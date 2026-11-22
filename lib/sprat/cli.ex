defmodule Sprat.CLI do
  @moduledoc """
  Real CLI entry points (docs/spec-v1.md §13 CLI table), replacing the
  demo as the main way in while `mix sprat.demo` stays runnable for dev.
  `main/1` is the sole entry point a release's `bin/sprat eval
  "Sprat.CLI.main(System.argv())"` or an escript calls — it starts the
  `:sprat` application itself (rather than relying on the app callback,
  which cannot see `System.argv()`) so it can set `:sprat, :force_no_ui`
  before boot for the non-interactive commands (`doctor`, `sessions
  list|delete`, `--plain`), keeping the raw-terminal `Sprat.UISupervisor`
  out of paths that never read from the tty.

  `-p`/`--solo` from the spec's CLI table are not implemented: both need a
  model backend, which is out of scope for this build (§15) — see the
  report for why.

  ## UI selection

  `sprat` opens the zoned UI (`docs/design/tui-zones.md`) by default.
  `--inline` (anywhere in argv, alongside any other flag) selects the old
  line-append renderer instead — both still leave the alternate screen (or,
  for `--inline`, nothing to leave) cleanly on every exit path. `--plain`
  is unaffected by `--inline`: it never touches either renderer.
  """

  alias Sprat.Store.{Missions, Sessions, Tasks}
  alias Sprat.CLI.{Doctor, PlainShell}
  alias Sprat.Session.Shell

  # Verify (spec-v4 §9): these never start the :sprat application. The hook
  # runs in Claude Code's Stop path and must be fast and unable to fail.
  def main(["hook" | rest]), do: Sprat.Verify.CLI.main(rest)
  def main(["attach" | rest]), do: attach(rest)
  def main(["detach" | rest]), do: detach(rest)

  def main(argv) do
    {inline?, argv} = extract_flag(argv, "--inline")
    mode = if inline?, do: :inline, else: :zoned
    start_app(force_no_ui: true)
    dispatch(argv, mode)
  end

  @doc """
  Entry point for a release booted via the `sprat` overlay script (see
  `rel/overlays/bin/sprat`), which launches through `bin/sprat start`
  — the Ctrl+C-safe path (docs/phase0/03-terminal-spike.md: `bin/sprat
  eval` runs its code over a port with no controlling tty, so
  `Sprat.Terminal.Mode`'s `stty raw -echo` primary path can't reach it and
  it falls back to a mode that never clears ISIG; `start`'s direct `erl`
  exec keeps the real tty throughout). `Sprat.Application` has already
  started the app (and, seeing `SPRAT_CLI_ARGV`, skipped its own
  unconditional `Sprat.UISupervisor` start — this function's `dispatch/2`
  call brings up the UI itself, exactly like `main/1` does), so this only
  sets `force_no_ui` (`Shell.run/2`/`PlainShell.run/1` start the UI
  themselves either way, but a non-interactive command like `doctor` must
  never trip `Sprat.Application`'s own boot-time check on a later
  restart), dispatches, and halts the VM — `start`, unlike `eval`, has
  nothing else to stop it after a one-shot command finishes.
  """
  def run_release(argv) do
    Application.put_env(:sprat, :force_no_ui, true)
    {inline?, argv} = extract_flag(argv, "--inline")
    mode = if inline?, do: :inline, else: :zoned
    dispatch(argv, mode)
    System.halt(0)
  catch
    :exit, {:shutdown, code} when is_integer(code) -> System.halt(code)
  end

  defp dispatch(argv, mode) do
    case argv do
      [] -> Sprat.CLI.V4.board()
      ["board"] -> Sprat.CLI.V4.board()
      ["serve"] -> Sprat.CLI.V4.serve()
      ["status"] -> Sprat.CLI.V4.status()
      ["brief"] -> Sprat.CLI.V4.brief()
      ["mcp"] -> Sprat.CLI.V4.mcp()
      ["install-agent"] -> Sprat.CLI.V4.install_agent()
      ["voice", "setup"] -> Sprat.CLI.Voice.setup()
      ["hook" | rest] -> Sprat.Verify.CLI.main(rest)
      ["attach" | rest] -> attach(rest)
      ["detach" | rest] -> detach(rest)
      ["legacy"] -> interactive(fn -> open_or_create(cwd()) end, mode)
      ["--continue"] -> interactive(fn -> continue(cwd()) end, mode)
      ["--resume"] -> interactive(fn -> resume_pick(cwd()) end, mode)
      ["--resume", id] -> interactive(fn -> id end, mode)
      ["--plain"] -> plain(fn -> open_or_create(cwd()) end)
      ["doctor"] -> run_doctor()
      ["settings"] -> run_settings()
      ["debug"] -> run_debug()
      ["sessions", "list"] -> sessions_list()
      ["sessions", "delete", id] -> sessions_delete(id)
      _ -> usage()
    end
  end

  defp attach(args) do
    {yes?, args} = extract_flag(args, "--yes")

    case Sprat.Verify.Attach.attach(path_arg(args), yes: yes?) do
      {:error, _} -> exit({:shutdown, 1})
      _ -> :ok
    end
  end

  defp detach(args) do
    case Sprat.Verify.Attach.detach(path_arg(args)) do
      {:error, _} -> exit({:shutdown, 1})
      _ -> :ok
    end
  end

  defp path_arg([path]), do: path
  defp path_arg(_), do: cwd()

  defp extract_flag(argv, flag), do: {flag in argv, List.delete(argv, flag)}

  defp cwd, do: File.cwd!()

  defp interactive(session_id_fun, mode) do
    # Force no UI at boot even for the interactive path: `--resume` (no
    # id) picks a session with a plain, line-buffered `IO.gets/1` prompt
    # first, and that can't share stdin with `Sprat.Terminal.Input`'s raw
    # byte-at-a-time reader — if `Sprat.UISupervisor` had already put the
    # tty into raw mode and started reading it, the picker's prompt would
    # never see a normal line. `Sprat.Session.Shell.run/2` brings the raw
    # UI up itself, right before its own loop starts, once the session id
    # is already decided.
    start_app(force_no_ui: true)
    Shell.run(session_id_fun.(), mode: mode)
  end

  defp plain(session_id_fun) do
    start_app(force_no_ui: true)
    PlainShell.run(session_id_fun.())
  end

  defp start_app(force_no_ui: force_no_ui?) do
    Application.put_env(:sprat, :force_no_ui, force_no_ui?)
    {:ok, _} = Application.ensure_all_started(:sprat)
  end

  # -- session selection --------------------------------------------------

  defp open_or_create(path) do
    {:ok, session} = Sessions.create(Sprat.Store, %{project_path: path})
    session.id
  end

  defp continue(path) do
    case Sessions.by_project(Sprat.Store, path) do
      [latest | _] -> latest.id
      [] -> open_or_create(path)
    end
  end

  defp resume_pick(path) do
    case Sessions.by_project(Sprat.Store, path) do
      [] ->
        IO.puts("No sessions yet for this project. Starting a new one.")
        open_or_create(path)

      sessions ->
        print_session_table(sessions)
        IO.write("\nPick a session number: ")

        case IO.gets("") |> to_string() |> String.trim() |> Integer.parse() do
          {n, _} when n >= 1 and n <= length(sessions) ->
            Enum.at(sessions, n - 1).id

          _ ->
            IO.puts(:stderr, "Not a valid choice.")
            exit({:shutdown, 1})
        end
    end
  end

  # -- doctor ---------------------------------------------------------------

  defp run_doctor, do: Doctor.report() |> Enum.each(&IO.puts/1)

  # -- settings/debug (docs/spec-v1.md §13, this build's addition) --------
  # Same content as the TUI's `/settings`/`/debug` and the `Alt+s`/`Alt+d`
  # overlays, printed for a non-interactive shell — `sprat settings`
  # is the CLI-side reach the task asked for; see `Sprat.Config.effective/1`
  # and `Sprat.Debug` for where the data actually comes from.

  defp run_settings do
    project = cwd()
    entries = Sprat.Config.effective(project)

    key_line =
      case Sprat.Secrets.status(project) do
        {:ok, %{present: false}} ->
          "API key: not set (OPENAI_API_KEY, .env, or the OS credential store)"

        {:ok, %{present: true, source: source, last4: last4}} ->
          "API key: set, from #{Sprat.Secrets.describe_source(source)} (…#{last4})"
      end

    IO.puts("Sprat settings — #{project}\n")
    IO.puts(key_line)
    IO.puts("")
    Enum.each(entries, &IO.puts(settings_line(&1)))
  end

  defp settings_line(%{value: nil} = e), do: "  #{e.label}: unset (#{e.source}) — #{e.note}"

  defp settings_line(%{key: "budget_usd", value: %Decimal{} = d} = e),
    do: "  #{e.label}: $#{Decimal.round(d, 2)} (#{e.source})"

  defp settings_line(e), do: "  #{e.label}: #{e.value} (#{e.source})"

  defp run_debug do
    project = cwd()
    sessions = Sessions.by_project(Sprat.Store, project)
    missions = Enum.flat_map(sessions, &Missions.by_session(Sprat.Store, &1.id))

    IO.puts("Sprat debug — #{project}\n")

    case missions do
      [] ->
        IO.puts("No missions recorded for this project yet.")

      missions ->
        Enum.each(missions, &print_mission_debug/1)
    end
  end

  defp print_mission_debug(mission) do
    tasks = Tasks.by_mission(Sprat.Store, mission.id)
    costs = Sprat.Debug.costs(Sprat.Store, mission.id, tasks)
    requests = Sprat.Debug.requests(Sprat.Store, mission.id)
    tools = Sprat.Debug.tool_calls(Sprat.Store, tasks)

    cost =
      if costs.mission_totals.cost,
        do: "$#{Decimal.round(costs.mission_totals.cost, 4)}",
        else: "unknown"

    IO.puts("#{mission.objective}")
    IO.puts("  requests: #{length(requests)}  tool calls: #{length(tools)}")

    IO.puts(
      "  cost: #{cost} (#{costs.unknown_or_estimated} estimated/unavailable, pricing #{costs.pricing_version || "unknown"})"
    )

    IO.puts("")
  end

  # -- sessions list/delete -------------------------------------------------

  defp sessions_list do
    case Sessions.all(Sprat.Store) do
      [] -> IO.puts("No sessions yet.")
      sessions -> print_session_table(sessions, show_project?: true)
    end
  end

  defp sessions_delete(id) do
    case Sessions.get(id) do
      nil ->
        IO.puts(:stderr, "No such session: #{id}")
        exit({:shutdown, 1})

      _session ->
        :ok = Sessions.delete(id)
        IO.puts("Deleted #{id}")
    end
  end

  defp print_session_table(sessions, opts \\ []) do
    sessions
    |> Enum.with_index(1)
    |> Enum.each(fn {session, i} ->
      project = if opts[:show_project?], do: "#{session.project_path}  ", else: ""

      IO.puts(
        "  #{i}. #{session.id}  #{session.started_at}  #{project}#{session_summary(session)}"
      )
    end)
  end

  defp session_summary(session) do
    case Missions.by_session(Sprat.Store, session.id) do
      [] ->
        "(no mission yet)"

      missions ->
        objectives = missions |> Enum.map(& &1.objective) |> Enum.join("; ")

        task_count =
          missions |> Enum.map(&length(Tasks.by_mission(Sprat.Store, &1.id))) |> Enum.sum()

        "#{objectives} · #{task_count} tasks"
    end
  end

  defp usage do
    IO.puts(:stderr, """
    usage: sprat                 the Pass board: every Claude Code session, its roadmap, what needs you
           sprat serve           run the observer/PM as a daemon (the board becomes its client)
           sprat status          one line per project
           sprat brief           today's brief
           sprat install-agent   start `sprat serve` at login (launchd)
           sprat voice setup     talk to the board: install sox and whisper.cpp, fetch the speech model
           sprat mcp             the PM's tool server (used by Sprat itself)
           sprat attach [path] [--yes]   Verify: refuse a session's stop while .sprat/checks fail
           sprat detach [path]           remove that Stop hook
           sprat hook stop       the Stop hook itself (Claude Code runs it)

           sprat legacy [--continue | --resume [id] | --plain] [--inline]   the V1 research product
           sprat doctor
           sprat settings
           sprat debug
           sprat sessions list|delete <id>
    """)

    exit({:shutdown, 1})
  end
end
