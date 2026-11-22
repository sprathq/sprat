defmodule Sprat.Terminal.Renderer do
  @moduledoc """
  The sole stdout-writing process (spec §13 supervision tree). Owns the
  inline rendering model: finished blocks are written once via `commit/2`
  and never redrawn; the live region (activity/spinner, checklist,
  permission prompt, composer, footer) is redrawn in place, capped at
  `rows - 2`, coalesced to roughly 30fps.

  Also the input-event sink: it holds the composer and keybinding-dispatch
  state, so keystrokes update what's drawn without a second writer. Global
  keybinding intents (`:interrupt`, `:exit`, `{:submit, text}`, ...) it
  cannot act on itself are forwarded to `:intent_subscriber` — this module
  never implements what an intent *does* beyond the purely visual ones
  (verbose toggle, checklist collapse, redraw, mode cycling).

  The output IO device is injectable via `:io_device` so tests can capture
  output without a real tty.
  """

  use GenServer

  alias Sprat.Terminal.{Composer, Keybindings, View, Width}

  @frame_ms 33
  @paragraph_break ~r/\n\n+/

  defstruct io_device: :stdio,
            cols: 80,
            rows: 24,
            last_live_height: 0,
            repaint_scheduled?: false,
            spinner_index: 0,
            verbose?: false,
            checklist_collapsed?: false,
            mode: "normal",
            live: %{activity: nil, checklist: nil, permission: nil},
            footer: %{mode: "normal", cost: "$0.00", sources: 0},
            streams: %{},
            composer: nil,
            keybindings: nil,
            intent_subscriber: nil,
            latencies: [],
            pending_keystrokes: []

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {cols, rows} = terminal_size()

    state = %__MODULE__{
      io_device: Keyword.get(opts, :io_device, :stdio),
      cols: cols,
      rows: rows,
      composer:
        Composer.new(
          commands: Keyword.get(opts, :commands, []),
          history: Keyword.get(opts, :history, []),
          files: []
        ),
      keybindings: Keybindings.new(),
      intent_subscriber: Keyword.get(opts, :intent_subscriber)
    }

    unless Keyword.get(opts, :skip_timers, false) do
      :timer.send_interval(120, :spinner_tick)
      :timer.send_interval(250, :resize_poll)
    end

    {:ok, state, {:continue, :paint}}
  end

  @impl true
  def handle_continue(:paint, state), do: {:noreply, paint(state)}

  # -- public API (cast: callers never block on the sole writer) --------------

  def commit(server \\ __MODULE__, lines) when is_list(lines),
    do: GenServer.cast(server, {:commit, lines})

  @doc "Replace the live region's non-composer content: %{activity:, checklist:, permission:}."
  def set_live(server \\ __MODULE__, view_model) when is_map(view_model),
    do: GenServer.cast(server, {:set_live, view_model})

  @doc "Append streaming text for `block_id`; whole paragraphs are committed as they complete."
  def stream_delta(server \\ __MODULE__, block_id, text) when is_binary(text),
    do: GenServer.cast(server, {:stream_delta, block_id, text})

  def set_footer(server \\ __MODULE__, footer), do: GenServer.cast(server, {:set_footer, footer})

  @doc "Change who receives forwarded intents (e.g. a demo or orchestrator process)."
  def subscribe(server \\ __MODULE__, pid), do: GenServer.cast(server, {:subscribe, pid})

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)
  def latency_report(server \\ __MODULE__), do: GenServer.call(server, :latency_report)

  @doc """
  Interior width for committed content — the raw terminal `cols` here
  (this renderer draws no zone borders/side columns to account for; see
  `ZonedRenderer.content_width/1` for the zoned build, which does).
  Both renderers implement this call so `Session.Subscriber` never has to
  know which one it's talking to.
  """
  def content_width(server \\ __MODULE__), do: GenServer.call(server, :content_width)

  # -- casts --------------------------------------------------------------

  @impl true
  def handle_cast({:commit, lines}, state),
    do: {:noreply, state |> do_commit(lines) |> request_repaint()}

  def handle_cast({:set_live, view_model}, state) do
    {:noreply, request_repaint(%{state | live: Map.merge(state.live, view_model)})}
  end

  def handle_cast({:stream_delta, block_id, text}, state) do
    {:noreply, state |> append_stream(block_id, text) |> request_repaint()}
  end

  def handle_cast({:set_footer, footer}, state),
    do: {:noreply, request_repaint(%{state | footer: footer})}

  def handle_cast({:subscribe, pid}, state), do: {:noreply, %{state | intent_subscriber: pid}}

  # -- calls ----------------------------------------------------------------

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call(:latency_report, _from, state),
    do: {:reply, percentiles(state.latencies), state}

  def handle_call(:content_width, _from, state), do: {:reply, state.cols, state}

  # -- input events -----------------------------------------------------------

  @impl true
  def handle_info({:input_event, event}, state), do: {:noreply, apply_input(state, event)}

  def handle_info(:spinner_tick, state) do
    {:noreply, request_repaint(%{state | spinner_index: state.spinner_index + 1})}
  end

  def handle_info(:resize_poll, state) do
    case terminal_size() do
      {cols, rows} when {cols, rows} != {state.cols, state.rows} ->
        {:noreply, request_repaint(%{state | cols: cols, rows: rows})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:do_repaint, state) do
    {:noreply, state |> flush_latencies() |> paint() |> Map.put(:repaint_scheduled?, false)}
  end

  # Only restore the real controlling terminal when this Renderer is
  # actually writing to it (the default `:stdio` device, as `UISupervisor`
  # starts it) — never when an `:io_device` was injected (every test does
  # this), otherwise `GenServer.stop/1` on a test Renderer would write raw
  # escape codes to the real terminal `mix test` is running in.
  @impl true
  def terminate(_reason, %{io_device: :stdio}) do
    Sprat.Terminal.Mode.restore!()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- input dispatch -----------------------------------------------------

  defp apply_input(state, :input_closed) do
    notify(state, :input_closed)
  end

  defp apply_input(state, event) do
    now = System.monotonic_time(:millisecond)

    state =
      if state.live.permission do
        handle_permission_event(state, event)
      else
        dispatch_global_or_composer(state, event, now)
      end

    state = track_keystroke(state, event, now)
    request_repaint(state)
  end

  defp dispatch_global_or_composer(state, event, now) do
    context = %{
      composer_empty?: state.composer.text == "",
      menu_open?: Composer.menu(state.composer) != nil or Composer.mention(state.composer) != nil
    }

    {intent, keybindings} = Keybindings.dispatch(state.keybindings, event, context, now)
    state = %{state | keybindings: keybindings}

    case intent do
      nil -> route_to_composer(state, event)
      :toggle_verbose -> %{state | verbose?: not state.verbose?}
      :toggle_checklist -> %{state | checklist_collapsed?: not state.checklist_collapsed?}
      :redraw -> %{state | last_live_height: 0}
      {:mode, :cycle} -> cycle_mode(state)
      other -> notify(state, other)
    end
  end

  defp route_to_composer(state, event) do
    case Composer.handle_event(state.composer, event) do
      {:ok, composer} -> %{state | composer: composer}
      {:submit, text, composer} -> notify(%{state | composer: composer}, {:submit, text})
    end
  end

  # -- permission prompt: intercepts navigation while it's open ---------------

  defp handle_permission_event(state, :up), do: move_permission(state, -1)
  defp handle_permission_event(state, :down), do: move_permission(state, 1)

  defp handle_permission_event(state, :enter) do
    p = state.live.permission
    notify(clear_permission(state), {:permission_result, p.selected})
  end

  defp handle_permission_event(state, :esc),
    do: notify(clear_permission(state), :permission_cancelled)

  defp handle_permission_event(state, _event), do: state

  defp move_permission(state, delta) do
    p = state.live.permission
    n = length(p.options)
    selected = rem(p.selected + delta + n, n)
    %{state | live: %{state.live | permission: %{p | selected: selected}}}
  end

  defp clear_permission(state), do: %{state | live: %{state.live | permission: nil}}

  defp cycle_mode(state) do
    modes = ["normal", "auto", "plan"]
    idx = Enum.find_index(modes, &(&1 == state.mode)) || 0
    next = Enum.at(modes, rem(idx + 1, length(modes)))
    notify(%{state | mode: next}, {:mode, next})
  end

  defp notify(%{intent_subscriber: nil} = state, _intent), do: state

  defp notify(state, intent) do
    send(state.intent_subscriber, {:sprat_intent, intent})
    state
  end

  @tracked_for_latency [:enter, :backspace]

  defp track_keystroke(state, event, now) do
    if match?({:char, _}, event) or event in @tracked_for_latency do
      %{state | pending_keystrokes: [now | state.pending_keystrokes]}
    else
      state
    end
  end

  # -- streaming --------------------------------------------------------------

  defp append_stream(state, block_id, text) do
    buffer = (state.streams[block_id] || "") <> text

    case String.split(buffer, @paragraph_break, parts: 2) do
      [paragraph, rest] ->
        state
        |> do_commit(Sprat.Terminal.Markdown.to_lines(paragraph, draw_width(state)))
        |> put_in_stream(block_id, rest)
        |> append_stream(block_id, "")

      [_incomplete] ->
        put_in_stream(state, block_id, buffer)
    end
  end

  defp put_in_stream(state, block_id, ""),
    do: %{state | streams: Map.delete(state.streams, block_id)}

  defp put_in_stream(state, block_id, buffer),
    do: %{state | streams: Map.put(state.streams, block_id, buffer)}

  # -- painting -------------------------------------------------------------

  defp request_repaint(%{repaint_scheduled?: true} = state), do: state

  defp request_repaint(state) do
    Process.send_after(self(), :do_repaint, @frame_ms)
    %{state | repaint_scheduled?: true}
  end

  defp do_commit(state, lines) do
    clear = clear_sequence(state.last_live_height)
    IO.write(state.io_device, clear <> Enum.join(lines, "\r\n") <> "\r\n")
    %{state | last_live_height: 0}
  end

  defp flush_latencies(state) do
    now = System.monotonic_time(:millisecond)
    new_latencies = Enum.map(state.pending_keystrokes, &(now - &1))
    %{state | latencies: state.latencies ++ new_latencies, pending_keystrokes: []}
  end

  defp paint(state) do
    lines = live_lines(state)
    max_lines = max(state.rows - 2, 3)
    # Prefer keeping the bottom of the live region (composer + footer)
    # visible over the top (activity/checklist) when space is constrained.
    lines = if length(lines) > max_lines, do: Enum.take(lines, -max_lines), else: lines

    clear = clear_sequence(state.last_live_height)
    IO.write(state.io_device, clear <> Enum.join(lines, "\r\n"))
    %{state | last_live_height: physical_height(lines, state.cols)}
  end

  defp clear_sequence(0), do: ""
  defp clear_sequence(height), do: "\r\e[#{height}A\e[J"

  # `\e[nA` moves the cursor up N *physical* terminal rows, not N logical
  # lines — a logical line whose visible width exceeds the terminal width
  # wraps into more than one physical row (spike finding).
  defp physical_height(lines, cols) when cols > 0 do
    Enum.reduce(lines, 0, fn line, acc -> acc + max(1, ceil(Width.width(line) / cols)) end)
  end

  defp live_lines(%{live: %{permission: p}} = state) when not is_nil(p) do
    View.prompt_lines(p, state.cols)
  end

  defp live_lines(state) do
    activity =
      if state.live.activity,
        do:
          View.activity_line(
            Map.put(state.live.activity, :spinner_index, state.spinner_index),
            state.cols
          ),
        else: []

    checklist =
      if state.live.checklist,
        do:
          View.checklist_lines(
            Map.put(state.live.checklist, :collapsed?, state.checklist_collapsed?),
            state.cols
          ),
        else: []

    streaming = streaming_tail_lines(state)
    composer = View.composer_lines(state.composer, state.cols)
    footer = View.footer_lines(Map.merge(state.footer, %{mode: state.mode}), state.cols)
    activity ++ checklist ++ streaming ++ composer ++ footer
  end

  defp streaming_tail_lines(%{streams: streams}) when map_size(streams) == 0, do: []

  defp streaming_tail_lines(state) do
    state.streams
    |> Map.values()
    |> Enum.join(" ")
    |> Width.wrap(draw_width(state))
    |> Enum.take(-3)
  end

  defp draw_width(state), do: max(state.cols - 1, 10)

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
