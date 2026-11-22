defmodule Sprat.Terminal.ZonedRenderer do
  @moduledoc """
  The sole stdout writer for the zoned UI (`docs/design/tui-zones.md`),
  the default entry point (`sprat`, no flags) — `Sprat.Terminal.Renderer`
  keeps that same sole-writer role for `--inline`, and the two never run
  together: `Sprat.UISupervisor` starts exactly one, chosen by `:mode`.

  Owns a `Terminal.Screen` frame, a `Terminal.Layout`, a `Terminal.Focus`
  ring, one `{module, state}` per zone slot, and a `Terminal.Animate`
  clock. Every repaint: `Layout.compute/3` for the current size and NAV
  single-zone focus, each visible zone's `render/4` into the frame,
  `Screen.diff/4` against the last-flushed frame, `Screen.to_ansi/2`
  written once. Coalesced the same way the old renderer is (33ms,
  `Animate.repaint_interval_ms/0`).

  ## The session-update seam (stage 2)

  This module's public API deliberately matches `Sprat.Terminal.Renderer`'s
  (`commit/2`, `set_live/2`, `set_footer/2`, `subscribe/2`, `snapshot/1`) —
  `Sprat.Session.Subscriber` already only depends on that shape, so it
  points at whichever renderer is running without caring which one. In
  stage 1, `commit/2` appends to the Conversation zone's `Scrollback`
  (still a `Zones.Placeholder`) and `set_live/2` re-renders the Mission
  zone's text from the same checklist/activity view model
  `Sprat.Terminal.Renderer` already understands. Stage 2 replaces the
  Placeholder in those two slots with real `Zones.Conversation` /
  `Zones.Mission` and gives them a proper `handle_view_update/2` instead of
  this stand-in's `Placeholder.set_text/2`.

  ## Input routing

  `Terminal.Keybindings` still owns Ctrl+C (interrupt/exit),
  Ctrl+D (exit) and the INSERT-empty Shift+Tab permission-mode cycle,
  checked first, before anything reaches `Terminal.Focus` — those three
  behave identically to the inline renderer's. Everything else goes
  through `Focus.handle_key/3`; see that module's moduledoc for exactly
  who gets INSERT keystrokes (always the Composer zone) vs. NAV keystrokes
  (whichever zone the ring currently points at).
  """

  use GenServer

  alias Sprat.Agent.Tools.Files
  alias Sprat.Terminal.{Animate, Focus, Keybindings, Layout, Mascot, Screen, Width}

  alias Sprat.Terminal.Zones.{
    Agents,
    Composer,
    Conversation,
    Debug,
    Detail,
    Flow,
    Inspector,
    Mission,
    Settings
  }

  defstruct io_device: :stdio,
            cols: 80,
            rows: 24,
            color?: true,
            screen: %{},
            focus: nil,
            zones: %{},
            animate: nil,
            keybindings: nil,
            footer: %{mode: "normal", sources: 0},
            activity: nil,
            checklist: nil,
            budget: nil,
            mission_mode: nil,
            messages: [],
            permission: nil,
            hint: nil,
            flow_overlay?: false,
            settings_overlay?: false,
            debug_overlay?: false,
            repaint_scheduled?: false,
            intent_subscriber: nil,
            latencies: [],
            pending_keystrokes: [],
            last_event: nil,
            session_id: nil,
            project_path: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    {cols, rows} = Keyword.get(opts, :size) || terminal_size()

    state = %__MODULE__{
      io_device: Keyword.get(opts, :io_device, :stdio),
      cols: cols,
      rows: rows,
      color?: Sprat.Terminal.Glyphs.color?(opts),
      focus: Focus.new(),
      zones: init_zones(opts),
      animate: Animate.new(),
      keybindings: Keybindings.new(),
      intent_subscriber: Keyword.get(opts, :intent_subscriber),
      session_id: Keyword.get(opts, :session_id),
      project_path: Keyword.get(opts, :project_path)
    }

    if state.io_device == :stdio, do: IO.write(state.io_device, Screen.enter_alt_screen())

    # Off the startup path: walking a real project costs hundreds of ms even
    # after skipping build directories, and doing it here delayed the first
    # paint by that much (4.6s before the skip list).
    Files.attachable_files_async(Keyword.get(opts, :project_path), self())

    unless Keyword.get(opts, :skip_timers, false) do
      :timer.send_interval(250, :resize_poll)
    end

    {:ok, state, {:continue, :paint}}
  end

  defp init_zones(opts) do
    %{
      mission: {Mission, Mission.init([])},
      agents: {Agents, Agents.init([])},
      conversation: {Conversation, Conversation.init([])},
      inspector: {Inspector, Inspector.init([])},
      detail: {Detail, Detail.init([])},
      flow: {Flow, Flow.init([])},
      settings: {Settings, Settings.init([])},
      debug: {Debug, Debug.init([])},
      composer:
        {Composer,
         Composer.init(
           commands: Keyword.get(opts, :commands, []),
           history: Keyword.get(opts, :history, []),
           files: []
         )}
    }
  end

  @impl true
  def handle_continue(:paint, state), do: {:noreply, paint(state)}

  # -- public API (matches Terminal.Renderer's — see moduledoc) ---------------

  def commit(server \\ __MODULE__, lines) when is_list(lines),
    do: GenServer.cast(server, {:commit, lines})

  def set_live(server \\ __MODULE__, view_model) when is_map(view_model),
    do: GenServer.cast(server, {:set_live, view_model})

  def set_footer(server \\ __MODULE__, footer), do: GenServer.cast(server, {:set_footer, footer})

  @doc "Pushes `%{agents:, messages:}` (see `Terminal.MessageFlow`) to the Agents and Flow zones."
  def set_agents(server \\ __MODULE__, view_model) when is_map(view_model),
    do: GenServer.cast(server, {:set_agents, view_model})

  @doc """
  Admits one message (`%{from:, to:, type:}`, plus optional `:at` for
  display) — the design's "when a message is admitted, an envelope glyph
  travels..." The `:frame` `Terminal.MessageFlow` animates against is
  stamped here from the renderer's own `Terminal.Animate` clock, not by
  the caller: a caller that invented its own frame numbers (even a
  monotonically increasing counter, as this build's demo first tried)
  drifts arbitrarily far from the real clock the moment more than one
  message is admitted, so age-since-admission comparisons in
  `MessageFlow.gutter/4` stop lining up with real elapsed frames and the
  gutter silently never shows — found the hard way (a real tmux capture
  never once caught the gutter lit, across dozens of tries, until this
  was the fix). Pushed to the Agents/Flow gutter and the Inspector
  Messages tab; the full (bounded) history lives here, not in any caller.
  """
  def add_message(server \\ __MODULE__, message) when is_map(message),
    do: GenServer.cast(server, {:add_message, message})

  @doc "Pushes `%{sources:, tasks:, usage:, events:}` (any subset) to the Inspector zone's tabs."
  def set_inspector(server \\ __MODULE__, view_model) when is_map(view_model),
    do: GenServer.cast(server, {:set_inspector, view_model})

  def subscribe(server \\ __MODULE__, pid), do: GenServer.cast(server, {:subscribe, pid})
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def latency_report(server \\ __MODULE__), do: GenServer.call(server, :latency_report)

  @doc """
  Interior width available for the Conversation zone's content —
  `Session.Subscriber` wraps committed agent messages to this, not to
  `state.cols` (the raw terminal width): under a real breakpoint layout
  the Conversation zone shares the screen with Mission/Agents/Inspector
  columns and draws its own 2-column border (`Terminal.ZoneFrame`), so a
  line wrapped to the full terminal width was still too wide for the
  zone's box and got ellipsis-truncated a second time on render — the
  `"…involves packaging your application and its depende…"` bug. Falls
  back to `cols - 2` if the conversation zone were ever dropped to an
  overlay (not reachable at any terminal size `Layout` currently supports,
  since Conversation is the default focus and always fits or takes the
  single-zone breakpoint).
  """
  def content_width(server \\ __MODULE__), do: GenServer.call(server, :content_width)

  @doc "Starts the animation clock (a spinner or other motion is now active). No-op timers while stopped — the design's hard rule."
  def start_animation(server \\ __MODULE__), do: GenServer.cast(server, :start_animation)
  def stop_animation(server \\ __MODULE__), do: GenServer.cast(server, :stop_animation)

  # -- casts --------------------------------------------------------------

  @impl true
  def handle_cast({:commit, lines}, state) do
    {:noreply, state |> update_zone(:conversation, &append_lines(&1, lines)) |> request_repaint()}
  end

  def handle_cast({:set_live, view_model}, state) do
    state = %{
      state
      | activity: Map.get(view_model, :activity, state.activity),
        checklist: Map.get(view_model, :checklist, state.checklist),
        budget: Map.get(view_model, :budget, state.budget),
        mission_mode: Map.get(view_model, :mode, state.mission_mode),
        permission: Map.get(view_model, :permission, state.permission)
    }

    {:noreply, request_repaint(sync_mission(state))}
  end

  def handle_cast({:set_footer, footer}, state),
    do: {:noreply, request_repaint(%{state | footer: footer})}

  def handle_cast({:set_agents, view_model}, state) do
    state =
      state
      |> update_zone(:agents, &Agents.handle_view_update(&1, view_model))
      |> update_zone(:flow, &Flow.handle_view_update(&1, view_model))
      |> update_zone(:detail, &Detail.handle_view_update(&1, view_model))

    {:noreply, request_repaint(state)}
  end

  @max_messages 500

  def handle_cast({:add_message, message}, state) do
    message = Map.put(message, :frame, state.animate.frame)
    messages = state.messages ++ [message]
    messages = Enum.take(messages, -@max_messages)
    view_model = %{messages: messages}

    state =
      %{state | messages: messages}
      |> update_zone(:agents, &Agents.handle_view_update(&1, view_model))
      |> update_zone(:flow, &Flow.handle_view_update(&1, view_model))
      |> update_zone(:inspector, &Inspector.handle_view_update(&1, view_model))

    {:noreply, request_repaint(state)}
  end

  def handle_cast({:set_inspector, view_model}, state),
    do:
      {:noreply,
       request_repaint(
         update_zone(state, :inspector, &Inspector.handle_view_update(&1, view_model))
       )}

  def handle_cast({:subscribe, pid}, state), do: {:noreply, %{state | intent_subscriber: pid}}

  def handle_cast(:start_animation, state) do
    state = %{state | animate: Animate.start(state.animate)}
    {:noreply, schedule_animation_tick(state)}
  end

  def handle_cast(:stop_animation, state),
    do: {:noreply, %{state | animate: Animate.stop(state.animate)}}

  # -- calls ----------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:latency_report, _from, state),
    do: {:reply, percentiles(state.latencies), state}

  def handle_call(:content_width, _from, state),
    do: {:reply, conversation_inner_width(state), state}

  defp conversation_inner_width(state) do
    layout =
      Layout.compute(state.cols, state.rows, %{
        focused: Focus.current(state.focus),
        composer_lines: composer_line_count(state)
      })

    case Map.get(layout.zones, :conversation) do
      %{w: w} -> max(w - 2, 10)
      nil -> max(state.cols - 2, 10)
    end
  end

  # -- input ----------------------------------------------------------------

  @impl true
  def handle_info({:input_event, :input_closed}, state),
    do: {:noreply, notify(state, :input_closed)}

  def handle_info({:input_event, event}, state) do
    now = System.monotonic_time(:millisecond)
    state = %{state | last_event: event}
    state = dispatch(state, event, now)
    state = track_keystroke(state, event, now)
    {:noreply, request_repaint(state)}
  end

  def handle_info({:attachable_files, files}, state) do
    {:noreply, update_zone(state, :composer, &Composer.set_files(&1, files))}
  end

  def handle_info(:resize_poll, state) do
    case terminal_size() do
      {cols, rows} when {cols, rows} != {state.cols, state.rows} ->
        # A live resize needs an actual clear, not just resetting the
        # tracked frame to blank: a diff only writes cells where the new
        # frame differs from the (now-blank) old one, so a cell that is
        # blank in both never gets a space written to it -- even though
        # the real terminal may still show stale content there from
        # before the resize (its own reflow does not reliably clear
        # whatever falls outside the new dimensions). Found by resizing a
        # live tmux pane and watching the old composer box survive under
        # the new, composer-less single-zone layout -- see
        # `Screen.clear_screen/0`.
        if state.io_device == :stdio, do: IO.write(state.io_device, Screen.clear_screen())

        {:noreply,
         request_repaint(%{state | cols: cols, rows: rows, screen: Screen.blank(cols, rows)})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:animation_tick, state) do
    state = %{state | animate: Animate.tick(state.animate)}
    {:noreply, request_repaint(schedule_animation_tick(state))}
  end

  # Forces one repaint once a hint's TTL has elapsed, for the idle case
  # (nothing else — no animation, no resize — would otherwise trigger a
  # repaint and the now-stale hint would keep showing until the next
  # unrelated event happened to repaint the footer). `footer_hint/1` is
  # what actually decides "expired"; this only makes sure a repaint
  # exists to notice.
  def handle_info(:hint_expired, state), do: {:noreply, request_repaint(state)}

  def handle_info(:do_repaint, state) do
    {:noreply, state |> flush_latencies() |> paint() |> Map.put(:repaint_scheduled?, false)}
  end

  @impl true
  def terminate(_reason, %{io_device: :stdio} = state) do
    IO.write(state.io_device, Screen.leave_alt_screen())
    Sprat.Terminal.Mode.restore!()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- dispatch -----------------------------------------------------------

  defp dispatch(%{permission: p} = state, event, _now) when not is_nil(p),
    do: dispatch_permission(state, event)

  defp dispatch(%{flow_overlay?: true} = state, event, _now),
    do: dispatch_flow_overlay(state, event)

  defp dispatch(%{settings_overlay?: true} = state, event, _now),
    do: dispatch_settings_overlay(state, event)

  defp dispatch(%{debug_overlay?: true} = state, event, _now),
    do: dispatch_debug_overlay(state, event)

  defp dispatch(state, event, now) do
    ctx = %{composer_empty?: composer_empty?(state), menu_open?: composer_menu_open?(state)}

    if event in [:ctrl_c, :ctrl_d] or (event == :shift_tab and state.focus.mode == :insert) do
      apply_keybinding_intent(state, event, ctx, now)
    else
      {focus, action} = Focus.handle_key(state.focus, event, ctx)
      apply_focus_action(%{state | focus: focus}, action, now)
    end
  end

  # A pending permission/recovery prompt (`Sprat.Session.recovery_choice/2`,
  # the same `live.permission` shape `Sprat.Terminal.Renderer` already
  # handles) takes over all input until answered — Focus and every zone
  # are frozen, exactly like the inline renderer's `handle_permission_event/2`.
  # Real, existing functionality (session-recovery prompts on resume), not
  # a stage-2 zone — dropping it here would silently break recovery for
  # anyone on the now-default zoned UI.
  defp dispatch_permission(state, :up), do: move_permission(state, -1)
  defp dispatch_permission(state, :down), do: move_permission(state, 1)

  defp dispatch_permission(state, :enter) do
    p = state.permission
    notify(%{state | permission: nil}, {:permission_result, p.selected})
  end

  defp dispatch_permission(state, :esc),
    do: notify(%{state | permission: nil}, :permission_cancelled)

  defp dispatch_permission(state, _event), do: state

  # The Flow overlay (`f`/`Alt+f`, docs/design/tui-zones.md §3) takes over
  # input the same way a permission prompt does while open — `esc` or
  # either open chord closes it, everything else is the overlay's own
  # (filters, scrolling); not a zone in `Terminal.Layout`/`Terminal.Focus`'s
  # ring, so it never competes for Tab-focus.
  defp dispatch_flow_overlay(state, :esc), do: %{state | flow_overlay?: false}
  defp dispatch_flow_overlay(state, {:char, "f"}), do: %{state | flow_overlay?: false}
  defp dispatch_flow_overlay(state, {:alt, "f"}), do: %{state | flow_overlay?: false}

  defp dispatch_flow_overlay(state, event) do
    {mod, zstate} = Map.fetch!(state.zones, :flow)
    {new_zstate, intents} = mod.handle_key(zstate, event)
    dispatch_intents(put_in(state.zones.flow, {mod, new_zstate}), intents)
  end

  # The Settings overlay (`s`/`Alt+s`) — same overlay contract as Flow.
  # Pressing Enter on an editable row (see `Zones.Settings.handle_key/2`)
  # returns `{:settings_edit, key}`, which closes the overlay and hands
  # off to the intent subscriber (`Sprat.Session.Shell`) to run the actual
  # numbered-prompt editor — the overlay itself never edits anything.
  defp dispatch_settings_overlay(state, :esc), do: %{state | settings_overlay?: false}
  defp dispatch_settings_overlay(state, {:char, "s"}), do: %{state | settings_overlay?: false}
  defp dispatch_settings_overlay(state, {:alt, "s"}), do: %{state | settings_overlay?: false}

  defp dispatch_settings_overlay(state, event) do
    {mod, zstate} = Map.fetch!(state.zones, :settings)
    {new_zstate, intents} = mod.handle_key(zstate, event)
    state = put_in(state.zones.settings, {mod, new_zstate})

    if Enum.any?(intents, &match?({:settings_edit, _}, &1)) do
      dispatch_intents(%{state | settings_overlay?: false}, intents)
    else
      dispatch_intents(state, intents)
    end
  end

  # The Debug overlay (`d`/`Alt+d`) — same overlay contract as Flow;
  # `[`/`]` and `Alt+[`/`Alt+]` switch its tab while open, same chord the
  # Inspector zone already uses (`apply_global/2`'s `{:inspector_tab,
  # dir}` intercepts those globally when *this* overlay isn't open).
  defp dispatch_debug_overlay(state, :esc), do: %{state | debug_overlay?: false}
  defp dispatch_debug_overlay(state, {:char, "d"}), do: %{state | debug_overlay?: false}
  defp dispatch_debug_overlay(state, {:alt, "d"}), do: %{state | debug_overlay?: false}

  defp dispatch_debug_overlay(state, {:char, "["}),
    do: update_zone(state, :debug, &Debug.switch_tab(&1, :prev))

  defp dispatch_debug_overlay(state, {:char, "]"}),
    do: update_zone(state, :debug, &Debug.switch_tab(&1, :next))

  defp dispatch_debug_overlay(state, {:alt, "["}),
    do: update_zone(state, :debug, &Debug.switch_tab(&1, :prev))

  defp dispatch_debug_overlay(state, {:alt, "]"}),
    do: update_zone(state, :debug, &Debug.switch_tab(&1, :next))

  defp dispatch_debug_overlay(state, event) do
    {mod, zstate} = Map.fetch!(state.zones, :debug)
    {new_zstate, intents} = mod.handle_key(zstate, event)
    dispatch_intents(put_in(state.zones.debug, {mod, new_zstate}), intents)
  end

  defp move_permission(state, delta) do
    p = state.permission
    n = length(p.options)
    selected = rem(p.selected + delta + n, n)
    %{state | permission: %{p | selected: selected}}
  end

  defp apply_keybinding_intent(state, event, ctx, now) do
    {intent, keybindings} = Keybindings.dispatch(state.keybindings, event, ctx, now)
    state = %{state | keybindings: keybindings}

    case intent do
      nil -> apply_focus_action(state, :route_composer, now)
      {:mode, :cycle} -> cycle_mode(state)
      :clear_composer -> update_zone(state, :composer, &Composer.clear/1)
      other -> notify(state, other)
    end
  end

  defp apply_focus_action(state, :none, _now), do: state
  defp apply_focus_action(state, {:mode, _}, _now), do: state

  defp apply_focus_action(state, :route_composer, _now) do
    {zone_state, intents} =
      Composer.handle_key(elem(state.zones.composer, 1), last_routed_event(state))

    state = put_in(state.zones.composer, {Composer, zone_state})
    dispatch_intents(state, intents)
  end

  defp apply_focus_action(state, {:route_zone, key}, now), do: route_to_focused(state, key, now)

  defp apply_focus_action(state, {:route_zone_and_mode, key, _mode}, now),
    do: route_to_focused(state, key, now)

  defp apply_focus_action(state, {:global, intent}, now), do: apply_global(state, intent, now)

  defp route_to_focused(state, key, now) do
    zone_id = Focus.current(state.focus)
    {mod, zstate} = Map.fetch!(state.zones, zone_id)
    {new_zstate, intents} = mod.handle_key(zstate, key)

    state =
      if new_zstate == zstate and intents == [] do
        set_hint(state, "#{key_word(key)} has no effect in #{zone_id}", now)
      else
        state
      end

    state = put_in(state.zones[zone_id], {mod, new_zstate})
    dispatch_intents(state, intents)
  end

  defp key_word(key) when is_atom(key), do: key
  defp key_word(key), do: inspect(key)

  # -- intents a zone's handle_key/2 can return --------------------------

  defp dispatch_intents(state, intents), do: Enum.reduce(intents, state, &dispatch_intent(&2, &1))

  defp dispatch_intent(state, {:focus, zone_id}),
    do: %{state | focus: Focus.jump(state.focus, zone_id)}

  defp dispatch_intent(state, {:open_detail, term}),
    do: update_zone(state, :detail, &Detail.open(&1, term))

  defp dispatch_intent(state, {:toggle_pin, term}),
    do: update_zone(state, :detail, &Detail.toggle_pin(&1, term))

  defp dispatch_intent(state, other), do: notify(state, other)

  defp apply_global(state, {:inspector_tab, dir}, _now),
    do: update_zone(state, :inspector, &Inspector.switch_tab(&1, dir))

  defp apply_global(state, :open_flow_overlay, _now),
    do: %{state | flow_overlay?: not state.flow_overlay?}

  # Refreshed from the store every time the overlay opens (never on
  # close) — `Sprat.Config.effective/1`/`Sprat.Secrets.status/1` are cheap
  # local reads, so doing them here keeps `Zones.Settings.render/4` pure
  # while still always showing the current effective values, including
  # whatever a just-finished `{:settings_edit, _}` round trip changed.
  defp apply_global(state, :open_settings_overlay, _now) do
    state = %{state | settings_overlay?: not state.settings_overlay?}
    if state.settings_overlay?, do: refresh_settings(state), else: state
  end

  defp apply_global(state, :open_debug_overlay, _now) do
    state = %{state | debug_overlay?: not state.debug_overlay?}
    if state.debug_overlay?, do: refresh_debug(state), else: state
  end

  defp apply_global(state, {:page_zone, :down}, now), do: route_to_focused(state, :page_down, now)
  defp apply_global(state, {:page_zone, :up}, now), do: route_to_focused(state, :page_up, now)

  defp apply_global(state, :open_pager, now),
    do: set_hint(state, "$PAGER integration: stage 2", now)

  defp apply_global(state, :toggle_mouse, now), do: set_hint(state, "mouse mode: stage 2", now)

  defp apply_global(state, :open_command_menu, now),
    do: set_hint(state, "command menu: stage 2", now)

  defp apply_global(state, :help, now),
    do: set_hint(state, "?  help overlay: stage 2 — see docs/design/tui-zones.md", now)

  # Hints expire on their own (`footer_hint/1` compares `at` against the
  # paint-time clock) rather than sticking until the next keypress happens
  # to overwrite one — a stale hint from several seconds ago ("down has no
  # effect in conversation") otherwise lingers in the footer indefinitely,
  # since `footer_hint/1` used to only ever check `nil` vs. not. Reuses
  # the same `now` (`System.monotonic_time(:millisecond)`) this module
  # already threads through `dispatch/3` for latency tracking, rather than
  # a second, independent clock read.
  @hint_ttl_ms 4_000
  defp set_hint(state, text, now) do
    Process.send_after(self(), :hint_expired, @hint_ttl_ms)
    %{state | hint: %{text: text, at: now}}
  end

  # -- Settings/Debug overlay data (docs handed off to Sprat.Config /
  # Sprat.Debug — see those modules; this is only the seam that turns
  # their query results into each overlay zone's view model) -----------

  defp refresh_settings(state) do
    entries = Sprat.Config.effective(state.project_path)

    case Sprat.Secrets.status(state.project_path || File.cwd!()) do
      {:ok, key_status} ->
        update_zone(
          state,
          :settings,
          &Settings.handle_view_update(&1, %{entries: entries, key_status: key_status})
        )
    end
  end

  defp refresh_debug(state) do
    {_mod, inspector} = state.zones.inspector
    tasks = inspector.tasks
    mission_id = tasks |> List.first() |> mission_id_of()

    requests = if mission_id, do: build_requests(mission_id), else: []
    tools = if tasks != [], do: build_tools(tasks), else: []
    costs = if mission_id, do: Sprat.Debug.costs(Sprat.Store, mission_id, tasks), else: nil
    events = if state.session_id, do: build_events(state.session_id), else: []
    logs = Sprat.LogBuffer.all()

    view_model = %{requests: requests, tools: tools, events: events, costs: costs, logs: logs}
    update_zone(state, :debug, &Debug.handle_view_update(&1, view_model))
  end

  defp mission_id_of(nil), do: nil
  defp mission_id_of(task), do: task.mission_id

  defp build_requests(mission_id) do
    Sprat.Store
    |> Sprat.Debug.requests(mission_id)
    |> Enum.map(fn row ->
      detail = Sprat.Debug.request_detail(Sprat.Store, row)
      Map.put(row, :detail_lines, detail_lines(detail))
    end)
  end

  defp build_tools(tasks) do
    Sprat.Store
    |> Sprat.Debug.tool_calls(tasks)
    |> Enum.map(fn row ->
      detail = Sprat.Debug.tool_detail(Sprat.Store, row)
      Map.put(row, :detail_lines, detail_lines(detail))
    end)
  end

  defp build_events(session_id) do
    Sprat.Store
    |> Sprat.Debug.events(session_id)
    |> Enum.map(fn event ->
      payload = event.payload && JSON.decode!(event.payload)
      %{event: event, detail_lines: detail_lines(%{payload: payload})}
    end)
  end

  # Redacted-by-construction: everything passed in here already went
  # through `Sprat.Store.Redact.scrub/2` at write time
  # (`Sprat.Store.Events.append/5`) — `inspect/2` just formats it for the
  # overlay, it applies no redaction of its own.
  defp detail_lines(map) do
    Enum.flat_map(map, fn {key, value} ->
      ["#{key}:" | value |> inspect(pretty: true, limit: 200) |> String.split("\n")]
    end)
  end

  # `Composer.handle_key/2` needs the *original* event (e.g. `{:char, "a"}`,
  # `:backspace`) rather than whatever Focus normalised NAV keys to — INSERT
  # mode never renormalises, so the event Focus was given is always the
  # right one to forward. Threading it through a struct field avoids
  # widening `Focus.handle_key/3`'s return shape just for this one path.
  defp last_routed_event(%{last_event: event}), do: event

  defp cycle_mode(state) do
    modes = ["normal", "auto", "plan"]
    idx = Enum.find_index(modes, &(&1 == state.footer.mode)) || 0
    next = Enum.at(modes, rem(idx + 1, length(modes)))
    notify(%{state | footer: %{state.footer | mode: next}}, {:mode, next})
  end

  defp notify(%{intent_subscriber: nil} = state, _intent), do: state

  defp notify(state, intent) do
    send(state.intent_subscriber, {:sprat_intent, intent})
    state
  end

  defp composer_empty?(state), do: Composer.empty?(elem(state.zones.composer, 1))

  defp composer_line_count(state) do
    {_mod, zstate} = state.zones.composer
    Composer.line_count(zstate)
  end

  defp composer_menu_open?(state), do: Composer.menu_open?(elem(state.zones.composer, 1))

  defp update_zone(state, zone_id, fun) do
    {mod, zstate} = Map.fetch!(state.zones, zone_id)
    put_in(state.zones[zone_id], {mod, fun.(zstate)})
  end

  defp append_lines(%Conversation{} = zstate, lines), do: Conversation.append(zstate, lines)

  defp sync_mission(state) do
    view_model = %{
      activity: state.activity,
      checklist: state.checklist,
      budget: state.budget,
      mode: state.mission_mode
    }

    update_zone(state, :mission, &Mission.handle_view_update(&1, view_model))
  end

  # -- animation ------------------------------------------------------------

  defp schedule_animation_tick(state) do
    if state.animate.running? and Animate.enabled?(animate_opts(state)) do
      Process.send_after(self(), :animation_tick, Animate.spinner_interval_ms())
    end

    state
  end

  defp animate_opts(state),
    do: [
      plain?: false,
      tty?: state.io_device == :stdio,
      size: {state.cols, state.rows},
      color: state.color?
    ]

  # -- painting -------------------------------------------------------------

  defp request_repaint(%{repaint_scheduled?: true} = state), do: state

  defp request_repaint(state) do
    Process.send_after(self(), :do_repaint, Animate.repaint_interval_ms())
    %{state | repaint_scheduled?: true}
  end

  # A permission prompt (fetch-approval, stage-failure retry/skip/abandon,
  # model-pick, budget-confirm — anything routed through
  # `Sprat.Session.await_permission/2`) used to paint from a blank screen,
  # which blanked every other zone (Mission checklist, Conversation
  # history, everything) while the user was asked to decide — a real live
  # run caught this. It now composites on top of the same zone-layout
  # frame the flow/settings/debug overlays already build on
  # (`put_overlay/4`), so the prompt is the last thing drawn but the rest
  # of the screen stays visible underneath, exactly like those overlays.
  defp paint(state) do
    layout =
      Layout.compute(state.cols, state.rows, %{
        focused: Focus.current(state.focus),
        composer_lines: composer_line_count(state)
      })

    focused_id = Focus.current(state.focus)

    frame =
      Enum.reduce(layout.zones, Screen.blank(state.cols, state.rows), fn {zone_id, rect}, frame ->
        {mod, zstate} = Map.fetch!(state.zones, zone_id)
        rows = mod.render(zstate, rect, zone_id == focused_id, state.animate.frame)
        Screen.put_rows(frame, rect, rows)
      end)

    frame = put_footer(frame, state, layout.footer)

    frame =
      if state.flow_overlay?, do: put_overlay(frame, state, layout.footer, :flow), else: frame

    frame =
      if state.settings_overlay?,
        do: put_overlay(frame, state, layout.footer, :settings),
        else: frame

    frame =
      if state.debug_overlay?, do: put_overlay(frame, state, layout.footer, :debug), else: frame

    frame = if state.permission, do: put_permission_overlay(frame, state), else: frame

    flush_frame(state, frame)
  end

  defp put_overlay(frame, state, footer_rect, zone_id) do
    rect = %{x: 0, y: 0, w: state.cols, h: max(footer_rect.y, 1)}
    {mod, zstate} = Map.fetch!(state.zones, zone_id)
    rows = mod.render(zstate, rect, true, state.animate.frame)
    Screen.put_rows(frame, rect, rows)
  end

  defp flush_frame(state, frame) do
    diff = Screen.diff(state.screen, frame, state.cols, state.rows)
    if diff != [], do: IO.write(state.io_device, Screen.to_ansi(diff, color?: state.color?))
    %{state | screen: frame}
  end

  # A simple centred box — same content `Terminal.View.prompt_lines/3`
  # renders for the inline UI, laid out as cells instead of an ANSI
  # string (this renderer's frame is cells everywhere, never bytes, until
  # `Screen.to_ansi/2`).
  defp put_permission_overlay(frame, state) do
    p = state.permission
    w = min(max(state.cols - 4, 20), 70)

    lines =
      [p.title <> ":"] ++
        p.lines ++ [""] ++ option_lines(p) ++ ["", "Enter to confirm · Esc to cancel"]

    h = min(length(lines) + 2, max(state.rows - 2, 3))
    rect = %{x: div(state.cols - w, 2), y: div(state.rows - h, 2), w: w, h: h}

    rows = [
      Screen.text_cells(String.duplicate("─", w), w, Screen.default_style())
      | Enum.map(Enum.take(lines, h - 2), &Screen.text_cells(&1, w, Screen.default_style()))
    ]

    rows = rows ++ [Screen.text_cells(String.duplicate("─", w), w, Screen.default_style())]
    Screen.put_rows(frame, rect, rows)
  end

  defp option_lines(p) do
    p.options
    |> Enum.with_index()
    |> Enum.map(fn {opt, i} ->
      marker = if i == p.selected, do: "> ", else: "  "
      "#{marker}#{i + 1}. #{opt}"
    end)
  end

  # The mascot swims at the right end of the footer: still when idle,
  # swimming while work runs, turning to blink at the user when a prompt
  # is waiting. See `Sprat.Terminal.Mascot`.
  @mascot_track 18

  defp put_footer(frame, state, rect) do
    left =
      " #{String.upcase(Atom.to_string(state.focus.mode))} · #{state.footer.mode} mode · #{footer_cost(state)} · #{footer_hint(state)}"

    text = pad_with_mascot(left, rect.w, state)
    cells = Screen.text_cells(text, rect.w, Screen.default_style())
    Screen.put_rows(frame, rect, [cells])
  end

  defp pad_with_mascot(left, width, state) do
    # One trailing space so the fish never sits against the screen edge.
    track = min(@mascot_track, width - Width.width(left) - 2)

    mascot =
      Mascot.render(
        Mascot.state_of(%{permission: state.permission, animating?: state.animate.running?}),
        state.animate.frame,
        max(track, 0),
        ascii?: Sprat.Terminal.Glyphs.ascii?()
      )

    if mascot == "" do
      left
    else
      gap = width - Width.width(left) - Width.width(mascot) - 1
      left <> String.duplicate(" ", max(gap, 0)) <> mascot <> " "
    end
  end

  # One source for the cost, so the footer can never disagree with Mission.
  # No budget recorded means unknown, which is not zero (spec-v1.md §12).
  defp footer_cost(state), do: Mission.budget_word(state.budget) || "cost unknown"

  # Both completion menus were computed and never drawn: the composer zone
  # renders only its border and text, so `/` commands and `@` mentions
  # completed blind — the user could Tab through matches they could not see.
  # The composer's rect is three rows (border, text, border) with no room for
  # a list, so the matches go where there is room: the footer.
  defp footer_hint(state) do
    case completion_hint(state) do
      nil -> stale_aware_hint(state)
      hint -> hint
    end
  end

  defp completion_hint(state) do
    {_mod, zstate} = state.zones.composer

    case Composer.completions(zstate) do
      nil -> nil
      %{matches: [], query: query} -> "no match for #{query}"
      %{matches: matches, selected: selected} -> render_completions(matches, selected)
    end
  end

  defp render_completions(matches, selected) do
    shown =
      matches
      |> Enum.take(5)
      |> Enum.with_index()
      |> Enum.map_join("  ", fn {match, i} ->
        if i == selected, do: "[#{match}]", else: match
      end)

    more = if length(matches) > 5, do: " +#{length(matches) - 5} more", else: ""
    "#{shown}#{more} · tab completes"
  end

  defp stale_aware_hint(%{hint: nil}), do: "tab zones · ? help"

  defp stale_aware_hint(%{hint: %{text: text, at: at}}) do
    if System.monotonic_time(:millisecond) - at <= @hint_ttl_ms do
      text
    else
      "tab zones · ? help"
    end
  end

  @tracked_for_latency [:enter, :backspace]

  defp track_keystroke(state, event, now) do
    if match?({:char, _}, event) or event in @tracked_for_latency do
      %{state | pending_keystrokes: [now | state.pending_keystrokes]}
    else
      state
    end
  end

  defp flush_latencies(state) do
    now = System.monotonic_time(:millisecond)
    new_latencies = Enum.map(state.pending_keystrokes, &(now - &1))
    %{state | latencies: state.latencies ++ new_latencies, pending_keystrokes: []}
  end

  defp percentiles([]), do: %{p50: 0, p95: 0, max: 0, count: 0}

  defp percentiles(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    p95_idx = max(round(n * 0.95) - 1, 0)

    %{
      p50: Enum.at(sorted, div(n, 2)),
      p95: Enum.at(sorted, p95_idx),
      max: List.last(sorted),
      count: n
    }
  end

  defp terminal_size do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows() do
      {cols, rows}
    else
      _ -> {80, 24}
    end
  end
end
