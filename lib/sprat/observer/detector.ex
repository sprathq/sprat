defmodule Sprat.Observer.Detector do
  @moduledoc """
  The stall detector (spec §7): pure rules over the observer's projections.

  `detect/2` takes everything the rules read and returns `%Finding{}`s. No I/O,
  no clock: `now` comes in with the input, so the same input always yields the
  same findings with the same ids.

  ## Rules

  | Id | Kind | Fires when |
  |----|------|------------|
  | W1 | `:needs_you` | idle, last turn asks the user (or a pending `AskUserQuestion`), > `w1_idle` |
  | W2 | `:needs_you` | a non-question `tool_use` has no result, idle > `w2_idle` |
  | W3 | `:needs_you` | ≥ `w3_min_errors` non-limit API errors in the last `w3_window` assistant records |
  | Q1 | `:scheduled` | the session's last assistant record is a usage limit, or a background agent failed on one that has not reset (the later reset wins) |
  | L1 | `:stuck` | one error signature ≥ `l1_min_repeats` times within `l1_window`, no edit between first and last |
  | L2 | `:stuck` | one file edited ≥ `l2_min_edits` times within `l2_window` while the last test failed |
  | L3 | `:stuck` | busy > `l3_busy` with no edit, commit or roadmap tick in that time |
  | P1 | `:stalled` | active item, no progress for `p1_no_progress`, no live session bound to it |
  | P2 | `:stalled` | session ended with a dirty tree or its branch-bound item unfinished, no newer PAUSE.md |
  | P3 | `:stalled` | last assistant text claims done while the bound item is unticked or the last test failed |
  | P4 | `:stalled` | idle > `p4_idle`, last turn not a question, bound item not done |

  ## Conventions

  - **Binding.** A session is bound to the roadmap item whose `branch` equals the
    session's branch, else to the project position's active item.
  - **Owner typing.** A `user_text` in the session within `owner_quiet` of `now`
    suppresses every rule for that session.
  - **Idle/busy since.** `session.status_since`, falling back to the session
    state's `last_event_at`. When neither is known the duration is unknown and
    the time-based rules do not fire (spec §7: unknown stays unknown).
  - **Live rules** (W*, L*, P3, P4) only look at live sessions; P2 only at ended
    ones; Q1 at any session whose limit has not been stale for a day.
  - **Limited accounts.** A session on an account with `limited_until > now` is
    paused by the limit (§7.1), so L3 and P4 do not fire for it.
  - **Ids.** `"<rule>-<16 hex>"`, a hash of rule, session id (or project root)
    and a rule-specific evidence key, so re-detection yields the same id.
  - **Evidence.** Every finding carries at least one evidence id:
    `"transcript:<sid>:<line>"` for session rules, `"roadmap:<item id>"` for P1.
  """

  alias Sprat.Observer.Model.{Account, Finding, Item, Project, Session, SessionState}

  @minute 60
  @hour 3600

  @doc """
  Default thresholds. Durations are in seconds. Pass a map with any subset of
  these keys to `detect/2` to override.
  """
  def default_settings do
    %{
      owner_quiet: 2 * @minute,
      w1_idle: 10 * @minute,
      w2_idle: 5 * @minute,
      w3_min_errors: 2,
      w3_window: 10,
      l1_min_repeats: 3,
      l1_window: 30 * @minute,
      l2_min_edits: 6,
      l2_window: 20 * @minute,
      l3_busy: 45 * @minute,
      p1_no_progress: 48 * @hour,
      p4_idle: 30 * @minute,
      q1_stale_after: 24 * @hour
    }
  end

  @type input :: %{
          now: DateTime.t(),
          projects: [Project.t()],
          states: %{String.t() => SessionState.t()},
          sessions: [Session.t()],
          accounts: [Account.t()]
        }

  @doc "Runs every rule over `input`. Findings are sorted by id."
  @spec detect(input(), map()) :: [Finding.t()]
  def detect(input, settings \\ default_settings()) do
    settings = Map.merge(default_settings(), settings)
    now = input.now
    projects = Map.get(input, :projects, [])
    sessions = Map.get(input, :sessions, [])
    states = Map.get(input, :states, %{})
    accounts = Map.get(input, :accounts, [])

    projects_by_root =
      projects |> Enum.reject(& &1.archived?) |> Map.new(&{&1.root, &1})

    limited_dirs =
      for %Account{limited_until: %DateTime{} = until, config_dir: dir} <- accounts,
          DateTime.compare(until, now) == :gt,
          into: MapSet.new(),
          do: dir

    ctx = %{
      now: now,
      s: settings,
      projects: projects_by_root,
      sessions: sessions,
      accounts: accounts,
      limited_dirs: limited_dirs
    }

    session_findings =
      for %Session{} = session <- sessions,
          project = Map.get(projects_by_root, session.project_root),
          project != nil,
          state = Map.get(states, session.session_id, %SessionState{}),
          not owner_typing?(state, ctx),
          finding <- session_rules(session, state, project, ctx),
          do: finding

    project_findings =
      for project <- Map.values(projects_by_root),
          finding <- p1(project, ctx),
          do: finding

    (session_findings ++ project_findings)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.id)
  end

  # ── per-session rules ────────────────────────────────────────────────────

  defp session_rules(session, state, project, ctx) do
    item = bound_item(project, session)

    if live?(session) do
      [
        w1(session, state, ctx),
        w2(session, state, ctx),
        w3(session, state, ctx),
        q1(session, state, ctx),
        l1(session, state, ctx),
        l2(session, state, ctx),
        l3(session, state, project, ctx),
        p3(session, state, item),
        p4(session, state, item, ctx)
      ]
    else
      [q1(session, state, ctx), p2(session, state, project, item, ctx)]
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&stamp(&1, ctx.now))
  end

  defp w1(session, state, ctx) do
    question_tools =
      state.pending_tool_uses |> Map.values() |> Enum.filter(&question_tool?/1)

    asks? = state.asks_user? == true or question_tools != []

    with true <- asks?,
         :idle <- session.status,
         true <- idle_for?(session, state, ctx.s.w1_idle, ctx.now) do
      line = question_line(state)

      lines =
        [state.last_assistant_line | Enum.map(question_tools, &field(&1, :line))]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      finding(session, "W1", :needs_you, line || "question",
        summary: "waiting on you: " <> (line || "question pending"),
        evidence: evidence(session, lines, state),
        data: %{question: line}
      )
    else
      _ -> nil
    end
  end

  defp w2(session, state, ctx) do
    pending =
      state.pending_tool_uses
      |> Enum.reject(fn {_id, ev} -> question_tool?(ev) end)
      |> Enum.sort_by(fn {id, _} -> id end)

    with [_ | _] <- pending,
         :idle <- session.status,
         true <- idle_for?(session, state, ctx.s.w2_idle, ctx.now) do
      ids = Enum.map(pending, &elem(&1, 0))
      names = pending |> Enum.map(fn {_, ev} -> tool_name(ev) end) |> Enum.uniq()
      lines = Enum.map(pending, fn {_, ev} -> field(ev, :line) end)

      finding(session, "W2", :needs_you, Enum.join(ids, ","),
        summary: "permission prompt: " <> Enum.join(names, ", "),
        evidence: evidence(session, lines, state),
        data: %{tool_use_ids: ids, tools: names}
      )
    else
      _ -> nil
    end
  end

  defp w3(session, state, ctx) do
    window = (state.recent_assistant_lines || []) |> Enum.take(ctx.s.w3_window)

    errors =
      state.api_errors
      |> List.wrap()
      |> Enum.reject(&limit_error?/1)
      |> then(fn errs ->
        case window do
          [] ->
            errs

          lines ->
            min_line = Enum.min(lines)
            Enum.filter(errs, &((field(&1, :line) || 0) >= min_line))
        end
      end)

    if length(errors) >= ctx.s.w3_min_errors do
      lines = errors |> Enum.map(&field(&1, :line)) |> Enum.reject(&is_nil/1) |> Enum.sort()
      statuses = errors |> Enum.map(&field(&1, :status)) |> Enum.uniq()

      finding(session, "W3", :needs_you, Enum.join(lines, ","),
        summary:
          "api errors: #{length(errors)} in recent turns (#{Enum.map_join(statuses, ", ", &to_string/1)})",
        evidence: evidence(session, lines, state),
        data: %{count: length(errors), statuses: statuses}
      )
    end
  end

  defp q1(session, %SessionState{} = state, ctx) do
    case effective_limit(session, state, ctx.now) do
      nil -> nil
      limit -> q1_finding(session, state, limit, ctx)
    end
  end

  defp q1_finding(session, state, limit, ctx) do
    account = Enum.find(ctx.accounts, &(&1.config_dir == session.config_dir))

    reset_at =
      field(limit, :reset_at) ||
        (account && account.limited_until)

    stale? =
      match?(%DateTime{}, reset_at) and
        DateTime.diff(ctx.now, reset_at) > ctx.s.q1_stale_after

    if stale? do
      nil
    else
      limit_kind =
        field(limit, :limit_kind) || field(limit, :kind) ||
          (account && account.limit_kind)

      line = field(limit, :line)
      who = if limit[:agents?], do: "agents' usage limit", else: "usage limit"

      finding(session, "Q1", :scheduled, "#{line}",
        summary:
          case reset_at do
            %DateTime{} = at -> "#{who} · resets #{Calendar.strftime(at, "%H:%M")}"
            _ -> "#{who} · reset unknown"
          end,
        evidence: evidence(session, [line], state),
        data:
          Map.merge(
            %{reset_at: reset_at, limit_kind: limit_kind, account: session.config_dir},
            if(limit[:agents?], do: %{agents?: true}, else: %{})
          )
      )
    end
  end

  # The limit that pauses a session. The main thread's own, unless a
  # background agent hit one that resets later (resuming at the earlier reset
  # would only fail the agents again); or, with no main-thread limit, an
  # agent's that has not reset yet while the session sits idle.
  @doc false
  def effective_limit(session, %SessionState{usage_limit: main} = state, now) do
    agent =
      case Map.get(state, :agent_limit) do
        %{reset_at: %DateTime{} = r} = a -> if DateTime.compare(r, now) == :gt, do: a
        _ -> nil
      end

    main = main && plain_limit(main)

    cond do
      main && agent && later?(agent.reset_at, main.reset_at) ->
        %{main | reset_at: agent.reset_at, kind: agent.kind, agents?: true}

      main ->
        main

      agent && session.status == :idle ->
        agent |> Map.put(:agents?, true) |> Map.put(:limit_kind, nil)

      true ->
        nil
    end
  end

  defp plain_limit(limit) do
    %{
      line: field(limit, :line),
      at: field(limit, :at),
      reset_at: field(limit, :reset_at),
      kind: field(limit, :kind),
      limit_kind: field(limit, :limit_kind),
      text: field(limit, :text),
      agents?: false
    }
  end

  defp later?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :gt
  defp later?(%DateTime{}, nil), do: true
  defp later?(_, _), do: false

  defp l1(session, state, ctx) do
    since = DateTime.add(ctx.now, -ctx.s.l1_window)

    state.recent_results
    |> List.wrap()
    |> Enum.filter(fn r ->
      field(r, :is_error) == true and is_binary(field(r, :signature)) and
        after?(field(r, :at), since)
    end)
    |> Enum.group_by(&field(&1, :signature))
    |> Enum.filter(fn {_sig, rs} -> length(rs) >= ctx.s.l1_min_repeats end)
    |> Enum.filter(fn {_sig, rs} -> no_edit_between?(rs, state) end)
    |> Enum.sort_by(fn {sig, _} -> sig end)
    |> Enum.map(fn {sig, rs} ->
      lines = rs |> Enum.map(&field(&1, :line)) |> Enum.sort()

      finding(session, "L1", :stuck, sig,
        summary: "error loop: #{length(rs)}× #{sig}",
        evidence: evidence(session, lines, state),
        data: %{signature: sig, count: length(rs)}
      )
    end)
    |> List.first()
  end

  defp no_edit_between?(results, state) do
    lines = Enum.map(results, &field(&1, :line))
    {first, last} = Enum.min_max(lines)

    not Enum.any?(List.wrap(state.recent_edits), fn e ->
      l = field(e, :line)
      is_integer(l) and l > first and l < last
    end)
  end

  defp l2(session, state, ctx) do
    since = DateTime.add(ctx.now, -ctx.s.l2_window)

    if state.last_test_failed? == true do
      state.recent_edits
      |> List.wrap()
      |> Enum.filter(&after?(field(&1, :at), since))
      |> Enum.group_by(&field(&1, :path))
      |> Enum.filter(fn {path, es} -> is_binary(path) and length(es) >= ctx.s.l2_min_edits end)
      |> Enum.sort_by(fn {path, es} -> {-length(es), path} end)
      |> Enum.map(fn {path, es} ->
        lines = es |> Enum.map(&field(&1, :line)) |> Enum.sort()

        finding(session, "L2", :stuck, path,
          summary: "edit churn: #{path} edited #{length(es)}× while tests fail",
          evidence: evidence(session, lines, state) ++ ["file:" <> path],
          data: %{path: path, count: length(es)}
        )
      end)
      |> List.first()
    end
  end

  defp l3(session, state, project, ctx) do
    with :busy <- session.status,
         false <- limited?(session, ctx),
         %DateTime{} = since <- session.status_since || state.last_event_at,
         true <- DateTime.diff(ctx.now, since) > ctx.s.l3_busy do
      cutoff = DateTime.add(ctx.now, -ctx.s.l3_busy)

      last_edit_at =
        state.recent_edits |> List.wrap() |> Enum.map(&field(&1, :at)) |> latest()

      tick_at = project.position && project.position.last_progress_at

      if Enum.any?([last_edit_at, state.last_commit_at, tick_at], &after?(&1, cutoff)) do
        nil
      else
        mins = div(DateTime.diff(ctx.now, since), 60)

        finding(session, "L3", :stuck, DateTime.to_iso8601(since),
          summary: "spinning: busy #{mins}m with no file change, commit or tick",
          evidence: evidence(session, [state.last_event_line], state),
          data: %{busy_since: since}
        )
      end
    else
      _ -> nil
    end
  end

  defp p3(session, state, item) do
    text = state.last_assistant_text

    # Only an item bound to the session's own branch counts: comparing a
    # worktree's "done" with the project's overall position was wrong in
    # practice (real-machine run, 23 Nov: 6 of 8 hits were other tasks).
    item =
      if item != nil and item.branch != nil and item.branch == session.branch, do: item, else: nil

    with true <- is_binary(text) and claims_done?(text),
         true <- (item != nil and item.state != :done) or state.last_test_failed? == true do
      why =
        cond do
          state.last_test_failed? == true -> "last test run failed"
          true -> "#{item.id} is not ticked"
        end

      finding(session, "P3", :stalled, "#{state.last_assistant_line}",
        summary: "claimed done, not done: #{why}",
        evidence: evidence(session, [state.last_assistant_line], state),
        data: %{item_id: item && item.id, last_test_failed?: state.last_test_failed? == true}
      )
    else
      _ -> nil
    end
  end

  defp p4(session, state, item, ctx) do
    with :idle <- session.status,
         false <- state.asks_user? == true,
         false <- limited?(session, ctx),
         true <- effective_limit(session, state, ctx.now) == nil,
         true <- map_size(state.pending_tool_uses || %{}) == 0,
         %Item{state: item_state} when item_state != :done <- item,
         true <- idle_for?(session, state, ctx.s.p4_idle, ctx.now) do
      finding(session, "P4", :stalled, "#{state.last_assistant_line}",
        summary: "idle with work left on #{item.id} #{item.text}",
        evidence: evidence(session, [state.last_assistant_line], state),
        data: %{item_id: item.id}
      )
    else
      _ -> nil
    end
  end

  defp p2(session, state, project, item, ctx) do
    last_activity = session.last_activity_at || state.last_event_at
    branch_item? = item != nil and session.branch != nil and item.branch == session.branch
    work_left? = session.dirty? == true or (branch_item? and item.state != :done)

    with true <- work_left?,
         %DateTime{} <- last_activity,
         false <- pause_newer?(project, last_activity),
         false <- superseded?(session, last_activity, project, item, ctx) do
      why =
        cond do
          session.dirty? == true -> "uncommitted changes"
          true -> "#{item.id} unfinished"
        end

      finding(session, "P2", :stalled, DateTime.to_iso8601(last_activity),
        summary: "left mid-step: #{why}, no PAUSE.md since",
        evidence: evidence(session, [state.last_event_line], state),
        data: %{item_id: item && item.id, dirty?: session.dirty? == true}
      )
    else
      _ -> nil
    end
  end

  defp pause_newer?(%Project{pause_md_at: %DateTime{} = at}, last_activity),
    do: DateTime.compare(at, last_activity) == :gt

  defp pause_newer?(_project, _last_activity), do: false

  # Another session on the same branch (or bound to the same item) that is live
  # or more recently active has picked the work up.
  defp superseded?(session, last_activity, project, item, ctx) do
    Enum.any?(ctx.sessions, fn other ->
      other.session_id != session.session_id and other.project_root == session.project_root and
        same_work?(other, session, project, item) and
        (live?(other) or after?(other.last_activity_at, last_activity))
    end)
  end

  defp same_work?(other, session, project, item) do
    (session.branch != nil and other.branch == session.branch) or
      (item != nil and match?(%Item{}, bound_item(project, other)) and
         bound_item(project, other).id == item.id)
  end

  # ── per-project rules ────────────────────────────────────────────────────

  defp p1(%Project{position: %{item_id: item_id} = pos} = project, ctx)
       when is_binary(item_id) do
    last = pos.last_progress_at || project.first_seen_at

    with false <- pos.all_done? == true,
         %DateTime{} <- last,
         true <- DateTime.diff(ctx.now, last) > ctx.s.p1_no_progress,
         false <- live_session_on?(project, item_id, ctx) do
      hours = div(DateTime.diff(ctx.now, last), 3600)

      key = "#{item_id}|#{DateTime.to_iso8601(last)}"

      [
        %Finding{
          id: finding_id("P1", project.root, key),
          rule: "P1",
          kind: :stalled,
          project_root: project.root,
          session_id: nil,
          summary: "roadmap stalled #{format_age(hours)} at #{item_id} #{pos.item_text}",
          evidence: ["roadmap:#{item_id}"],
          data: %{item_id: item_id, last_progress_at: pos.last_progress_at},
          first_seen_at: ctx.now,
          last_seen_at: ctx.now
        }
      ]
    else
      _ -> []
    end
  end

  defp p1(_project, _ctx), do: []

  defp live_session_on?(project, item_id, ctx) do
    Enum.any?(ctx.sessions, fn s ->
      s.project_root == project.root and live?(s) and
        match?(%Item{id: ^item_id}, bound_item(project, s))
    end)
  end

  defp format_age(hours) when hours >= 48, do: "#{div(hours, 24)} days"
  defp format_age(hours), do: "#{hours}h"

  # ── binding ──────────────────────────────────────────────────────────────

  @doc """
  The roadmap item a session works on: the item bound to its branch, else the
  project position's active item. `nil` when the project has neither.
  """
  @spec bound_item(Project.t(), Session.t()) :: Item.t() | nil
  def bound_item(%Project{} = project, %Session{} = session) do
    items = all_items(project)

    by_branch =
      session.branch && Enum.find(items, &(&1.branch != nil and &1.branch == session.branch))

    by_branch ||
      case project.position do
        %{item_id: id} when is_binary(id) -> Enum.find(items, &(&1.id == id))
        _ -> nil
      end
  end

  defp all_items(%Project{roadmap: %{phases: phases}}) when is_list(phases),
    do: Enum.flat_map(phases, &(&1.items || []))

  defp all_items(_), do: []

  # ── "claimed done" ───────────────────────────────────────────────────────

  @claim ~r/\b(done|complete|completed|finished|ready)\b/i
  @negated ~r/\b(not|never|isn't|isnt|aren't|wasn't|weren't|hasn't|haven't|no longer|nothing)\s+(yet\s+|quite\s+|fully\s+|really\s+|entirely\s+|been\s+)?(done|complete|completed|finished|ready)\b/i

  @doc """
  True when `text` claims the work is done ("done", "complete", "finished",
  "ready"), ignoring negated claims ("not done", "isn't finished yet").
  """
  @spec claims_done?(String.t()) :: boolean()
  def claims_done?(text) when is_binary(text) do
    text |> String.replace(@negated, " ") |> then(&Regex.match?(@claim, &1))
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp finding(session, rule, kind, key, opts) do
    %Finding{
      id: finding_id(rule, session.session_id, key),
      rule: rule,
      kind: kind,
      project_root: session.project_root,
      session_id: session.session_id,
      summary: Keyword.fetch!(opts, :summary),
      evidence: Keyword.fetch!(opts, :evidence),
      data: Keyword.get(opts, :data, %{})
    }
  end

  defp stamp(%Finding{} = f, now), do: %{f | first_seen_at: now, last_seen_at: now}

  @doc "The stable finding id for a rule, a scope (session id or project root) and an evidence key."
  @spec finding_id(String.t(), String.t(), String.t()) :: String.t()
  def finding_id(rule, scope, key) do
    hash =
      :crypto.hash(:sha256, Enum.join([rule, scope, key], <<0>>))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    rule <> "-" <> hash
  end

  defp evidence(session, lines, state) do
    lines =
      lines
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> Enum.reject([state.last_event_line, state.last_assistant_line], &is_nil/1)
        ls -> ls
      end
      |> Enum.uniq()

    case lines do
      [] -> ["session:#{session.session_id}"]
      ls -> Enum.map(ls, &"transcript:#{session.session_id}:#{&1}")
    end
  end

  defp owner_typing?(%SessionState{last_user_at: %DateTime{} = at}, ctx),
    do: DateTime.diff(ctx.now, at) < ctx.s.owner_quiet

  defp owner_typing?(_state, _ctx), do: false

  defp live?(%Session{status: :ended}), do: false
  defp live?(%Session{live?: live}), do: live == true

  defp limited?(session, ctx), do: MapSet.member?(ctx.limited_dirs, session.config_dir)

  defp idle_for?(session, state, seconds, now) do
    case session.status_since || state.last_event_at do
      %DateTime{} = since -> DateTime.diff(now, since) > seconds
      _ -> false
    end
  end

  defp question_tool?(ev), do: tool_name(ev) == "AskUserQuestion"

  defp tool_name(ev), do: field(ev, :name) |> to_string()

  defp question_line(state) do
    case state.pending_question do
      q when is_binary(q) and q != "" ->
        last_line(q)

      %{} = q ->
        (field(q, :question) || field(q, :text)) |> then(&if(is_binary(&1), do: last_line(&1)))

      _ ->
        if is_binary(state.last_assistant_text), do: last_line(state.last_assistant_text)
    end
  end

  defp last_line(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
  end

  defp limit_error?(err), do: field(err, :limit?) == true

  # Reads a key from a struct or map, falling back to its `data` map (so an
  # `%Event{}` and a plain map with the same fields both work).
  defp field(nil, _key), do: nil

  defp field(%{} = m, key) do
    case Map.get(m, key) do
      nil ->
        case Map.get(m, :data) do
          %{} = data -> Map.get(data, key)
          _ -> nil
        end

      v ->
        v
    end
  end

  defp after?(%DateTime{} = dt, %DateTime{} = ref), do: DateTime.compare(dt, ref) == :gt
  defp after?(_, _), do: false

  defp latest(dts) do
    dts
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> Enum.max(DateTime, fn -> nil end)
  end
end
