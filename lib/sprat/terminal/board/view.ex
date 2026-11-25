defmodule Sprat.Terminal.Board.View do
  @moduledoc """
  View state for the Pass (`docs/spec-v4.md` §10): which screen is showing,
  the latest snapshot, the selection, the opened ticket, scroll offsets, an
  inline composer, and a transient status message. Pure data plus the
  derived orderings that both `Sprat.Terminal.Board` (render) and
  `Sprat.Terminal.Board.Keys` (input) must agree on.

  ## Snapshot

      %{
        now: DateTime.t(),
        projects: [%Model.Project{}],
        tickets: [%Model.Ticket{}],
        served: [%Model.Served{}],
        header: %{pm_spend: number | Decimal, fleet_cap: number | Decimal,
                  limited_accounts: [%Model.Account{}]},
        # optional
        settings: %{age_thresholds: %{"L1" => 10, default: 15}},  # minutes
        utc_offset: 0,                                             # seconds, for clock display
        session_lines: %{session_id => [%{at, kind, text, error?}]} | [...]
      }
  """

  alias Sprat.Observer.Model.{Project, Session, Ticket}

  @type screen :: :board | {:project, String.t()} | {:session, String.t()}
  @type focus :: :rail | :line | :served

  @blink_seconds 10
  @finished_seconds 30 * 60

  defstruct screen: :board,
            snapshot: nil,
            focus: :rail,
            rail_index: 0,
            line_index: 0,
            served_index: 0,
            # selection inside the project screen (tickets ++ sessions)
            project_index: 0,
            # cursor and expanded lines inside the session screen
            session_index: 0,
            session_expanded: MapSet.new(),
            opened_ticket: nil,
            # nil | %{purpose: :edit_proposal | :dismiss_reason | :command, ticket_id, composer}
            composer: nil,
            # ticket_id => owner-edited proposal text
            edited: %{},
            status: nil,
            help?: false,
            # an in-place band over the line: nil | {:brief, text}
            overlay: nil,
            # transcript lines the engine sent for the open session: {sid, lines}
            session_lines: nil,
            # yours ticket ids already seen (nil until the first snapshot)
            seen_yours: nil,
            blink_until: nil,
            # a command sent and not yet answered: nil | %{ref, label}
            pending: nil,
            # first timeline row shown on the activity screen
            activity_index: 0,
            # first line shown on the help page
            help_index: 0,
            # never opened help: the board says ? explains it
            first_run?: false,
            # the session screen shows the session's own terminal (:terminal),
            # its condensed transcript (:transcript) or what it did over the
            # last hours (:recap)
            session_mode: :terminal,
            # the open session's recap: nil | {sid, hours, Sprat.Recap.t()}
            recap: nil,
            # the hours the recap covers
            recap_hours: 4,
            # how many lines the recap is scrolled up from its newest
            recap_scroll: 0,
            # the last read of the open session's terminal: nil | {sid, text}
            session_screen: nil,
            # how many lines the mirrored terminal is scrolled up from its
            # bottom (0 follows it live)
            mirror_scroll: 0,
            # talking to the board: nil | %{state: :listening | :transcribing, hint}
            voice: nil,
            # the processes screen: nil | %{map, rates, born, gone, error}
            procs: nil,
            # how it draws them: :story (by project and session), :pulse
            # (each session's last two minutes), :tank (sessions as fish)
            # or :tree (the supervision tree and its messages)
            procs_view: :story

  @type t :: %__MODULE__{}

  @doc "A fresh view, optionally with a first snapshot."
  def new(snapshot \\ nil) do
    view = %__MODULE__{snapshot: empty_snapshot()}
    if snapshot, do: put_snapshot(view, snapshot), else: view
  end

  @doc "An empty snapshot (nothing known yet)."
  def empty_snapshot do
    %{
      now: DateTime.utc_now(),
      projects: [],
      tickets: [],
      served: [],
      jobs: [],
      header: %{pm_spend: 0, fleet_cap: nil, limited_accounts: []}
    }
  end

  @doc """
  Installs a new snapshot: clamps every selection, folds an opened ticket
  that has left the rail, and starts the fish's ten-second blink when a
  yours ticket appears that was not on the previous snapshot (never on the
  first snapshot: what was already there is not news).
  """
  def put_snapshot(%__MODULE__{} = view, snapshot) do
    snapshot = empty_snapshot() |> Map.merge(snapshot) |> normalize()
    yours = for %Ticket{owner: :yours, id: id} <- snapshot.tickets, into: MapSet.new(), do: id

    blink_until =
      case view.seen_yours do
        nil ->
          view.blink_until

        seen ->
          if MapSet.subset?(yours, seen),
            do: view.blink_until,
            else: DateTime.add(snapshot.now, @blink_seconds, :second)
      end

    view = %{view | snapshot: snapshot, seen_yours: yours, blink_until: blink_until}

    view =
      if view.opened_ticket && is_nil(ticket(view, view.opened_ticket)) do
        %{view | opened_ticket: nil, composer: drop_ticket_composer(view.composer)}
      else
        view
      end

    view
    |> fold_missing_screen()
    |> clamp()
  end

  # Nil collections from the engine read as empty.
  defp normalize(snap) do
    # Map.merge, not %{snap | …}: a snapshot from an older daemon lacks the
    # newer keys, and the board must still draw it.
    Map.merge(snap, %{
      projects: Enum.map(Map.get(snap, :projects) || [], &%{&1 | sessions: &1.sessions || []}),
      tickets: Map.get(snap, :tickets) || [],
      served: Map.get(snap, :served) || [],
      jobs: Map.get(snap, :jobs) || [],
      activity: Map.get(snap, :activity) || [],
      commands: Map.get(snap, :commands) || [],
      system: Map.get(snap, :system) || %{},
      header: Map.get(snap, :header) || %{},
      now: Map.get(snap, :now) || DateTime.utc_now()
    })
  end

  defp drop_ticket_composer(%{purpose: :command} = c), do: c
  defp drop_ticket_composer(_), do: nil

  defp fold_missing_screen(%{screen: {:project, root}} = view) do
    if project(view, root), do: view, else: %{view | screen: :board}
  end

  defp fold_missing_screen(%{screen: {:session, sid}} = view) do
    if session(view, sid), do: view, else: %{view | screen: :board}
  end

  defp fold_missing_screen(%{screen: {:activity, root}} = view) when is_binary(root) do
    if project(view, root), do: view, else: %{view | screen: :board}
  end

  defp fold_missing_screen(view), do: view

  @doc "The activity stream, newest first: every project's, or one project's."
  def activity(%__MODULE__{snapshot: snap}, root \\ nil) do
    events = Map.get(snap, :activity) || []
    if root, do: Enum.filter(events, &(&1.project_root == root)), else: events
  end

  @doc "Keeps every index inside its list; moves focus off an empty rail."
  def clamp(view) do
    rail = rail(view)
    line = line(view)
    served = served_today(view)

    view = %{
      view
      | rail_index: clamp_index(view.rail_index, length(rail)),
        line_index: clamp_index(view.line_index, length(line)),
        served_index: clamp_index(view.served_index, length(served))
    }

    view =
      case view.screen do
        {:project, root} ->
          %{
            view
            | project_index: clamp_index(view.project_index, length(project_items(view, root)))
          }

        {:session, sid} ->
          %{
            view
            | session_index: clamp_index(view.session_index, length(session_lines(view, sid)))
          }

        _ ->
          view
      end

    cond do
      view.focus == :rail and rail == [] and line != [] -> %{view | focus: :line}
      view.focus == :served and served == [] -> %{view | focus: :line}
      true -> view
    end
  end

  defp clamp_index(_i, 0), do: 0
  defp clamp_index(i, n), do: i |> max(0) |> min(n - 1)

  # -- derived data ------------------------------------------------------------

  @doc "Tickets on the rail: yours first, then sprat, each group oldest left."
  def rail(%__MODULE__{snapshot: snap}), do: sort_rail(snap.tickets)

  def sort_rail(tickets) do
    Enum.sort_by(tickets, fn t ->
      {if(t.owner == :yours, do: 0, else: 1), unix(t.since)}
    end)
  end

  @doc "Tickets for one project, in rail order."
  def project_tickets(view, root), do: view |> rail() |> Enum.filter(&(&1.project_root == root))

  @doc "The ticket with `id`, or nil."
  def ticket(%__MODULE__{snapshot: snap}, id), do: Enum.find(snap.tickets, &(&1.id == id))

  @doc "The selected rail ticket on the board, or nil."
  def selected_ticket(%__MODULE__{} = view) do
    case view.screen do
      {:project, root} ->
        case Enum.at(project_items(view, root), view.project_index) do
          {:ticket, t} -> t
          _ -> nil
        end

      _ ->
        Enum.at(rail(view), view.rail_index)
    end
  end

  @doc "The ticket an action applies to: the opened one, else the selected one."
  def target_ticket(view) do
    (view.opened_ticket && ticket(view, view.opened_ticket)) || selected_ticket(view)
  end

  @doc "The text `f` would fire for `ticket`: the owner's edit, else the proposal."
  def fire_text(view, %Ticket{} = t), do: Map.get(view.edited, t.id) || t.proposal
  def fire_text(_view, _), do: nil

  @doc "The project with `root`, or nil."
  def project(%__MODULE__{snapshot: snap}, root), do: Enum.find(snap.projects, &(&1.root == root))

  @doc "The session with `sid` and its project, or nil."
  def session(%__MODULE__{snapshot: snap}, sid) do
    Enum.find_value(snap.projects, fn p ->
      case Enum.find(p.sessions, &(&1.session_id == sid)) do
        nil -> nil
        s -> {s, p}
      end
    end)
  end

  @doc "Selectable rows of a project screen: its tickets, then its sessions."
  def project_items(view, root) do
    tickets = view |> project_tickets(root) |> Enum.map(&{:ticket, &1})

    sessions =
      case project(view, root) do
        nil -> []
        p -> p |> sorted_sessions(view) |> Enum.map(&{:session, &1})
      end

    tickets ++ sessions
  end

  @doc "A project's sessions, live ones first, then by most recent activity."
  def sorted_sessions(%Project{sessions: sessions}, view) do
    Enum.sort_by(sessions, fn s ->
      {session_rank(view, s), -unix(s.last_activity_at || s.status_since || s.started_at)}
    end)
  end

  defp session_rank(view, s) do
    case session_state(view, s) do
      :waiting -> 0
      :stuck -> 1
      :finished -> 2
      :busy -> 3
      :idle -> 4
      :ended -> 5
    end
  end

  @doc """
  A session's state for its glyph: `:waiting` (a yours ticket waits on the
  owner's answer in it), `:stuck` (an open stuck finding), `:busy`,
  `:finished` (idle, having ended a turn in the last
  #{div(@finished_seconds, 60)} minutes: its next prompt is someone's move),
  `:idle` or `:ended`.
  """
  def session_state(%__MODULE__{snapshot: snap}, %Session{} = s) do
    tickets = Enum.filter(snap.tickets, &(&1.session_id == s.session_id))

    cond do
      Enum.any?(tickets, &(&1.owner == :yours and finding_kind(&1) == :needs_you)) -> :waiting
      Enum.any?(tickets, &(finding_kind(&1) == :stuck and finding_state(&1) == :open)) -> :stuck
      s.status == :busy -> :busy
      s.status == :ended or not s.live? -> :ended
      finished?(s, snap.now) -> :finished
      true -> :idle
    end
  end

  # Idle since a moment that is recent, and not just since it opened (a
  # fresh session that never worked has finished nothing).
  defp finished?(%Session{status_since: %DateTime{} = since} = s, %DateTime{} = now) do
    DateTime.diff(now, since) in 0..@finished_seconds and
      (is_nil(s.started_at) or DateTime.diff(since, s.started_at) > 60)
  end

  defp finished?(_s, _now), do: false

  @doc """
  How many live sessions, across every project on the line, are working,
  have just finished a turn or are stuck, and how many tickets wait on the
  owner: the header's one-glance count. `%{busy: n, finished: n, waiting: n, stuck: n, live: n}`.
  """
  def fleet_counts(%__MODULE__{snapshot: snap} = view) do
    states =
      for p <- snap.projects,
          not p.archived?,
          s <- p.sessions,
          s.live?,
          do: session_state(view, s)

    counts = Enum.frequencies(states)

    %{
      busy: Map.get(counts, :busy, 0),
      finished: Map.get(counts, :finished, 0),
      # What needs the owner is their tickets, whether or not the session
      # that raised one is still open.
      waiting: Enum.count(snap.tickets, &(&1.owner == :yours)),
      stuck: Map.get(counts, :stuck, 0),
      live: length(states)
    }
  end

  defp finding_kind(%Ticket{finding: %{kind: k}}), do: k
  defp finding_kind(_), do: nil

  defp finding_state(%Ticket{finding: %{state: s}}), do: s
  defp finding_state(_), do: nil

  @doc """
  Projects on the line, sorted by worst state then most recent change.
  Archived projects are left out.
  """
  def line(%__MODULE__{snapshot: snap} = view) do
    snap.projects
    |> Enum.reject(& &1.archived?)
    |> Enum.sort_by(fn p -> {state_rank(project_state(view, p)), -unix(last_change(view, p))} end)
  end

  @doc """
  A project's worst state: `:yours`, `:stuck`, `:stalled`, `:sprat` (a PM
  run or follow-up in progress), `:moving`, `:idle`, `:limited`,
  `:no_roadmap` or `:done`.
  """
  def project_state(%__MODULE__{snapshot: snap} = view, %Project{} = p) do
    tickets = Enum.filter(snap.tickets, &(&1.project_root == p.root))
    states = Enum.map(p.sessions, &session_state(view, &1))

    cond do
      Enum.any?(tickets, &(&1.owner == :yours)) -> :yours
      :stuck in states -> :stuck
      Enum.any?(tickets, &(finding_kind(&1) == :stalled)) -> :stalled
      Enum.any?(tickets, &(finding_kind(&1) != :scheduled)) -> :sprat
      position_done?(p) -> :done
      limited_until(view, p) -> :limited
      is_nil(p.roadmap) and is_nil(p.position) -> :no_roadmap
      :busy in states -> :moving
      true -> :idle
    end
  end

  @doc """
  What Sprat is doing for a project right now, as `{label, style}`: the
  column that answers "is Sprat on this, or is it waiting on me?".
  """
  def doing(%__MODULE__{snapshot: snap} = view, %Project{} = p) do
    tickets = Enum.filter(snap.tickets, &(&1.project_root == p.root))
    offset = Map.get(snap, :utc_offset, 0)

    project_jobs = Enum.filter(jobs(view), &(&1.project_root == p.root))
    running = Enum.find(project_jobs, &(&1.status == :running))
    failed = Enum.find(project_jobs, &(&1.status == :failed))

    # A few words: the column sits beside the roadmap item, and the job's
    # full step is in the NOW band.
    cond do
      running ->
        {job_word(running), :progress}

      failed ->
        {job_word(failed) <> " failed", :stuck}

      Enum.any?(tickets, &unreachable?/1) ->
        {"can't reach", :stuck}

      t = Enum.find(tickets, & &1.pm_running?) ->
        {"investigating" <> minutes_since(snap.now, t.pm_started_at), :text}

      Enum.any?(tickets, &(&1.owner == :yours)) ->
        {"waiting on you", :you}

      Enum.any?(tickets, &account_offer?/1) ->
        {"other account free", :you}

      reset = Enum.find_value(tickets, &resume_at/1) ->
        {"resumes " <> hhmm(reset, offset), :quiet}

      until = limited_until(view, p) ->
        {"resumes " <> hhmm(until, offset), :quiet}

      Enum.any?(tickets, &(finding_state(&1) in [:open, :pm_running])) ->
        {"queued", :quiet}

      Enum.any?(tickets, &(finding_state(&1) == :acted)) ->
        {"following up", :text}

      position_done?(p) ->
        {"", :quiet}

      true ->
        {"watching", :quiet}
    end
  end

  defp job_word(%{kind: :switch_account}), do: "moving session"
  defp job_word(%{kind: :message}), do: "sending message"
  defp job_word(%{kind: :investigate}), do: "investigating"
  defp job_word(_), do: "working"

  @doc "The jobs the engine reported: running first, then the ones that just ended."
  def jobs(%__MODULE__{snapshot: snap}), do: Map.get(snap, :jobs) || []

  @doc """
  What to say while a command is on its way to the engine: the key's action
  in words, so a key press answers in the same frame.
  """
  def pending_label(%__MODULE__{snapshot: snap}, command) do
    case command do
      {:fire, id, _} ->
        case Enum.find(snap.tickets, &(&1.id == id)) do
          %Ticket{action_label: "f " <> rest} -> rest |> String.split("  ") |> hd()
          _ -> "sending"
        end

      {:dismiss, _, _} ->
        "dismissing"

      {:open_session_terminal, _} ->
        "switching to the session"

      {:send_to_session, _, _} ->
        "sending"

      {:copy, _} ->
        "copying"

      {:brief, _} ->
        "writing the brief"

      {:set_autonomy, _, level} ->
        "setting autonomy to #{level}"

      {:revert, _} ->
        "undoing"

      {:mute, _} ->
        "muting"

      {:write_roadmap, _} ->
        "writing the roadmap"

      {:reread_roadmap, _} ->
        "re-reading the roadmap"

      {:edit_roadmap, _} ->
        "opening the roadmap"

      {:add_project, path} ->
        "adding #{Path.basename(to_string(path))}"

      {:archive, _} ->
        "archiving"

      _ ->
        "working"
    end
  end

  defp unreachable?(%Ticket{headline: h}) when is_binary(h),
    do: String.starts_with?(h, "delivery failed")

  defp unreachable?(_), do: false

  defp account_offer?(%Ticket{finding: %{rule: "Q1"}, proposal: p}) when is_binary(p), do: true
  defp account_offer?(_), do: false

  defp resume_at(%Ticket{
         owner: :sprat,
         finding: %{rule: "Q1", data: %{reset_at: %DateTime{} = at}}
       }),
       do: at

  defp resume_at(_), do: nil

  defp hhmm(%DateTime{} = at, offset),
    do: at |> DateTime.add(offset, :second) |> Calendar.strftime("%H:%M")

  defp state_rank(state) do
    Enum.find_index(
      [:yours, :stuck, :stalled, :sprat, :moving, :idle, :limited, :no_roadmap, :done],
      &(&1 == state)
    )
  end

  defp position_done?(%Project{position: %{all_done?: true}}), do: true
  defp position_done?(_), do: false

  @doc "The most recent change on a project: newest ticket, progress or session activity."
  def last_change(%__MODULE__{snapshot: snap}, %Project{} = p) do
    ticket_times =
      for t <- snap.tickets, t.project_root == p.root, do: t.since

    session_times = Enum.map(p.sessions, &(&1.last_activity_at || &1.status_since))
    progress = p.position && p.position.last_progress_at

    [progress | ticket_times ++ session_times]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&unix/1, fn -> nil end)
  end

  @doc """
  When the project can work again, if every account that works on it is
  limited: the earliest of their resets (from the snapshot's `accounts` and
  `header.limited_accounts`, ignoring limits already past). Nil while any of
  its accounts is free.
  """
  def limited_until(%__MODULE__{snapshot: snap}, %Project{} = p) do
    header = Map.get(snap, :header) || %{}
    accounts = (Map.get(snap, :accounts) || []) ++ (Map.get(header, :limited_accounts) || [])
    dirs = p.config_dirs || []
    now = unix(snap.now)

    until =
      Map.new(accounts, fn a ->
        {a.config_dir, if(a.limited_until && unix(a.limited_until) > now, do: a.limited_until)}
      end)

    # Several accounts can work on one project: it is limited only while
    # every one of them is, until the first of them resets.
    resets = Enum.map(dirs, &Map.get(until, &1))

    if dirs != [] and Enum.all?(resets),
      do: Enum.min_by(resets, &unix/1),
      else: nil
  end

  @doc "Served lines from the snapshot's day, newest first."
  def served_today(%__MODULE__{snapshot: snap}) do
    offset = Map.get(snap, :utc_offset, 0)
    today = local_date(snap.now, offset)

    snap.served
    |> Enum.filter(&(local_date(&1.at, offset) == today))
    |> Enum.sort_by(&(-unix(&1.at)))
  end

  @doc "Served lines for one project over the last seven days, newest first."
  def served_recent(%__MODULE__{snapshot: snap}, %Project{} = p) do
    cutoff = DateTime.add(snap.now, -7 * 86_400, :second)
    name = p.name || Path.basename(p.root)

    snap.served
    |> Enum.filter(&(&1.project_name == name and unix(&1.at) >= unix(cutoff)))
    |> Enum.sort_by(&(-unix(&1.at)))
  end

  @doc """
  Condensed transcript lines for a session: what the engine sent for it
  (`put_session_lines/3`), else what the snapshot carries.
  """
  def session_lines(%__MODULE__{session_lines: {sid, lines}}, sid), do: lines

  def session_lines(%__MODULE__{snapshot: snap}, sid) do
    case Map.get(snap, :session_lines) do
      lines when is_list(lines) -> lines
      %{} = by_sid -> Map.get(by_sid, sid, [])
      _ -> []
    end
  end

  @doc "Stores a read of the session's own terminal (its cmux surface)."
  def put_session_screen(%__MODULE__{} = view, sid, text) when is_binary(text),
    do: %{view | session_screen: {sid, text}}

  @doc "Whether the session screen shows the session's live terminal (it has a cmux tab)."
  def mirroring?(%__MODULE__{session_mode: :terminal} = view, sid) do
    match?({%{surface: "surface:" <> _}, _}, session(view, sid))
  end

  def mirroring?(_view, _sid), do: false

  @doc """
  Lines of the session's terminal from the last read, trailing blank lines
  dropped: what the mirror scrolls through.
  """
  def mirror_lines(nil), do: []

  def mirror_lines(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc "The recap read for session `sid` over the current hours, or nil."
  def recap(%__MODULE__{recap: {sid, hours, r}, recap_hours: hours}, sid), do: r
  def recap(_view, _sid), do: nil

  @doc "Stores a recap read for session `sid` over `hours`."
  def put_recap(%__MODULE__{} = view, sid, hours, recap), do: %{view | recap: {sid, hours, recap}}

  @doc "The last read of the session's terminal, or nil."
  def session_screen(%__MODULE__{session_screen: {sid, text}}, sid), do: text
  def session_screen(_view, _sid), do: nil

  @doc """
  Whether the session's terminal shows a Claude dialog (a permission
  question, a menu): then digits, arrows and ⏎ answer it.
  """
  def session_dialog?(view, sid) do
    case mirroring?(view, sid) && session_screen(view, sid) do
      false -> false
      nil -> false
      text -> Sprat.Nudge.Delivery.prompt_state(text) == {:hold, :dialog}
    end
  end

  @doc "Stores the engine's transcript lines for the session `sid`."
  def put_session_lines(%__MODULE__{} = view, sid, lines) when is_list(lines) do
    follow? = view.session_index >= length(session_lines(view, sid)) - 1
    view = %{view | session_lines: {sid, lines}}
    # Stay on the newest line while following; otherwise keep the cursor.
    view = if follow?, do: %{view | session_index: max(length(lines) - 1, 0)}, else: view
    clamp(view)
  end

  @doc "True while the fish is in its ten-second blink window."
  def blinking?(%__MODULE__{blink_until: nil}), do: false

  def blinking?(%__MODULE__{blink_until: until, snapshot: snap}),
    do: DateTime.compare(snap.now, until) == :lt

  @doc "`:facing` (any yours ticket), `:swimming` (any PM run live) or `:still`."
  def fish_state(%__MODULE__{snapshot: snap}) do
    cond do
      Enum.any?(snap.tickets, &(&1.owner == :yours)) -> :facing
      Enum.any?(snap.tickets, & &1.pm_running?) -> :swimming
      true -> :still
    end
  end

  # " 3m" once a run has gone a minute: the column's in-progress clock.
  defp minutes_since(%DateTime{} = now, %DateTime{} = at) do
    case div(DateTime.diff(now, at), 60) do
      m when m >= 1 -> " #{m}m"
      _ -> ""
    end
  end

  defp minutes_since(_now, _at), do: ""

  @doc "True when something on screen animates (the app ticks frames only then)."
  def animating?(view, opts \\ []) do
    reduced? = Keyword.get(opts, :reduced_motion?, false)

    blinking?(view) or
      (not reduced? and
         (Enum.any?(view.snapshot.tickets, & &1.pm_running?) or view.pending != nil or
            view.voice != nil or
            Enum.any?(jobs(view), &(&1.status == :running)) or
            working_on_screen?(view)))
  end

  # A project's or a session's own screen shows its working agents with a
  # spinner; the board keeps them still (one mark each, many projects).
  defp working_on_screen?(%__MODULE__{screen: {:project, root}} = view) do
    case Enum.find(view.snapshot.projects, &(&1.root == root)) do
      nil -> false
      p -> Enum.any?(p.sessions, &(session_state(view, &1) == :busy))
    end
  end

  defp working_on_screen?(%__MODULE__{screen: {:session, sid}} = view) do
    case session(view, sid) do
      {%Session{} = s, _} -> session_state(view, s) == :busy
      _ -> false
    end
  end

  # The processes screen moves: messages travel its lanes.
  defp working_on_screen?(%__MODULE__{screen: {:processes, _}}), do: true
  defp working_on_screen?(_view), do: false

  # -- the processes screen ------------------------------------------------------

  @history 8
  @fresh_ms 3_000

  @doc """
  Installs a reading of `sprat serve`'s processes
  (`Sprat.Engine.ProcessMap.snapshot/0`): each process's work per second
  since the last reading (its last #{@history}), which processes are new
  (started in the last #{div(@fresh_ms, 1000)} seconds) and which have just
  ended (kept on screen as long).
  """
  def put_process_map(%__MODULE__{} = view, map) do
    # A daemon from before refs sends nodes without them.
    map =
      map
      |> Map.put_new(:wall_ms, System.os_time(:millisecond))
      |> Map.update!(:nodes, fn nodes ->
        Enum.map(nodes, &Map.merge(%{ref: nil, did: nil, did_ago_ms: nil, beats: []}, &1))
      end)

    prev = view.procs
    now = map.at
    by_id = Map.new(map.nodes, &{&1.id, &1})

    {rates, born, gone, order, active} =
      case prev do
        %{map: %{nodes: old_nodes, at: then}} = p ->
          old = Map.new(old_nodes, &{&1.id, &1})
          dt = max(now - then, 1)

          rates =
            Map.new(map.nodes, fn n ->
              rate =
                case old[n.id] do
                  %{reductions: r} -> max(n.reductions - r, 0) * 1000 / dt
                  nil -> 0
                end

              {n.id, Enum.take([rate | Map.get(p.rates, n.id, [])], @history)}
            end)

          born =
            p.born
            |> Map.reject(fn {id, at} -> now - at > @fresh_ms or not Map.has_key?(by_id, id) end)
            |> Map.merge(
              Map.new(for n <- map.nodes, not Map.has_key?(old, n.id), do: {n.id, now})
            )

          ended = for n <- old_nodes, not Map.has_key?(by_id, n.id), do: %{node: n, at: now}

          gone =
            (ended ++ p.gone)
            |> Enum.reject(&(now - &1.at > @fresh_ms or Map.has_key?(by_id, &1.node.id)))

          {rates, born, gone, order(p.order, map.nodes), active(p.active, map, rates, born)}

        _ ->
          {Map.new(map.nodes, &{&1.id, []}), %{}, [], order(%{}, map.nodes), %{}}
      end

    %{
      view
      | procs: %{
          map: map,
          rates: rates,
          born: born,
          gone: gone,
          order: Map.take(order, Enum.map(map.nodes, & &1.id) ++ Enum.map(gone, & &1.node.id)),
          marks: marks(prev && Map.get(prev, :marks), map),
          active: active,
          error: nil,
          flows: flows(prev, map)
        }
    }
  end

  # When the engine checked and the publisher sent, since the screen opened
  # (the pulse's bottom lanes): a new mark each time a process's last
  # deed is newer than the one before, kept for the pulse's window.
  @marks_for ["engine", "publisher"]
  @marks_ms 130_000

  defp marks(prev, map) do
    prev = prev || %{}

    for n <- map.nodes, n.name in @marks_for, is_integer(n.did_ago_ms), into: prev do
      at = map.wall_ms - n.did_ago_ms
      old = Map.get(prev, n.name, [])

      kept =
        case old do
          [last | _] when at - last < 250 -> old
          _ -> [at | old]
        end

      {n.name, Enum.take_while(kept, &(map.wall_ms - &1 <= @marks_ms))}
    end
  end

  # Where each process sits among its siblings, fixed when first seen: a
  # newcomer joins the end, and one that ends keeps its place, so rows
  # don't trade places from one reading to the next.
  defp order(order, nodes) do
    next = map_size(order)

    nodes
    |> Enum.reject(&Map.has_key?(order, &1.id))
    |> Enum.with_index(next)
    |> Map.new(fn {n, i} -> {n.id, i} end)
    |> Map.merge(order)
  end

  @busy_rate 2_000

  # When each process last did something worth showing (worked hard, had
  # mail waiting, started): which of a crowd of watchers get the rows.
  defp active(active, map, rates, born) do
    ids = MapSet.new(map.nodes, & &1.id)

    fresh =
      for n <- map.nodes,
          n.queue > 0 or Map.has_key?(born, n.id) or
            match?([r | _] when r >= @busy_rate, Map.get(rates, n.id)),
          into: %{},
          do: {n.id, map.at}

    active
    |> Map.filter(fn {id, _} -> MapSet.member?(ids, id) end)
    |> Map.merge(fresh)
  end

  # Messages seen in the last few samples, newest count per pair: a lane
  # stays on screen a little while after its last message, rather than
  # blinking with every quiet sample.
  @flow_ms 4_000

  defp flows(prev, map) do
    fresh = Map.new(map.flows, &{{&1.from, &1.to}, Map.put(&1, :at, map.at)})

    kept =
      for {key, f} <- (prev && Map.get(prev, :flows)) || %{},
          map.at - f.at <= @flow_ms,
          not Map.has_key?(fresh, key),
          into: %{},
          do: {key, f}

    Map.merge(kept, fresh)
  end

  @doc "The processes could not be read (no daemon, or one from before the screen)."
  def put_process_error(%__MODULE__{} = view, why) do
    procs =
      view.procs ||
        %{map: nil, rates: %{}, born: %{}, gone: [], flows: %{}, order: %{}, active: %{}}

    %{view | procs: Map.put(procs, :error, why)}
  end

  # -- time helpers ------------------------------------------------------------

  @doc false
  def unix(nil), do: 0
  def unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  def unix(_), do: 0

  @doc "The local calendar date of `dt` under `offset` seconds."
  def local_date(nil, _offset), do: nil

  def local_date(%DateTime{} = dt, offset),
    do: dt |> DateTime.add(offset, :second) |> DateTime.to_date()
end
