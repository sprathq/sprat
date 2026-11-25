defmodule Sprat.Engine.Snapshot do
  @moduledoc """
  Turns the engine's state into what the Pass TUI draws (spec-v4 §10.3):
  projects with positions, rail tickets (yours / sprat), served today, and
  the header. Pure over the state map plus store reads.
  """

  alias Sprat.Observer.Store
  alias Sprat.Observer.Model.{Finding, Project, Ticket}

  @shown_states [:open, :pm_running, :acted, :escalated]

  def build(state, now) do
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    projects = state.projects |> Map.values() |> Enum.map(&attach_sessions(&1, state))

    %{
      now: now,
      projects: projects,
      tickets: tickets(state, now),
      quiet: quiet(state, projects, now),
      served: served(state, midnight),
      jobs: jobs(state, now),
      activity: Sprat.Activity.recent(200),
      commands: Sprat.Activity.commands(),
      system: system(state),
      accounts: Map.values(state.accounts),
      header: %{
        pm_spend: Store.spend_today(state.store, :fleet, now),
        fleet_cap: Sprat.Engine.setting(state, "fleet_cap_usd"),
        limited_accounts:
          state.accounts
          |> Map.values()
          |> Enum.filter(&(&1.limited_until && DateTime.compare(&1.limited_until, now) == :gt)),
        pm_running: map_size(state.pm_running),
        cmux: Map.get(state, :cmux),
        sessions: state.sessions |> Map.values() |> Enum.count(& &1.live?)
      }
    }
  end

  defp attach_sessions(%Project{root: root} = p, state) do
    sessions =
      state.sessions
      |> Map.values()
      |> Enum.filter(&(&1.project_root == root and &1.live?))
      |> Enum.sort_by(&(&1.name || ""))

    # Every account that has worked here, not only the ones with a session
    # now: the board calls a project limited only while all of them are.
    dirs = Enum.uniq((p.config_dirs || []) ++ Sprat.Engine.project_accounts(state, root))
    %{p | sessions: sessions, config_dirs: dirs}
  end

  # Why each live session that is not working is quiet, what it last did and
  # what Sprat means to do about it (`Sprat.Engine.Quiet`), by session id.
  defp quiet(state, projects, now) do
    findings = state.findings |> Map.values() |> Enum.group_by(& &1.session_id)

    for %Project{} = p <- projects,
        s <- p.sessions,
        into: %{} do
      item = p.roadmap && Sprat.Observer.Detector.bound_item(p, s)

      {s.session_id,
       Sprat.Engine.Quiet.explain(s, %{
         now: now,
         state: Map.get(state.states, s.session_id),
         account: s.config_dir && Map.get(state.accounts, s.config_dir),
         project: p,
         item: item,
         findings: Map.get(findings, s.session_id, [])
       })}
    end
  end

  # The VM as the activity screen shows it: the supervised processes with
  # their mailboxes and memory, and what is running under the task
  # supervisor (jobs, PM investigations).
  defp system(state) do
    procs =
      case Process.whereis(Sprat.Engine.Supervisor) do
        nil ->
          [{"engine", self()}]

        sup ->
          sup
          |> Supervisor.which_children()
          |> Enum.reverse()
          |> Enum.flat_map(fn
            {Sprat.Observer.Supervisor, pid, _, _} when is_pid(pid) ->
              for {id, child, _, _} <- Enum.reverse(Supervisor.which_children(pid)),
                  is_pid(child),
                  id not in [Sprat.Observer.SessionRegistry, Sprat.Observer.ProjectRegistry],
                  do: {process_name(id), child}

            {id, pid, _, _} when is_pid(pid) ->
              [{process_name(id), pid}]

            _ ->
              []
          end)
      end

    %{
      processes: :erlang.system_info(:process_count),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      uptime_s: div(elem(:erlang.statistics(:wall_clock), 0), 1000),
      tasks: task_count(),
      jobs_running: Enum.count(Map.values(state.jobs), &(&1.status == :running)),
      pm_running: map_size(state.pm_running),
      tree:
        Enum.map(procs, fn {name, pid} ->
          info = Process.info(pid, [:message_queue_len, :memory, :reductions]) || []

          %{
            name: name,
            alive?: info != [],
            queue: info[:message_queue_len] || 0,
            memory_kb: div(info[:memory] || 0, 1024)
          }
        end)
    }
  rescue
    _ -> %{}
  end

  defp process_name(Sprat.Observer.Live), do: "live tables"

  defp process_name(Sprat.Observer.SessionSupervisor),
    do: "sessions ×#{Sprat.Observer.SessionServer.count()}"

  defp process_name(Sprat.Observer.ProjectSupervisor),
    do: "projects ×#{Sprat.Observer.ProjectServer.count()}"

  defp process_name(Sprat.Observer.Accounts), do: "accounts"
  defp process_name(Sprat.Observer.Cmux), do: "cmux"
  defp process_name(Sprat.Observer.Sessions), do: "session scan"
  defp process_name(Sprat.Engine), do: "engine"
  defp process_name(Sprat.Observer.Store), do: "store"
  defp process_name(Sprat.Engine.TaskSupervisor), do: "tasks"
  defp process_name(Sprat.Activity), do: "activity"
  defp process_name(Sprat.Activity.Registry), do: "subscribers"
  defp process_name(id), do: id |> inspect() |> String.replace_prefix("Sprat.", "")

  defp task_count do
    case Process.whereis(Sprat.Engine.TaskSupervisor) do
      nil -> 0
      _ -> length(Task.Supervisor.children(Sprat.Engine.TaskSupervisor))
    end
  end

  # Running jobs and those that ended in the last ten minutes (spec-v5 §5).
  defp jobs(state, now) do
    state
    |> Sprat.Engine.Jobs.recent(now)
    |> Enum.map(fn j ->
      project = Map.get(state.projects, j.project_root)

      j
      |> Map.from_struct()
      |> Map.take([:id, :kind, :label, :step, :status, :result, :project_root, :ticket_id])
      |> Map.merge(%{
        project_name:
          (project && project.name) || (j.project_root && Path.basename(j.project_root)),
        started_at: j.started_at,
        finished_at: j.finished_at
      })
    end)
  end

  defp served(state, since) do
    Store.served_since(state.store, since)
  rescue
    _ -> []
  end

  # -- tickets -------------------------------------------------------------------

  def tickets(state, now) do
    state.findings
    |> Map.values()
    |> Enum.filter(&(&1.state in @shown_states))
    |> Enum.filter(&project_known?(state, &1))
    |> Enum.flat_map(&to_tickets(&1, state, now))
    |> Enum.sort_by(fn t ->
      {if(t.owner == :yours, do: 0, else: 1), (t.since && DateTime.to_unix(t.since)) || 0}
    end)
  end

  defp project_known?(state, %Finding{project_root: root}), do: Map.has_key?(state.projects, root)

  defp to_tickets(%Finding{} = f, state, now) do
    data = f.data || %{}
    base = base_ticket(f, state)
    running? = Map.has_key?(state.pm_running, f.id)

    main =
      cond do
        f.state == :escalated ->
          proposal = data[:proposal]

          %{
            base
            | owner: :yours,
              headline: data[:owner_note] || data[:proposal_reason] || f.summary,
              meanwhile: decision_line(data),
              proposal: proposal,
              action_label: if(proposal, do: "f send  ⏎ open", else: "⏎ details")
          }

        f.rule == "Q1" ->
          reset = data[:reset_at]
          session = Map.get(state.sessions, f.session_id)
          except = (session && session.config_dir) || data[:account]

          alt =
            List.first(
              Sprat.Engine.free_accounts(state, f.project_root, except, now, f.session_id)
            )

          resumes = if(reset, do: " · resumes #{hhmm(reset)}", else: "")

          if alt do
            %{
              base
              | owner: :sprat,
                headline:
                  "usage limit on #{Path.basename(except || "?")}#{resumes}. " <>
                    "#{Path.basename(alt)} is free and works on this project.",
                proposal:
                  Sprat.Engine.limit_resume_text(
                    state,
                    f,
                    "[sprat] The other account ran out of usage. Continue "
                  ),
                action_label: "f continue on #{Path.basename(alt)}  ⏎ watch"
            }
          else
            %{
              base
              | owner: :sprat,
                headline: "usage limit" <> resumes,
                action_label: "⏎ watch"
            }
          end

        running? or f.state in [:open, :pm_running] ->
          %{
            base
            | owner: :sprat,
              pm_running?: running?,
              pm_started_at: if(running?, do: state.pm_running[f.id][:started_at]),
              headline:
                if(running?, do: "investigating: ", else: "queued: ") <> (f.summary || f.rule),
              action_label: "⏎ watch"
          }

        f.state == :acted ->
          %{
            base
            | owner: :sprat,
              headline: "following up: " <> (decision_line(data) || f.summary || f.rule),
              action_label: "⏎ open"
          }
      end

    note =
      if f.state == :acted and is_binary(data[:owner_note]) and not data[:owner_note_done] do
        [
          %{
            base
            | id: f.id <> ":note",
              owner: :yours,
              headline: data[:owner_note],
              meanwhile: decision_line(data),
              action_label: "x done  ⏎ details"
          }
        ]
      else
        []
      end

    [main | note]
  end

  defp base_ticket(%Finding{} = f, state) do
    session = Map.get(state.sessions, f.session_id)
    project = Map.get(state.projects, f.project_root)

    %Ticket{
      id: f.id,
      owner: :sprat,
      project_root: f.project_root,
      project_name: (project && project.name) || Path.basename(f.project_root || "?"),
      session_id: f.session_id,
      session_name: session && (session.name || session.title),
      finding: f,
      decision: decision(f.data[:decision]),
      since: f.first_seen_at,
      did: did(state, f)
    }
  end

  defp decision(nil), do: nil
  defp decision(%Sprat.Observer.Model.Decision{} = d), do: d

  defp decision(m) when is_map(m) do
    fields = Map.keys(%Sprat.Observer.Model.Decision{action: nil}) -- [:__struct__]

    attrs =
      for k <- fields,
          Map.has_key?(m, k) or Map.has_key?(m, to_string(k)),
          do: {k, Map.get(m, k, Map.get(m, to_string(k)))}

    struct(Sprat.Observer.Model.Decision, attrs)
  end

  defp decision_line(data) do
    case data[:decision] do
      %{} = d ->
        msg = d[:message] || d["message"]
        action = d[:action] || d["action"]
        msg && "#{action}: " <> String.slice(String.replace(msg, ~r/\s+/, " "), 0, 160)

      _ ->
        nil
    end
  end

  defp did(state, %Finding{} = f) do
    run_id = f.data[:pm_run_id]

    writes =
      if run_id do
        state.store
        |> Store.list_writes(f.project_root)
        |> Enum.filter(&(&1[:pm_run_id] == run_id and is_nil(&1[:reverted_at])))
        |> Enum.map(fn w ->
          %{
            at: w[:at],
            text: "marked #{w[:item_id]} #{w[:to_state]} in .sprat/roadmap.md",
            revertible_id: w[:id]
          }
        end)
      else
        []
      end

    nudges =
      state.store
      |> Store.list_nudges(finding_id: f.id)
      |> Enum.map(fn n ->
        %{
          at: n[:delivered_at] || n[:created_at],
          text: "told the agent: " <> String.slice(n[:text] || "", 0, 160),
          revertible_id: nil
        }
      end)

    writes ++ nudges
  rescue
    _ -> []
  end

  # -- session view -----------------------------------------------------------------

  @doc "Condenses transcript events into one line each for the session view and PM excerpts."
  def session_lines(events) do
    Enum.flat_map(events, fn e ->
      d = e.data || %{}

      case e.kind do
        :user_text ->
          [%{at: e.at, kind: :user, text: one(d[:text]), error?: false}]

        :assistant_text ->
          [%{at: e.at, kind: :assistant, text: one(d[:text]), error?: false}]

        :tool_use ->
          [%{at: e.at, kind: :tool, text: tool_text(d), error?: false}]

        :tool_result ->
          if d[:is_error],
            do: [%{at: e.at, kind: :error, text: one(d[:text]), error?: true}],
            else: []

        :api_error ->
          [%{at: e.at, kind: :error, text: one(d[:text]), error?: true}]

        _ ->
          []
      end
    end)
  end

  defp tool_text(d) do
    input = d[:input] || %{}

    detail =
      input["command"] || input["file_path"] || input["pattern"] || input["url"] ||
        input["description"] || ""

    "#{d[:name]} #{one(to_string(detail))}"
  end

  defp one(nil), do: ""
  defp one(t), do: t |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)

  defp hhmm(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, local_zone()) do
      {:ok, l} -> Calendar.strftime(l, "%H:%M")
      _ -> Calendar.strftime(dt, "%H:%M")
    end
  end

  defp hhmm(_), do: ""

  @doc false
  def local_zone do
    System.get_env("SPRAT_TZ") ||
      case File.read_link("/etc/localtime") do
        {:ok, path} -> path |> String.split("zoneinfo/") |> List.last()
        _ -> "Etc/UTC"
      end
  end
end
