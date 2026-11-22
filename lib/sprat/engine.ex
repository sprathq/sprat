defmodule Sprat.Engine do
  @moduledoc """
  The V4 observer/PM engine (`docs/spec-v4.md` §6–§9): one process per
  machine that

    * every `fast_ms` (2 s): scans the Claude Code session registry, tails
      transcripts, folds session state, detects findings (§7), runs the
      usage-limit scheduler (§7.1), follow-ups (§9.4) and held deliveries;
    * every `slow_ms` (60 s): rebuilds roadmaps whose sources changed, reads
      git progress, refreshes the cmux surface map, promotes autonomy;
    * runs PM investigations (`Sprat.PM.Runner`) as tasks, at most
      `pm_concurrency` at a time, and acts on each decision only through
      `Sprat.PM.Policy` (§8.3, §9.2);
    * answers `snapshot/1` for the Pass TUI and takes its commands.

  All side effects go through injectable functions in `opts` (`:pm_fun`,
  `:deliver_fun`, `:notify_fun`, `:registry_fun`, …) so the engine is
  tested without Claude, cmux or a real machine.
  """

  use GenServer
  require Logger

  alias Sprat.Observer.{
    ConfigDirs,
    Detector,
    Live,
    Registry,
    RoadmapCache,
    SessionScan,
    Store,
    Surfaces,
    Tail,
    Transcript,
    UsageLimit
  }

  alias Sprat.Observer.Model.{Account, Decision, Finding, Project, Served, Session}
  alias Sprat.Observer.Model.SessionState, as: SState
  alias Sprat.PM.Policy
  alias Sprat.Roadmap
  alias Sprat.Roadmap.Position

  @follow_up_s 30 * 60
  @resume_spacing_s 5 * 60
  @first_day_s 24 * 3600

  @default_settings %{
    "pm_budget_usd" => 0.5,
    "project_cap_usd" => 3.0,
    "fleet_cap_usd" => 15.0,
    "pm_concurrency" => 2,
    "pm_model" => nil,
    "notify" => true
  }

  # -- API ----------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The current snapshot for the TUI (`Sprat.Engine.Snapshot`)."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot, 15_000)

  @doc "Runs a TUI command (see `Sprat.Terminal.Board.Keys`). Returns `:ok` or `{:error, message}`."
  def command(server \\ __MODULE__, cmd), do: GenServer.call(server, {:command, cmd}, 30_000)

  @doc "Forces a fast + slow tick now (tests, `sprat status`)."
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 120_000)

  @doc "Condensed transcript lines for the session view."
  def session_lines(server \\ __MODULE__, sid), do: GenServer.call(server, {:session_lines, sid})

  # -- init ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    store = Keyword.get(opts, :store, Store)

    state = %{
      opts: opts,
      store: store,
      config_dirs: Keyword.get_lazy(opts, :config_dirs, fn -> ConfigDirs.list() end),
      sessions: %{},
      states: %{},
      events: %{},
      tails: %{},
      projects: %{},
      roadmaps: %{},
      resolve_cache: %{},
      surfaces: %{},
      cmux: nil,
      account_dirs: Keyword.get(opts, :account_dirs, []),
      logins: %{},
      login_changed_at: %{},
      accounts: load_accounts(store),
      findings: %{},
      pm_queue: [],
      pm_running: %{},
      pm_sessions: %{},
      holds: %{},
      follow_ups: %{},
      notified: MapSet.new(),
      last_slow: nil
    }

    state = Map.merge(state, Sprat.Engine.Jobs.init_state())

    if Keyword.get(opts, :autostart, true) do
      # Sessions first, so the first roadmap pass knows which projects exist.
      send(self(), :fast_tick)
      send(self(), :slow_tick)
    end

    {:ok, state}
  end

  # -- ticks --------------------------------------------------------------------

  @impl true
  def handle_info(:fast_tick, state) do
    state = timed(:fast, fn -> safely(state, &fast/1) end)
    Sprat.Engine.ProcessMap.did("checked every session")
    Sprat.Engine.Publisher.dirty()
    Process.send_after(self(), :fast_tick, Keyword.get(state.opts, :fast_ms, 2_000))
    {:noreply, state}
  end

  def handle_info(:slow_tick, state) do
    state = timed(:slow, fn -> safely(state, &slow/1) end)
    Process.send_after(self(), :slow_tick, Keyword.get(state.opts, :slow_ms, 60_000))
    {:noreply, state}
  end

  def handle_info({:job_step, id, text}, state) do
    Sprat.Engine.Publisher.dirty()
    {:noreply, Sprat.Engine.Jobs.step(state, id, text, now(state))}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Sprat.Engine.Publisher.dirty()

    case Sprat.Engine.Jobs.finish(state, ref, result, now(state)) do
      {:ok, state} -> {:noreply, state}
      :error -> {:noreply, pm_reply(state, ref, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Sprat.Engine.Jobs.finish(state, ref, {:crashed, reason}, now(state)) do
      {:ok, state} -> {:noreply, state}
      :error -> {:noreply, pm_down(state, ref, reason)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp pm_reply(state, ref, result) do
    Process.demonitor(ref, [:flush])

    case Enum.find(state.pm_running, fn {_fid, %{ref: r}} -> r == ref end) do
      {fid, run} -> safely(state, &pm_finished(&1, fid, run, result))
      nil -> state
    end
  end

  defp pm_down(state, ref, reason) do
    case Enum.find(state.pm_running, fn {_fid, %{ref: r}} -> r == ref end) do
      {fid, run} -> safely(state, &pm_finished(&1, fid, run, {:error, {:crashed, reason}, %{}}))
      nil -> state
    end
  end

  # A tick long enough to make the board wait is logged, so a stall leaves a
  # trace in serve.log (Sprat.Cmd logs which command it had to stop).
  defp timed(tick, fun) do
    {us, state} = :timer.tc(fun)
    ms = div(us, 1000)

    if ms > 5_000 do
      Logger.warning("sprat engine: #{tick} tick took #{ms} ms")

      Sprat.Activity.emit(:engine,
        type: :slow_tick,
        text: "the #{tick} scan took #{Float.round(ms / 1000, 1)}s (the board waited)",
        status: :failed
      )
    end

    state
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, Sprat.Engine.Snapshot.build(state, now(state)), state}

  def handle_call(:refresh, _from, state) do
    state = state |> safely(&observe_sessions/1) |> safely(&slow/1) |> safely(&fast/1)
    {:reply, :ok, state}
  end

  def handle_call({:session_lines, sid}, _from, state),
    do: {:reply, Sprat.Engine.Snapshot.session_lines(Map.get(state.events, sid, [])), state}

  # The processes screen (in-process board): read here, no state touched.
  def handle_call({:command, :process_map}, _from, state),
    do: {:reply, {:ok, {:process_map, Sprat.Engine.ProcessMap.snapshot()}}, state}

  def handle_call({:command, cmd}, _from, state) do
    {reply, state} =
      try do
        Sprat.Engine.Commands.run(cmd, state, now(state))
      rescue
        e ->
          Logger.error(
            "sprat command #{inspect(cmd)} failed: " <>
              Exception.format(:error, e, __STACKTRACE__)
          )

          {{:error, Exception.message(e)}, state}
      end

    Sprat.Engine.Publisher.dirty()
    {:reply, reply, state}
  end

  defp safely(state, fun) do
    fun.(state)
  rescue
    e ->
      Logger.error("sprat engine: " <> Exception.format(:error, e, __STACKTRACE__))
      state
  end

  # -- fast tick ------------------------------------------------------------------

  defp fast(state) do
    now = now(state)

    state =
      state
      |> observe_sessions()
      |> update_accounts(now)
      |> detect(now)

    # The observers found a session in a project the engine doesn't know
    # yet (just after start, or a new project): look at projects now rather
    # than at the next slow tick, a minute away.
    state =
      if observers?(state) and unknown_project?(state) and
           (is_nil(state.last_slow) or DateTime.diff(now, state.last_slow) >= 10),
         do: state |> slow() |> detect(now),
         else: state

    if passive?(state) do
      state
    else
      state
      |> run_scheduler(now)
      |> run_holds(now)
      |> run_follow_ups(now)
      |> start_pm_runs(now)
      |> notify_new_yours()
    end
  end

  # A new account (a `claude` started with another CLAUDE_CONFIG_DIR) is
  # picked up within a minute. Fixed when the caller passed `:config_dirs`.
  defp config_dirs(state) do
    if Keyword.has_key?(state.opts, :config_dirs),
      do: state.config_dirs,
      else: ConfigDirs.list()
  end

  defp account_dirs(state) do
    cond do
      Keyword.has_key?(state.opts, :account_dirs) -> state.opts[:account_dirs]
      Keyword.has_key?(state.opts, :config_dirs) -> state.config_dirs
      true -> ConfigDirs.accounts()
    end
  end

  # `sprat status` / `sprat brief`: observe and detect, never route or act.
  defp passive?(state), do: Keyword.get(state.opts, :passive, false)

  # In the daemon the observers run as their own processes (spec-v5 §3) and
  # the engine only reads what they published; inline (tests, one-shot
  # commands) it runs the same observer code itself.
  defp observers?(state), do: Keyword.get(state.opts, :observers) == :processes

  defp observe_sessions(state) do
    if observers?(state),
      do: from_observers(state),
      else: state |> scan_sessions() |> tail_transcripts()
  end

  defp from_observers(state) do
    case Live.get(:sessions, :sessions) do
      nil ->
        state

      sessions ->
        state = %{state | sessions: sessions}

        Enum.reduce(Map.keys(sessions), state, fn sid, st ->
          case Live.get(:tails, sid) do
            %Tail{} = tail -> apply_tail(st, sid, tail)
            nil -> st
          end
        end)
    end
  end

  defp scan_sessions(state) do
    scan = Keyword.get(state.opts, :registry_fun, &Registry.scan/1)

    {sessions, cache} =
      SessionScan.scan(
        scan.(state.config_dirs),
        state.sessions,
        state.resolve_cache,
        state.surfaces,
        state.opts
      )

    %{state | sessions: sessions, resolve_cache: cache}
  end

  # Inline mode: each session's transcript is followed here (spec-v5: in the
  # daemon a SessionServer per session does this on its own timer).
  defp tail_transcripts(state) do
    Enum.reduce(state.sessions, state, fn {sid, s}, st ->
      tail = Map.get(st.tails, sid) || Tail.new(sid)

      case Tail.advance(tail, s.transcript_path) do
        :unchanged -> st
        {:changed, tail} -> apply_tail(st, sid, tail)
      end
    end)
  end

  @doc false
  # Takes one session's tail (from inline tailing or its SessionServer) into
  # the engine's view of that session.
  def apply_tail(state, sid, %Tail{} = tail) do
    session =
      case {Map.get(state.sessions, sid), tail.last_event_at} do
        {nil, _} -> nil
        {s, nil} -> s
        {s, at} -> %{s | last_activity_at: at}
      end

    %{
      state
      | states: Map.put(state.states, sid, tail.state),
        events: Map.put(state.events, sid, tail.events),
        tails: Map.put(state.tails, sid, tail),
        sessions: if(session, do: Map.put(state.sessions, sid, session), else: state.sessions)
    }
  end

  # A usage limit is per account: the newest limit seen in any session on an
  # account limits all of its sessions (§7.1). A background agent's limit
  # that resets later than the main thread's pushes the reset out.
  defp update_accounts(state, now) do
    accounts =
      Enum.reduce(state.sessions, state.accounts, fn {sid, s}, acc ->
        limit =
          case Map.get(state.states, sid) do
            %SState{} = st -> Sprat.Observer.Detector.effective_limit(s, st, now)
            _ -> nil
          end

        case limit do
          %{} = limit ->
            reset = limit_reset(limit, now)
            prev = Map.get(acc, s.config_dir, %Account{config_dir: s.config_dir})

            if reset && DateTime.compare(reset, now) == :gt &&
                 not before_login_change?(state, s.config_dir, limit) &&
                 (is_nil(prev.limited_until) or DateTime.compare(reset, prev.limited_until) != :eq) do
              a = %{
                prev
                | limited_until: reset,
                  limit_kind: limit_kind(limit),
                  limit_text: limit_text(limit),
                  login: Map.get(state.logins, s.config_dir),
                  limited_at: Map.get(limit, :at) || field_at(limit) || now
              }

              Store.put_account(state.store, a)
              Map.put(acc, s.config_dir, a)
            else
              acc
            end

          _ ->
            acc
        end
      end)

    %{state | accounts: share_by_login(accounts, state, now)}
  end

  # A limit hit before the dir switched login (`/login`) was the old login's.
  defp before_login_change?(state, dir, limit) do
    case {Map.get(state.login_changed_at, dir), Map.get(limit, :at) || field_at(limit)} do
      {%DateTime{} = changed, %DateTime{} = at} -> DateTime.compare(at, changed) == :lt
      _ -> false
    end
  end

  defp field_at(%{data: %{at: at}}), do: at
  defp field_at(_), do: nil

  # Two config dirs logged in to the same Claude account share its limit.
  defp share_by_login(accounts, state, now) do
    limited =
      for {_dir, %Account{login: l, limited_until: %DateTime{} = u} = a} <- accounts,
          is_binary(l),
          DateTime.compare(u, now) == :gt,
          into: %{},
          do: {l, a}

    Enum.reduce(state.logins, accounts, fn {dir, login}, acc ->
      prev = Map.get(acc, dir, %Account{config_dir: dir})

      case Map.get(limited, login) do
        %Account{config_dir: ^dir} ->
          acc

        %Account{} = src when is_nil(prev.limited_until) ->
          a = %{
            prev
            | limited_until: src.limited_until,
              limit_kind: src.limit_kind,
              limit_text: src.limit_text,
              login: login
          }

          Store.put_account(state.store, a)
          Map.put(acc, dir, a)

        _ ->
          acc
      end
    end)
  end

  # Each account dir's current login; when one changes, the time it changed.
  defp refresh_logins(state, now) do
    login_fun = Keyword.get(state.opts, :login_fun, &ConfigDirs.login/1)
    dirs = Enum.uniq(state.config_dirs ++ state.account_dirs ++ Map.keys(state.accounts))
    logins = Map.new(dirs, &{&1, login_fun.(&1)})

    changed =
      Enum.reduce(logins, state.login_changed_at, fn {dir, login}, acc ->
        before =
          Map.get(state.logins, dir) ||
            (Map.get(state.accounts, dir) || %Account{config_dir: dir}).login

        if is_binary(login) and is_binary(before) and login != before,
          do: Map.put(acc, dir, now),
          else: acc
      end)

    %{state | logins: logins, login_changed_at: changed}
  end

  # The reset instant was parsed against the limit record's own timestamp
  # (`SessionState.usage_limit.reset_at`). Re-parsing the text against `now`
  # would move "resets 11:50am" to tomorrow once 11:50 has passed and limit
  # the account for another day.
  defp limit_reset(limit, now) do
    data = event_data(limit)

    case data[:reset_at] || get_in(data, [:limit, :reset_at]) do
      %DateTime{} = r ->
        r

      _ ->
        with {:ok, %{reset_at: r}} <- UsageLimit.parse(data[:text] || data["text"] || "", now),
             do: r,
             else: (_ -> nil)
    end
  end

  defp limit_kind(limit) do
    data = event_data(limit)
    data[:kind] || get_in(data, [:limit, :kind])
  end

  defp limit_text(limit), do: event_data(limit)[:text]

  defp event_data(%{data: d}) when is_map(d), do: d
  defp event_data(d) when is_map(d), do: d
  defp event_data(_), do: %{}

  # -- detection ------------------------------------------------------------------

  defp detect(state, now) do
    projects = projects_with_sessions(state)

    input = %{
      now: now,
      projects: Map.values(projects),
      states: state.states,
      sessions: Map.values(state.sessions),
      accounts: Map.values(state.accounts)
    }

    found = Detector.detect(input)

    findings =
      Enum.reduce(found, state.findings, fn f, acc ->
        prev = Map.get(acc, f.id) || Store.get_finding(state.store, f.id)

        if is_nil(prev),
          do:
            Sprat.Activity.emit(:finding,
              type: :noticed,
              project_root: f.project_root,
              text: "noticed (#{f.rule}): " <> (f.summary || ""),
              status: :info
            )

        {:ok, stored} = Store.upsert_finding(state.store, with_engine_data(f, prev))
        Map.put(acc, stored.id, stored)
      end)

    # Findings that stopped matching are kept until the follow-up looks at them.
    live_ids = MapSet.new(found, & &1.id)

    findings =
      Map.new(findings, fn {id, f} ->
        {id, Map.put(f, :data, Map.put(f.data || %{}, :matching, MapSet.member?(live_ids, id)))}
      end)

    state = %{state | findings: findings, projects: projects}

    if passive?(state) do
      state
    else
      Enum.reduce(found, state, fn f, st ->
        stored = Map.fetch!(st.findings, f.id)
        route_new(st, stored, now)
      end)
    end
  end

  # Re-detection refreshes the rule's data but must keep what the engine
  # recorded on the finding (decision, proposal, owner note, nudge id, …).
  # A closed finding whose evidence changed reopens with a clean slate.
  defp with_engine_data(%Finding{} = f, nil), do: f

  defp with_engine_data(%Finding{} = f, %Finding{} = prev) do
    reopens? = prev.state in [:resolved, :dismissed] and prev.evidence != f.evidence

    if reopens?,
      do: f,
      else: %{f | data: Map.merge(prev.data || %{}, f.data || %{})}
  end

  defp projects_with_sessions(state) do
    by_root = state.sessions |> Map.values() |> Enum.group_by(& &1.project_root)

    Map.new(state.projects, fn {root, p} ->
      {root, %{p | sessions: Map.get(by_root, root, [])}}
    end)
  end

  # Decides what happens to a finding the first time it is open (§7, §8.1).
  defp route_new(state, %Finding{state: :open} = f, now) do
    cond do
      Map.has_key?(state.pm_running, f.id) or Enum.any?(state.pm_queue, &(&1 == f.id)) or
          Map.has_key?(state.holds, f.id) ->
        state

      f.rule == "Q1" ->
        schedule_limit(state, f, now)

      f.rule in ["W2", "W3"] ->
        escalate(state, f, "#{f.summary}", now)

      true ->
        %{state | pm_queue: state.pm_queue ++ [f.id]}
    end
  end

  defp route_new(state, _f, _now), do: state

  # -- usage-limit scheduler (§7.1) ---------------------------------------------------

  defp schedule_limit(state, %Finding{} = f, now) do
    # upsert_finding never changes an existing row's state; without this
    # the finding read back :open on every tick and was scheduled (and
    # logged) again every 2 seconds.
    {:ok, _} = Store.upsert_finding(state.store, f)
    Store.set_finding_state(state.store, f.id, :acted)
    state = put_finding(state, %{f | state: :acted})

    Store.log_event(
      state.store,
      :limit_scheduled,
      %{finding: f.id, reset_at: f.data[:reset_at]},
      now
    )

    state
  end

  defp run_scheduler(state, now) do
    Enum.reduce(state.accounts, state, fn {dir, %Account{} = a}, st ->
      login = Map.get(st.logins, dir)

      cond do
        is_nil(a.limited_until) ->
          st

        # Logged in to another account since the limit hit: carry on now.
        is_binary(a.login) and is_binary(login) and login != a.login ->
          resume_account(st, dir, a, now)

        # A session on this dir is working again before the reset (another
        # login, or the limit lifted early): the others can too.
        working_since?(st, dir, a.limited_at) ->
          resume_account(st, dir, a, now)

        DateTime.compare(DateTime.add(a.limited_until, 60, :second), now) == :gt ->
          st

        true ->
          resume_account(st, dir, a, now)
      end
    end)
  end

  # After the reset: continue the account's limited sessions one at a time,
  # highest-priority roadmap item first, `@resume_spacing_s` apart.
  defp resume_account(state, dir, %Account{} = a, now) do
    queue =
      case a.resume_queue do
        [_ | _] = q ->
          q

        _ ->
          state.findings
          |> Map.values()
          |> Enum.filter(
            &(&1.rule == "Q1" and &1.state in [:acted, :open] and session_dir(state, &1) == dir)
          )
          # One that is already working again (resumed by hand, another
          # login) needs no "your limit has reset".
          |> Enum.filter(&still_limited?(state, &1))
          |> Enum.sort_by(&priority(state, &1))
          |> Enum.map(& &1.id)
      end

    last = Store.get_setting(state.store, "last_resume_at:" <> dir)

    due? =
      case last do
        nil -> true
        iso -> DateTime.diff(now, parse_dt(iso)) >= @resume_spacing_s
      end

    case queue do
      [] ->
        clear_limit(state, dir, a)

      [fid | rest] when due? ->
        state = resume_limited(state, Map.get(state.findings, fid), now)
        Store.put_setting(state.store, "last_resume_at:" <> dir, DateTime.to_iso8601(now))
        a = %{a | resume_queue: rest}
        Store.put_account(state.store, a)
        state = %{state | accounts: Map.put(state.accounts, dir, a)}
        if rest == [], do: clear_limit(state, dir, a), else: state

      _ ->
        %{state | accounts: Map.put(state.accounts, dir, %{a | resume_queue: queue})}
    end
  end

  defp still_limited?(state, %Finding{session_id: sid}) do
    case Map.get(state.states, sid) do
      %SState{usage_limit: nil} -> false
      _ -> true
    end
  end

  defp working_since?(_state, _dir, nil), do: false

  defp working_since?(state, dir, %DateTime{} = since) do
    Enum.any?(state.sessions, fn {sid, s} ->
      s.config_dir == dir and s.live? and
        case Map.get(state.states, sid) do
          %SState{usage_limit: nil, last_assistant_at: %DateTime{} = at} ->
            DateTime.diff(at, since) > 60

          _ ->
            false
        end
    end)
  end

  defp clear_limit(state, dir, a) do
    a = %{
      a
      | limited_until: nil,
        limit_kind: nil,
        limit_text: nil,
        resume_queue: [],
        limited_at: nil
    }

    Store.put_account(state.store, a)
    %{state | accounts: Map.put(state.accounts, dir, a)}
  end

  defp resume_limited(state, nil, _now), do: state

  defp resume_limited(state, %Finding{} = f, now) do
    session = Map.get(state.sessions, f.session_id)
    project = Map.get(state.projects, f.project_root)
    text = limit_resume_text(state, f, "[sprat] Your usage limit has reset. Continue ")

    cond do
      session && session.live? ->
        deliver(state, f, session, text, :limit_resume, now)

      project && project.autonomy == :act_resume ->
        start_background(state, f, project, session, text, now)

      true ->
        propose(
          state,
          f,
          text,
          "the session ended while limited; start it again with this prompt",
          now
        )
    end
  end

  @doc """
  The prompt that continues a limited session: `lead` ("Your usage limit has
  reset. Continue "), the roadmap item, and the last step the agent reported.
  """
  def limit_resume_text(state, %Finding{} = f, lead) do
    session = Map.get(state.sessions, f.session_id)
    project = Map.get(state.projects, f.project_root)
    item = project && item_for(project, session)
    step = last_step(state, f.session_id)

    lead <>
      if(item, do: "with #{item.id} #{item.text} ", else: "") <>
      "from where you stopped" <> if(step, do: ": #{step}", else: ".") <> roadmap_suffix(item)
  end

  # -- other accounts --------------------------------------------------------------

  @doc """
  Accounts other than `except` that could work on the project at `root`
  now: a known account dir (symlinked twins included) that has this
  project's transcript folder and is not under a usage limit. Several
  accounts can work in the same folder; when one runs out, another can carry
  on. The project's own accounts come first.
  """
  def free_accounts(state, root, except, now, sid \\ nil) do
    state
    |> project_accounts(root)
    |> Enum.reject(&(&1 == except))
    |> Enum.reject(&limited_now?(Map.get(state.accounts, &1), now))
    # One that can read the session's transcript first: it forks the
    # conversation instead of starting over.
    |> Enum.sort_by(&if(sid && Transcript.locate(&1, sid), do: 0, else: 1))
  end

  @doc "Every known account that has worked on the project at `root` (has its transcript folder)."
  def project_accounts(state, root) do
    slug = Regex.replace(~r/[^A-Za-z0-9]/, root, "-")
    own = (Map.get(state.projects, root) || %{config_dirs: []}).config_dirs || []

    (own ++ Map.get(state, :account_dirs, []) ++ state.config_dirs)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?(Path.join([&1, "projects", slug])))
  end

  defp limited_now?(%Account{limited_until: %DateTime{} = u}, now),
    do: DateTime.compare(u, now) == :gt

  defp limited_now?(_, _), do: false

  @doc """
  Starts Claude on account `dir` in `root` (see `start_on_account/5`), then
  waits until the session really runs: a `<dir>/sessions/*.json` for `root`
  started after this call. A terminal that closed or a `claude` that exited
  is a failure, with what its terminal shows. `step.(text)` reports progress.
  """
  def start_and_confirm(root, dir, resume, text, step, opts \\ []) do
    since = System.os_time(:millisecond)
    step.("opening a cmux workspace for #{Path.basename(dir)}")

    case start_on_account(root, dir, resume, text, opts) do
      {:ok, where} ->
        step.(
          "waiting for Claude to start" <> if(resume, do: " and load the conversation", else: "")
        )

        case await_session(dir, root, since, opts) do
          {:ok, _sid} -> {:ok, where}
          :timeout -> {:error, not_started(where, opts)}
        end

      error ->
        error
    end
  end

  defp await_session(dir, root, since, opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :await_ms, 45_000)
    interval = Keyword.get(opts, :await_interval_ms, 1_000)
    do_await(dir, root, since, deadline, interval)
  end

  defp do_await(dir, root, since, deadline, interval) do
    found =
      dir
      |> Path.join("sessions/*.json")
      |> Path.wildcard()
      |> Enum.find_value(fn path ->
        with {:ok, bin} <- File.read(path),
             {:ok, %{"cwd" => ^root, "sessionId" => sid} = m} <- Jason.decode(bin),
             true <- (m["startedAt"] || 0) >= since - 2_000 do
          sid
        else
          _ -> nil
        end
      end)

    cond do
      found -> {:ok, found}
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> Process.sleep(interval) && do_await(dir, root, since, deadline, interval)
    end
  end

  defp not_started({:cmux, ws}, opts) when is_binary(ws) do
    cmux = Keyword.get_lazy(opts, :cmux_bin, &Surfaces.cmux_bin/0)
    run = Keyword.get(opts, :cmd, &Sprat.Cmd.run/3)

    shown =
      case cmux && run.(cmux, ["read-screen", "--workspace", ws, "--lines", "40"], timeout: 5_000) do
        {out, 0} ->
          out
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.take(-3)
          |> Enum.join(" / ")

        _ ->
          nil
      end

    if shown in [nil, ""],
      do: "Claude didn't start in cmux #{ws} (the workspace is gone or empty)",
      else: "Claude didn't start in cmux #{ws}; it shows: #{shown}"
  end

  defp not_started(_where, _opts), do: "the background session didn't start"

  @doc """
  Starts Claude in `root` on the account `dir`, in a new cmux workspace that
  gets focus so the owner can watch and type (`{:ok, {:cmux, "workspace:N"}}`),
  else as a background session (`{:ok, :background}`). With `resume`, the new
  session continues that conversation as a fork (the limited one keeps its
  id). The default account (`~/.claude`) runs without `CLAUDE_CONFIG_DIR`:
  setting it would move where Claude looks for its login.
  """
  def start_on_account(root, dir, resume, text, opts \\ []) do
    main = Path.join(System.user_home!(), ".claude")
    env = if dir == main, do: [], else: [{"CLAUDE_CONFIG_DIR", dir}]
    args = if resume, do: ["--resume", resume, "--fork-session", text], else: [text]
    name = "#{Path.basename(root)} · #{Path.basename(dir)}"
    cmux = Keyword.get_lazy(opts, :cmux_bin, &Surfaces.cmux_bin/0)
    run = Keyword.get(opts, :cmd, &Sprat.Cmd.run/3)

    cmux_result =
      if cmux do
        command = Enum.map_join(["claude" | args], " ", &shell_quote/1)

        run.(
          cmux,
          ["new-workspace", "--name", name, "--cwd", root, "--focus", "true"] ++
            Enum.flat_map(env, fn {k, v} -> ["--env", "#{k}=#{v}"] end) ++
            ["--command", command],
          timeout: 10_000
        )
      end

    case cmux_result do
      {out, 0} ->
        {:ok, {:cmux, workspace_ref(out)}}

      _ ->
        bin = System.find_executable("claude") || Path.expand("~/.local/bin/claude")

        case run.(bin, ["--bg" | args], cd: root, env: env, timeout: 30_000) do
          {_, 0} -> {:ok, :background}
          {out, code} -> {:error, "exit #{code}: #{String.slice(out, 0, 200)}"}
        end
    end
  end

  defp workspace_ref(out) do
    case Regex.run(~r/workspace:\d+/, out || "") do
      [ws] -> ws
      _ -> nil
    end
  end

  defp shell_quote(s) do
    if Regex.match?(~r/^[A-Za-z0-9_\-.\/=:]+$/, s),
      do: s,
      else: "'" <> String.replace(s, "'", ~S('\'')) <> "'"
  end

  defp last_step(state, sid) do
    state.events
    |> Map.get(sid, [])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{kind: :assistant_text, data: d} ->
        d[:text] && String.slice(String.replace(d[:text], ~r/\s+/, " "), 0, 200)

      _ ->
        nil
    end)
  end

  defp session_dir(state, %Finding{session_id: sid}),
    do: get_in(state.sessions, [sid, Access.key(:config_dir)])

  defp priority(state, %Finding{project_root: root}) do
    p = Map.get(state.projects, root)

    touched =
      p &&
        p.sessions
        |> Enum.map(& &1.last_activity_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)

    -((touched && DateTime.to_unix(touched)) || 0)
  end

  # -- PM runs -------------------------------------------------------------------------

  defp start_pm_runs(state, now) do
    limit = setting(state, "pm_concurrency")

    Enum.reduce_while(state.pm_queue, state, fn fid, st ->
      cond do
        map_size(st.pm_running) >= limit ->
          {:halt, st}

        true ->
          st = %{st | pm_queue: List.delete(st.pm_queue, fid)}
          {:cont, maybe_start_pm(st, Map.get(st.findings, fid), now)}
      end
    end)
  end

  defp maybe_start_pm(state, nil, _now), do: state

  defp maybe_start_pm(state, %Finding{} = f, now) do
    project = Map.get(state.projects, f.project_root)
    session = Map.get(state.sessions, f.session_id)
    account = (session && session.config_dir) || (project && List.first(project.config_dirs))
    acct = account && Map.get(state.accounts, account)

    cond do
      is_nil(project) ->
        state

      # It stopped matching while it waited (a hold, a limit): nothing to investigate.
      f.data[:matching] == false and f.state == :open ->
        Store.set_finding_state(state.store, f.id, :resolved)
        put_finding(state, %{f | state: :resolved})

      pm_disabled?(state) ->
        escalate(state, f, f.summary, now)

      acct && acct.limited_until && DateTime.compare(acct.limited_until, now) == :gt ->
        # The account is limited: PM runs pause with it (§7.1); retry later.
        hold(state, f.id, acct.limited_until)

      over_budget?(state, f.project_root, now) ->
        escalate(state, f, f.summary <> " (PM budget for today is spent)", now)

      true ->
        ctx = %{
          finding: f,
          project: project,
          session: session,
          state: Map.get(state.states, f.session_id),
          excerpt: excerpt(Map.get(state.events, f.session_id, [])),
          account: account
        }

        resume = pm_session_for_today(state, f.project_root, now)

        opts =
          [budget_usd: setting(state, "pm_budget_usd")] ++
            if(resume, do: [resume: resume], else: []) ++
            if(m = setting(state, "pm_model"), do: [model: m], else: [])

        pm_fun = Keyword.get(state.opts, :pm_fun, &Sprat.PM.Runner.run/2)

        task =
          Task.Supervisor.async_nolink(Sprat.Engine.TaskSupervisor, fn ->
            Sprat.Engine.ProcessMap.label("investigating " <> Path.basename(f.project_root))
            Sprat.Engine.ProcessMap.ref({:investigation, f.project_root})
            pm_fun.(ctx, opts)
          end)

        f2 = %{f | state: :pm_running}
        Store.upsert_finding(state.store, f2)
        Store.set_finding_state(state.store, f.id, :pm_running)
        Store.log_event(state.store, :pm_started, %{finding: f.id, rule: f.rule}, now)

        Sprat.Activity.emit(:pm,
          type: :started,
          project_root: f.project_root,
          text: "investigating: " <> (f.summary || f.rule),
          status: :running
        )

        state
        |> put_finding(f2)
        |> Map.update!(
          :pm_running,
          &Map.put(&1, f.id, %{ref: task.ref, started_at: now, run_id: "pm_" <> rand()})
        )
    end
  end

  defp pm_finished(state, fid, run, result) do
    now = now(state)
    state = %{state | pm_running: Map.delete(state.pm_running, fid)}
    f = Map.get(state.findings, fid)

    {decision, meta, error} =
      case result do
        {:ok, %Decision{} = d, meta} -> {d, meta, nil}
        {:error, reason, meta} -> {nil, meta || %{}, reason}
        other -> {nil, %{}, {:unexpected, other}}
      end

    Sprat.Activity.emit(:pm,
      type: if(error, do: :failed, else: :done),
      project_root: f && f.project_root,
      text:
        if(error,
          do: "investigation failed: #{short(error)}",
          else:
            "investigated: #{decision.action}" <>
              if(meta[:cost_usd],
                do: " · $#{:erlang.float_to_binary(meta[:cost_usd] / 1, decimals: 2)}",
                else: ""
              )
        ),
      status: if(error, do: :failed, else: :ok)
    )

    Store.record_pm_run(state.store, %{
      id: run.run_id,
      finding_id: fid,
      started_at: run.started_at,
      finished_at: now,
      decision: decision,
      cost_usd: meta[:cost_usd],
      turns: meta[:turns],
      session_id: meta[:session_id],
      sources: (decision && decision.evidence_used) || [],
      error: error && inspect(error)
    })

    state =
      if meta[:session_id] && f,
        do:
          put_in(
            state.pm_sessions[{f.project_root, Date.to_iso8601(DateTime.to_date(now))}],
            meta[:session_id]
          ),
        else: state

    cond do
      is_nil(f) ->
        state

      decision ->
        act(state, f, decision, run.run_id, now)

      true ->
        runs = Store.count_pm_runs(state.store, fid)

        if runs < 2,
          do: retry_pm(state, f),
          else:
            escalate(
              state,
              f,
              f.summary <> " (Sprat could not investigate: #{short(error)})",
              now
            )
    end
  end

  defp retry_pm(state, %Finding{} = f) do
    Store.set_finding_state(state.store, f.id, :open)
    %{put_finding(state, %{f | state: :open}) | pm_queue: state.pm_queue ++ [f.id]}
  end

  defp act(state, %Finding{} = f, %Decision{} = d, run_id, now) do
    project = Map.get(state.projects, f.project_root)
    session = Map.get(state.sessions, f.session_id)
    item = project && item_for(project, session, d.next_item)

    ctx = %{
      autonomy: (project && project.autonomy) || :propose,
      finding: f,
      session: session,
      now: now,
      ledger: Store.policy_ledger(state.store, f.id),
      budget: budget(state, f.project_root, now),
      owner_typing?: owner_typing?(state, session, now),
      item: item
    }

    state = record_decision(state, f, d, run_id)
    state = apply_done_items(state, f, d, run_id, now)
    # Act on the finding as just recorded, so what follows keeps the decision.
    f = Map.fetch!(state.findings, f.id)

    runs = ctx.ledger[:pm_runs_for_finding] || 0

    case Policy.authorize(d, ctx) do
      {:deliver, text} ->
        state = apply_roadmap_effects(state, f, d, run_id, now)

        case {d.action, session} do
          {:resume, _} -> start_background(state, f, project, session, text, now)
          {_, %Session{live?: true}} -> deliver(state, f, session, text, d.action, now)
          _ -> propose(state, f, text, "the session is not live", now)
        end
        |> owner_note(f, d, now)

      {:propose, reason} ->
        text = d.message && Policy.message_for(d, item)
        state |> propose(f, text, reason_text(reason, d), now) |> owner_note(f, d, now)

      {:escalate, reason} ->
        escalate(state, f, d.owner_note || d.obstacle || reason_text(reason, d), now, d)

      {:refuse, :no_evidence} when runs < 2 ->
        # §8.3: a decision that cites no evidence is discarded and retried once.
        retry_pm(state, f)

      {:refuse, reason} ->
        escalate(
          state,
          f,
          "Sprat refused its own plan (#{reason_text(reason, d)}): " <> (d.obstacle || f.summary),
          now,
          d
        )

      {:noop, {:hold, _why, retry_at}} ->
        hold(state, f.id, retry_at, d)

      {:noop, :wait} ->
        snooze(state, f, d.obstacle || "the agent is making progress", now)

      {:noop, _} ->
        # watch autonomy: investigated, acted on nothing.
        f2 = %{f | state: :escalated, data: Map.put(f.data || %{}, :watch_note, d.obstacle)}
        Store.set_finding_state(state.store, f.id, :escalated)
        put_finding(state, f2)
    end
  end

  defp record_decision(state, f, d, run_id) do
    f2 = %{f | data: Map.merge(f.data || %{}, %{decision: Map.from_struct(d), pm_run_id: run_id})}
    Store.upsert_finding(state.store, f2)
    put_finding(state, f2)
  end

  defp apply_roadmap_effects(
         state,
         f,
         %Decision{action: :reassign, blocked_item: id} = d,
         run_id,
         now
       )
       when is_binary(id) do
    case Roadmap.mark(f.project_root, id, :blocked, d.blocked_reason || d.obstacle) do
      {:ok, w} ->
        Store.record_write(state.store, %{
          id: "w_" <> rand(),
          project_root: f.project_root,
          item_id: id,
          from_state: to_string(w.from),
          to_state: "blocked",
          reason: w.reason,
          pm_run_id: run_id,
          at: now
        })

        invalidate_roadmap(state, f.project_root)

      {:error, _} ->
        state
    end
  end

  defp apply_roadmap_effects(state, _f, _d, _run_id, _now), do: state

  # §9.2: `done` ticks only when the PM cites a commit; only under act
  # autonomy; each one a revertible roadmap write shown on the ticket.
  defp apply_done_items(
         state,
         %Finding{} = f,
         %Decision{done_items: [_ | _] = ids} = d,
         run_id,
         now
       ) do
    project = Map.get(state.projects, f.project_root)
    commit? = Enum.any?(d.evidence_used, &String.starts_with?(&1, "commit:"))

    if project && project.autonomy in [:act, :act_resume] && commit? do
      Enum.reduce(ids, state, fn id, st ->
        case Roadmap.mark(
               f.project_root,
               id,
               :done,
               "verified by Sprat: " <> Enum.join(d.evidence_used, ", ")
             ) do
          {:ok, w} when w.from != :done ->
            Store.record_write(st.store, %{
              id: "w_" <> rand(),
              project_root: f.project_root,
              item_id: id,
              from_state: to_string(w.from),
              to_state: "done",
              reason: w.reason,
              pm_run_id: run_id,
              at: now
            })

            st
            |> served(
              f,
              "ticked #{id} done (#{Enum.find(d.evidence_used, &String.starts_with?(&1, "commit:"))})",
              now
            )
            |> invalidate_roadmap(f.project_root)

          _ ->
            st
        end
      end)
    else
      state
    end
  end

  defp apply_done_items(state, _f, _d, _run_id, _now), do: state

  defp owner_note(state, %Finding{} = f, %Decision{owner_note: note}, now) when is_binary(note) do
    f2 = Map.get(state.findings, f.id) || f
    f2 = %{f2 | data: Map.put(f2.data || %{}, :owner_note, note)}
    Store.upsert_finding(state.store, f2)
    Store.log_event(state.store, :owner_note, %{finding: f.id, note: note}, now)
    put_finding(state, f2)
  end

  defp owner_note(state, _f, _d, _now), do: state

  # -- acting -------------------------------------------------------------------------

  @doc false
  def deliver(state, %Finding{} = f, %Session{} = s, text, action, now) do
    deliver_fun = Keyword.get(state.opts, :deliver_fun, &Sprat.Nudge.Delivery.deliver/3)
    nid = "n_" <> rand()

    case deliver_fun.(s, text, []) do
      {:ok, adapter} ->
        Sprat.Activity.emit(:delivery,
          type: action,
          project_root: f.project_root,
          text:
            "sent to #{s.name || s.session_id} via #{adapter}: " <> String.slice(text, 0, 120),
          status: :ok
        )

        Store.record_nudge(state.store, %{
          id: nid,
          finding_id: f.id,
          session_id: s.session_id,
          text: text,
          adapter: to_string(adapter),
          state: "delivered",
          created_at: now,
          delivered_at: now
        })

        f2 = %{
          f
          | state: :acted,
            data: Map.merge(f.data || %{}, %{delivered_at: now, nudge_id: nid})
        }

        Store.upsert_finding(state.store, f2)
        Store.set_finding_state(state.store, f.id, :acted)

        if(action == :fired,
          do: owner_served(state, f, "you fired: " <> String.slice(text, 0, 80), now),
          else: served(state, f, served_text(action, f, text), now)
        )
        |> put_finding(f2)
        |> Map.update!(:follow_ups, &Map.put(&1, f.id, DateTime.add(now, @follow_up_s, :second)))
        |> Map.update!(:holds, &Map.delete(&1, f.id))

      {:hold, why} ->
        attempts = get_in(state.holds, [f.id, :attempts]) || 0

        if attempts == 0,
          do:
            Sprat.Activity.emit(:delivery,
              type: :held,
              project_root: f.project_root,
              text: "waiting to send to #{s.name || s.session_id}: #{short(why)}",
              status: :info
            )

        if attempts >= 15,
          do: propose(state, f, text, "couldn't deliver (#{why}) for 15 minutes", now),
          else:
            Map.update!(state, :holds, fn h ->
              Map.put(h, f.id, %{
                at: DateTime.add(now, 60, :second),
                attempts: attempts + 1,
                text: text,
                action: action
              })
            end)

      {:error, reason} ->
        Sprat.Activity.emit(:delivery,
          type: :failed,
          project_root: f.project_root,
          text: "couldn't send to #{s.name || s.session_id}: #{short(reason)}",
          status: :failed
        )

        propose(state, f, text, "delivery failed: #{short(reason)}", now)
    end
  end

  defp start_background(state, f, %Project{} = project, session, text, now) do
    bg = Keyword.get(state.opts, :background_fun, &start_claude_bg/3)
    account = (session && session.config_dir) || List.first(project.config_dirs)

    case bg.(project.root, text, account: account, resume: session && session.session_id) do
      :ok ->
        f2 = %{f | state: :acted}
        Store.set_finding_state(state.store, f.id, :acted)

        state
        |> served(f, "started a background session: " <> String.slice(text, 0, 80), now)
        |> put_finding(f2)
        |> Map.update!(:follow_ups, &Map.put(&1, f.id, DateTime.add(now, @follow_up_s, :second)))

      {:error, reason} ->
        propose(state, f, text, "could not start a session: #{short(reason)}", now)
    end
  end

  defp start_background(state, f, nil, _session, text, now),
    do: propose(state, f, text, "unknown project", now)

  defp start_claude_bg(root, text, opts) do
    env = if a = opts[:account], do: [{"CLAUDE_CONFIG_DIR", a}], else: []
    args = if r = opts[:resume], do: ["--bg", "--resume", r, text], else: ["--bg", text]
    bin = System.find_executable("claude") || Path.expand("~/.local/bin/claude")

    case Sprat.Cmd.run(bin, args, cd: root, env: env, timeout: 30_000) do
      {_, 0} -> :ok
      {out, code} -> {:error, "exit #{code}: #{String.slice(out, 0, 200)}"}
    end
  end

  @doc false
  def propose(state, %Finding{} = f, text, reason, now) do
    f2 = %{
      f
      | state: :escalated,
        data: Map.merge(f.data || %{}, %{proposal: text, proposal_reason: reason})
    }

    Store.upsert_finding(state.store, f2)
    Store.set_finding_state(state.store, f.id, :escalated)
    Store.log_event(state.store, :proposed, %{finding: f.id, reason: reason}, now)

    Sprat.Activity.emit(:finding,
      type: :proposed,
      project_root: f.project_root,
      text: "waiting for you to send it: #{reason}",
      status: :info
    )

    put_finding(state, f2)
  end

  @doc false
  def escalate(state, %Finding{} = f, note, now, decision \\ nil) do
    data = Map.merge(f.data || %{}, %{owner_note: note})
    data = if decision, do: Map.put(data, :decision, Map.from_struct(decision)), else: data
    f2 = %{f | state: :escalated, data: data}
    Store.upsert_finding(state.store, f2)
    Store.set_finding_state(state.store, f.id, :escalated)
    Store.log_event(state.store, :escalated, %{finding: f.id, note: note}, now)

    Sprat.Activity.emit(:finding,
      type: :escalated,
      project_root: f.project_root,
      text: "for you: #{String.slice(note || "", 0, 140)}",
      status: :info
    )

    put_finding(state, f2)
  end

  defp snooze(state, f, why, now) do
    f2 = %{
      f
      | state: :snoozed,
        data:
          Map.merge(f.data || %{}, %{
            snoozed_until: DateTime.add(now, @follow_up_s, :second),
            snooze_reason: why
          })
    }

    Store.upsert_finding(state.store, f2)
    Store.set_finding_state(state.store, f.id, :snoozed)
    put_finding(state, f2)
  end

  defp hold(state, fid, retry_at, decision \\ nil) do
    Map.update!(
      state,
      :holds,
      &Map.put(&1, fid, %{at: retry_at, attempts: 0, decision: decision})
    )
  end

  defp run_holds(state, now) do
    Enum.reduce(state.holds, state, fn {fid, h}, st ->
      if DateTime.compare(h.at, now) != :gt do
        st = %{st | holds: Map.delete(st.holds, fid)}
        f = Map.get(st.findings, fid)

        session = f && Map.get(st.sessions, f.session_id)

        cond do
          is_nil(f) ->
            st

          h[:text] && session && session.live? ->
            st
            |> deliver(f, session, h.text, h[:action] || :unblock, now)
            |> keep_attempts(fid, h)

          h[:decision] ->
            act(st, f, h.decision, f.data[:pm_run_id], now)

          true ->
            %{st | pm_queue: st.pm_queue ++ [fid]}
        end
      else
        st
      end
    end)
  end

  defp keep_attempts(state, fid, h) do
    case state.holds[fid] do
      nil -> state
      new -> put_in(state.holds[fid], %{new | attempts: max(new.attempts, h.attempts + 1)})
    end
  end

  # §9.4: 30 minutes after delivery, did it work?
  defp run_follow_ups(state, now) do
    Enum.reduce(state.follow_ups, state, fn {fid, due}, st ->
      if DateTime.compare(due, now) != :gt do
        st = %{st | follow_ups: Map.delete(st.follow_ups, fid)}
        f = Map.get(st.findings, fid)

        cond do
          is_nil(f) ->
            st

          f.data[:matching] == false ->
            Store.set_finding_state(st.store, fid, :resolved)

            if nid = f.data[:nudge_id],
              do: Store.update_nudge(st.store, nid, %{outcome: "resolved", outcome_at: now})

            st
            |> served(f, "resolved: " <> (f.summary || f.rule), now)
            |> put_finding(%{f | state: :resolved})

          f.rule == "Q1" ->
            # Still limited after the resume: the scheduler handles the next
            # reset; a usage limit never goes to the PM.
            st

          Store.count_pm_runs(st.store, fid) >= 3 ->
            if nid = f.data[:nudge_id],
              do: Store.update_nudge(st.store, nid, %{outcome: "unresolved", outcome_at: now})

            escalate(st, f, "still stuck after 3 tries: " <> (f.summary || f.rule), now)

          true ->
            if nid = f.data[:nudge_id],
              do: Store.update_nudge(st.store, nid, %{outcome: "unresolved", outcome_at: now})

            %{put_finding(st, %{f | state: :open}) | pm_queue: st.pm_queue ++ [fid]}
        end
      else
        st
      end
    end)
  end

  defp served(state, %Finding{} = f, text, now) do
    name = project_name(state, f.project_root)
    s = %Served{at: now, project_name: name, text: text, by: :sprat, ref: f.id}
    Store.record_served(state.store, s, f.project_root)
    Sprat.Activity.emit(:served, project_root: f.project_root, text: text, status: :ok)
    state
  end

  defp owner_served(state, %Finding{} = f, text, now) do
    name = project_name(state, f.project_root)
    s = %Served{at: now, project_name: name, text: text, by: :owner, ref: f.id}
    Store.record_served(state.store, s, f.project_root)
    state
  end

  defp served_text(:limit_resume, _f, _text), do: "resumed after the usage limit reset"
  defp served_text(:answer, f, _text), do: "answered the agent's question (#{f.rule})"
  defp served_text(:reassign, f, _text), do: "reassigned the agent: #{f.summary}"
  defp served_text(:resume, _f, _text), do: "resumed the project"
  defp served_text(_, f, _text), do: "unblocked: #{f.summary}"

  # -- notifications -------------------------------------------------------------------

  defp notify_new_yours(state) do
    yours =
      state.findings
      |> Map.values()
      |> Enum.filter(&(&1.state == :escalated))
      |> Enum.reject(&MapSet.member?(state.notified, &1.id))

    if yours != [] and setting(state, "notify") do
      notify = Keyword.get(state.opts, :notify_fun, &Sprat.Engine.Notifier.notify/2)

      Enum.each(yours, fn f ->
        notify.(
          "Sprat · #{project_name(state, f.project_root)}",
          f.data[:owner_note] || f.summary || f.rule
        )
      end)
    end

    %{state | notified: Enum.reduce(yours, state.notified, &MapSet.put(&2, &1.id))}
  end

  # -- slow tick: roadmaps, progress, surfaces, autonomy ------------------------------

  defp slow(state) do
    now = now(state)
    {surfaces, cmux} = observe_cmux(state)
    {config_dirs, account_dirs} = observe_accounts(state)

    state = %{
      state
      | surfaces: surfaces,
        cmux: cmux,
        last_slow: now,
        config_dirs: config_dirs,
        account_dirs: account_dirs
    }

    state = refresh_logins(state, now)

    sessions =
      Map.new(state.sessions, fn {sid, s} ->
        {sid, %{s | surface: Map.get(state.surfaces, s.pid) || s.surface}}
      end)

    state = %{state | sessions: sessions}

    roots =
      sessions
      |> Map.values()
      |> Enum.filter(&(&1.project_root && (&1.live? or recent?(&1, now))))
      |> Enum.map(& &1.project_root)
      |> Enum.concat(Map.keys(state.projects))
      |> Enum.concat(extra_projects(state))
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)

    stored = Store.get_projects(state.store) |> Map.new(&{&1.root, &1})

    # A project whose roadmap its ProjectServer has not loaded yet keeps its
    # last state, or waits for the next tick if it is new.
    refreshed =
      Enum.flat_map(roots, fn root ->
        case refresh_project(state, root, Map.get(stored, root), now) do
          nil ->
            case {Map.get(state.projects, root), Map.get(state.roadmaps, root)} do
              {%Project{} = p, cache} -> [{root, {p, cache}}]
              _ -> []
            end

          result ->
            [{root, result}]
        end
      end)

    projects =
      refreshed
      |> Enum.map(fn {root, {p, _cache}} -> {root, p} end)
      |> Enum.reject(fn {_root, p} -> p.archived? end)
      |> Map.new()

    roadmaps = Map.new(refreshed, fn {root, {_p, cache}} -> {root, cache} end)

    %{state | projects: projects, roadmaps: roadmaps}
  end

  defp unknown_project?(state) do
    Enum.any?(Map.values(state.sessions), fn s ->
      s.live? and is_binary(s.project_root) and not Map.has_key?(state.projects, s.project_root) and
        File.dir?(s.project_root)
    end)
  end

  defp observe_cmux(state) do
    if observers?(state) do
      Sprat.Observer.Cmux.latest() || {state.surfaces, state.cmux}
    else
      pids = for {_sid, %{live?: true, pid: pid}} <- state.sessions, is_integer(pid), do: pid
      surfaces_fun = Keyword.get(state.opts, :surfaces_fun, fn -> Surfaces.scan(pids: pids) end)

      # A failed `cmux top` keeps the surfaces already known; `cmux` says why
      # for the header.
      case surfaces_fun.() do
        {:ok, m} -> {m, :ok}
        {:error, :no_cmux} -> {%{}, :absent}
        {:error, reason} -> {state.surfaces, reason}
        m when is_map(m) -> {m, :ok}
      end
    end
  end

  defp observe_accounts(state) do
    cond do
      not observers?(state) ->
        {config_dirs(state), account_dirs(state)}

      dirs = Sprat.Observer.Accounts.latest() ->
        {dirs.config_dirs, dirs.account_dirs}

      # Not found yet: keep what is known rather than run `ps -E` here.
      true ->
        {state.config_dirs, state.account_dirs}
    end
  end

  defp extra_projects(state) do
    case Store.get_setting(state.store, "extra_projects") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp recent?(%Session{last_activity_at: nil}, _now), do: false
  defp recent?(%Session{last_activity_at: at}, now), do: DateTime.diff(now, at) < 7 * 86_400

  defp refresh_project(state, root, stored, now) do
    base =
      stored ||
        %Project{root: root, name: Path.basename(root), autonomy: :propose, first_seen_at: now}

    base = if is_nil(stored), do: tap(base, &Store.upsert_project(state.store, &1)), else: base
    base = if passive?(state), do: base, else: promote_autonomy(state, base, now)

    case roadmap_entry(state, root, now) do
      nil -> nil
      entry -> build_project(state, base, root, entry, now)
    end
  end

  defp build_project(state, base, root, entry, now) do
    %{roadmap: roadmap, events: events} = entry

    position = Position.compute(roadmap, events, now)

    config_dirs =
      state.sessions
      |> Map.values()
      |> Enum.filter(&(&1.project_root == root))
      |> Enum.map(& &1.config_dir)
      |> Enum.uniq()

    pause_at =
      case File.stat(Path.join([root, "docs", "PAUSE.md"]), time: :posix) do
        {:ok, %{mtime: m}} -> DateTime.from_unix!(m)
        _ -> nil
      end

    project = %{
      base
      | roadmap: roadmap,
        position: position,
        config_dirs: Enum.uniq(config_dirs ++ (base.config_dirs || [])),
        pause_md_at: pause_at
    }

    {project, entry}
  end

  defp roadmap_entry(state, root, now) do
    if observers?(state) do
      Sprat.Observer.ProjectServer.ensure(root, state.opts)
      Sprat.Observer.ProjectServer.entry(root) || Map.get(state.roadmaps, root)
    else
      RoadmapCache.current(Map.get(state.roadmaps, root), root, now)
    end
  end

  @doc false
  # The owner wrote or edited the roadmap: load it again.
  def invalidate_roadmap(state, root) do
    if observers?(state), do: Sprat.Observer.ProjectServer.reload(root)
    %{state | roadmaps: Map.delete(state.roadmaps, root)}
  end

  # New projects start in `propose`; after their first day Sprat moves them to
  # `act` unless the owner chose a level (§9.1).
  defp promote_autonomy(
         state,
         %Project{autonomy: :propose, first_seen_at: %DateTime{} = first} = p,
         now
       ) do
    owner_set? = match?(%{by: "owner"}, Store.autonomy_change(state.store, p.root))

    if not owner_set? and DateTime.diff(now, first) >= @first_day_s do
      Store.set_autonomy(state.store, p.root, :act, "sprat", now)
      %{p | autonomy: :act}
    else
      p
    end
  end

  defp promote_autonomy(_state, p, _now), do: p

  # -- helpers ------------------------------------------------------------------------

  @doc false
  def put_finding(state, %Finding{} = f),
    do: %{state | findings: Map.put(state.findings, f.id, f)}

  defp item_for(project, session, preferred_id \\ nil)

  defp item_for(%Project{roadmap: nil}, _session, _id), do: nil

  defp item_for(%Project{roadmap: rm} = p, session, id) do
    (id && Roadmap.find_item(rm, id)) || (session && Detector.bound_item(p, session)) ||
      (p.position && p.position.item_id && Roadmap.find_item(rm, p.position.item_id))
  end

  defp roadmap_suffix(nil), do: ""
  defp roadmap_suffix(item), do: " (roadmap: #{item.id} #{item.text})"

  defp excerpt(events) do
    events
    |> Enum.take(-60)
    |> Sprat.Engine.Snapshot.session_lines()
    |> Enum.map_join("\n", fn l ->
      "#{l.at && Calendar.strftime(l.at, "%H:%M")} #{l.kind} #{l.text}"
    end)
  end

  defp owner_typing?(_state, nil, _now), do: false

  defp owner_typing?(state, %Session{session_id: sid}, now) do
    case Map.get(state.states, sid) do
      %SState{last_user_at: %DateTime{} = at, last_user_text: t} when is_binary(t) ->
        DateTime.diff(now, at) < 120 and not String.starts_with?(t, "[sprat]")

      _ ->
        false
    end
  end

  defp budget(state, root, now) do
    %{
      project_spent_today: Store.spend_today(state.store, root, now),
      project_cap: setting(state, "project_cap_usd"),
      fleet_spent_today: Store.spend_today(state.store, :fleet, now),
      fleet_cap: setting(state, "fleet_cap_usd")
    }
  end

  defp over_budget?(state, root, now) do
    b = budget(state, root, now)
    b.project_spent_today >= b.project_cap or b.fleet_spent_today >= b.fleet_cap
  end

  defp pm_session_for_today(state, root, now),
    do: Map.get(state.pm_sessions, {root, Date.to_iso8601(DateTime.to_date(now))})

  defp pm_disabled?(state),
    do:
      Keyword.get(state.opts, :pm_disabled, System.get_env("SPRAT_PM_DISABLED") in ["1", "true"])

  @doc false
  def setting(state, key) do
    case Store.get_setting(state.store, key) do
      nil -> Map.get(@default_settings, key)
      v -> v
    end
  end

  defp load_accounts(store) do
    store |> Store.get_accounts() |> Map.new(&{&1.config_dir, &1})
  rescue
    _ -> %{}
  end

  defp project_name(state, root) do
    case Map.get(state.projects, root) do
      %Project{name: n} when is_binary(n) -> n
      _ -> root && Path.basename(root)
    end
  end

  defp reason_text(reason, %Decision{} = d) do
    case reason do
      r when is_binary(r) -> r
      {:owner_only, cat} -> "it would need the owner (#{cat})"
      :low_confidence -> "low confidence"
      :autonomy -> "this project is set to propose"
      :budget -> "the PM budget is spent"
      other -> d.obstacle || inspect(other)
    end
  end

  defp short(nil), do: "unknown"
  defp short(r) when is_binary(r), do: String.slice(r, 0, 120)
  defp short(r), do: r |> inspect() |> String.slice(0, 120)

  defp parse_dt(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp rand, do: :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)

  @doc false
  def now(state) do
    case Keyword.get(state.opts, :now_fun) do
      nil -> DateTime.utc_now()
      fun -> fun.()
    end
  end
end
