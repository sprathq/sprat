defmodule Sprat.Engine.Runtime do
  @moduledoc """
  How the engine runs (spec-v4 §6 "Daemon or not"):

    * `sprat serve` — the daemon: the engine runs headless, publishes its
      snapshot to `<data>/v4/snapshot.etf` and takes commands from
      `<data>/v4/spool/`. Only one may run (`<data>/v4/serve.pid`).
    * `sprat` — the board. If a daemon is running, the board is a client of
      it (reads the snapshot, writes commands to the spool and waits for the
      reply). Otherwise it starts the engine in its own process.
    * `sprat status` / `sprat brief` — a passive one-shot: observe and detect,
      never investigate or act.
  """

  require Logger

  alias Sprat.Engine
  alias Sprat.Observer.Store

  def dir, do: Path.join(Sprat.Store.Paths.data_dir(), "v4")
  def pid_path, do: Path.join(dir(), "serve.pid")
  def snapshot_path, do: Path.join(dir(), "snapshot.etf")
  def spool_dir, do: Path.join(dir(), "spool")
  def socket_path, do: Path.join(dir(), "sprat.sock")

  @doc """
  Starts Sprat's process tree (spec-v5 §3):

      Engine.Supervisor (rest_for_one)
      ├─ Activity.Registry, Activity   the activity stream
      ├─ Store                         SQLite
      ├─ Engine.TaskSupervisor         jobs and PM investigations
      ├─ Observer.Supervisor           sessions, projects, cmux, accounts (not in passive mode)
      └─ Engine                        decisions: rules, policy, scheduler, commands

  rest_for_one: an observer crash restarts the observers and the engine
  after them, never the store or the activity stream. Passive one-shots
  (`sprat status`, `sprat brief`) observe inline instead.
  """
  def start_engine(opts \\ []) do
    File.mkdir_p!(dir())

    opts = dry_run_opts(opts)

    opts =
      if Keyword.get(opts, :passive, false),
        do: opts,
        else: Keyword.put_new(opts, :observers, :processes)

    observers =
      if opts[:observers] == :processes, do: [{Sprat.Observer.Supervisor, opts}], else: []

    children =
      Sprat.Activity.child_specs() ++
        [
          {Store, name: Store, path: Keyword.get(opts, :store_path, Store.default_path())},
          {Task.Supervisor, name: Sprat.Engine.TaskSupervisor}
        ] ++ observers ++ [{Engine, opts}, Sprat.Engine.Tracer]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Sprat.Engine.Supervisor)
  end

  # SPRAT_DRY_RUN=1: everything runs (PM investigations included) but
  # nothing is typed into a session and no session is started; what would
  # have been sent is logged to <data>/v4/dry-run.log.
  defp dry_run_opts(opts) do
    if System.get_env("SPRAT_DRY_RUN") in ["1", "true"] do
      log = Path.join(dir(), "dry-run.log")

      record = fn kind, target, text ->
        File.write!(
          log,
          "#{DateTime.utc_now() |> DateTime.to_iso8601()} #{kind} #{target}\n#{text}\n\n",
          [:append]
        )
      end

      opts
      |> Keyword.put_new(:deliver_fun, fn session, text, _ ->
        record.("deliver", session.name || session.session_id, text)
        {:ok, :dry_run}
      end)
      |> Keyword.put_new(:background_fun, fn root, text, _ ->
        record.("start", root, text)
        :ok
      end)
    else
      opts
    end
  end

  @doc "The OS pid of a running `sprat serve`, or nil."
  def daemon_pid do
    with {:ok, text} <- File.read(pid_path()),
         {pid, _} <- Integer.parse(String.trim(text)),
         true <- pid != String.to_integer(System.pid()),
         {_, 0} <- System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      pid
    else
      _ -> nil
    end
  end

  # -- daemon -------------------------------------------------------------------

  @doc "Runs the daemon until the VM stops."
  def serve(opts \\ []) do
    case daemon_pid() do
      nil ->
        File.mkdir_p!(spool_dir())
        File.write!(pid_path(), System.pid())
        # The engine's supervisor is linked to this process; trapping exits
        # turns its death into :noproc below (and a restart) instead of
        # silently killing the loop while the VM stays up.
        Process.flag(:trap_exit, true)
        {:ok, _} = start_engine(opts)
        {:ok, _} = start_door()

        IO.puts(
          "sprat serve: watching every Claude Code session (pid #{System.pid()}). Ctrl+C to stop."
        )

        # Whatever ends the loop ends the VM, so launchd (KeepAlive) starts a
        # fresh daemon. A daemon whose engine died but whose VM lives on is
        # the worst case: the board waits on a spool nobody reads.
        try do
          spool_loop()
        catch
          kind, reason ->
            Logger.error(
              "sprat serve stopped: " <> Exception.format(kind, reason, __STACKTRACE__)
            )
        end

        System.halt(1)

      pid ->
        IO.puts(:stderr, "sprat serve is already running (pid #{pid}).")
        {:error, :already_running}
    end
  end

  # Boards connect over the socket and get each snapshot pushed
  # (`Sprat.Engine.Publisher`, which also writes `snapshot.etf` for boards
  # that read the file). Linked to the serve process: if either dies, the
  # loop below ends and the VM with it, so launchd starts a fresh daemon.
  defp start_door do
    children = [
      {Sprat.Engine.Publisher, file: snapshot_path()},
      {Sprat.Engine.Socket, path: socket_path()}
    ]

    Supervisor.start_link(children, strategy: :one_for_all, name: Sprat.Engine.Door)
  end

  # The command spool, for boards from before the socket (and anything
  # scripting the daemon through files).
  defp spool_loop do
    receive do
      {:EXIT, _pid, reason} ->
        raise "sprat serve: a supervisor stopped (#{inspect(reason, limit: 5)})"
    after
      200 -> :ok
    end

    process_spool()
    spool_loop()
  end

  defp call(fun) do
    {:ok, fun.()}
  catch
    :exit, {:timeout, _} -> {:error, "timeout"}
    :exit, {:noproc, _} -> raise "the engine is not running"
    :exit, reason -> {:error, inspect(reason, limit: 5)}
  end

  # Commands older than this were given up on by the board that sent them;
  # replies older than this were never collected.
  @spool_ttl_ms 60_000

  defp process_spool do
    sweep_spool()

    spool_dir()
    |> Path.join("cmd-*.etf")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.each(fn path ->
      id = path |> Path.basename(".etf") |> String.replace_prefix("cmd-", "")

      reply =
        with {:ok, bin} <- File.read(path),
             {:ok, reply} <- call(fn -> Engine.command(:erlang.binary_to_term(bin)) end) do
          reply
        else
          {:error, "timeout"} -> {:error, "Sprat is busy; try again in a moment."}
          {:error, why} when is_binary(why) -> {:error, why}
          _ -> {:error, "unreadable command"}
        end

      File.rm(path)
      File.write!(Path.join(spool_dir(), "reply-#{id}.etf"), :erlang.term_to_binary(reply))
    end)
  rescue
    e in RuntimeError -> reraise e, __STACKTRACE__
    _ -> :ok
  end

  defp sweep_spool do
    cutoff = System.os_time(:second) - div(@spool_ttl_ms, 1000)

    for path <- Path.wildcard(Path.join(spool_dir(), "*.etf")),
        {:ok, %{mtime: m}} <- [File.stat(path, time: :posix)],
        m < cutoff,
        do: File.rm(path)
  end

  # -- client -------------------------------------------------------------------

  @doc """
  Snapshot function for the board when a daemon is running. When the
  daemon has stopped publishing (gone, or its engine stuck) the snapshot
  carries a `:daemon_warning` the board shows instead of freezing on stale
  data without a word.
  """
  def client_snapshot(now \\ DateTime.utc_now()) do
    case File.read(snapshot_path()) do
      {:ok, bin} -> bin |> :erlang.binary_to_term() |> with_warning(now)
      _ -> nil
    end
  end

  @stale_s 15

  @doc false
  def with_warning(snap, now, alive? \\ fn -> daemon_pid() != nil end) do
    published = Map.get(snap, :published_at)

    warning =
      cond do
        not alive?.() ->
          "sprat serve is not running; showing its last state. Start it: sprat serve"

        published && DateTime.diff(now, published) > @stale_s ->
          "sprat serve has not updated since #{Calendar.strftime(published, "%H:%M:%S")} UTC (busy or stuck; see serve.log)"

        true ->
          nil
      end

    Map.put(snap, :daemon_warning, warning)
  end

  @doc """
  Command function for the board when a daemon is running. Reading a
  session's lines is polled while the session view is open, so it gives up
  fast; actions wait for the engine (whose own deadline is 30s).
  """
  def client_command(cmd), do: client_command(cmd, client_timeout(cmd))

  def client_command(cmd, timeout_ms) do
    File.mkdir_p!(spool_dir())
    id = "#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}"
    tmp = Path.join(spool_dir(), "tmp-#{id}")
    File.write!(tmp, :erlang.term_to_binary(cmd))
    cmd_path = Path.join(spool_dir(), "cmd-#{id}.etf")
    File.rename!(tmp, cmd_path)

    case wait_reply(Path.join(spool_dir(), "reply-#{id}.etf"), timeout_ms) do
      {:error, :no_answer} ->
        # Withdrawn, so a daemon catching up later doesn't act on it.
        File.rm(cmd_path)

        {:error,
         "sprat serve did not answer (pid #{daemon_pid() || "gone"}). See #{Path.join(dir(), "serve.log")}."}

      reply ->
        reply
    end
  end

  defp client_timeout({:session_lines, _}), do: 3_000
  defp client_timeout(_), do: 35_000

  defp wait_reply(_path, remaining) when remaining <= 0, do: {:error, :no_answer}

  defp wait_reply(path, remaining) do
    case File.read(path) do
      {:ok, bin} ->
        File.rm(path)
        :erlang.binary_to_term(bin)

      _ ->
        Process.sleep(100)
        wait_reply(path, remaining - 100)
    end
  end

  # -- one-shots ----------------------------------------------------------------

  @doc "A passive snapshot: observe and detect once, act on nothing."
  def passive_snapshot do
    {:ok, _} = start_engine(autostart: false, passive: true, pm_disabled: true)
    :ok = Engine.refresh()
    Engine.snapshot()
  end

  @doc "`sprat status`: one line per project."
  def status_lines(snap) do
    now = snap.now

    snap.projects
    |> Enum.sort_by(&(&1.name || ""))
    |> Enum.map(fn p ->
      pos = p.position

      where =
        cond do
          is_nil(pos) or pos.total == 0 -> "no roadmap"
          pos.all_done? -> "all done"
          true -> "#{pos.phase_id} #{pos.done}/#{pos.total} · #{pos.item_id} #{pos.item_text}"
        end

      yours = Enum.count(snap.tickets, &(&1.project_root == p.root and &1.owner == :yours))
      live = length(p.sessions)

      progress =
        case pos && pos.last_progress_at do
          nil -> ""
          at -> " · last progress #{ago(now, at)}"
        end

      flag = if yours > 0, do: " · #{yours} for you", else: ""

      "#{String.pad_trailing(p.name || "?", 22)} #{where}#{progress} · #{live} live · #{p.autonomy}#{flag}"
    end)
  end

  defp ago(now, at) do
    s = DateTime.diff(now, at)

    cond do
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
    end
  end

  # -- launchd ------------------------------------------------------------------

  @doc "The launchd agent plist that starts `sprat serve` at login."
  def launchd_plist(sprat_bin) do
    log = Path.join(dir(), "serve.log")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>dev.sprat.serve</string>
      <key>ProgramArguments</key>
      <array><string>#{sprat_bin}</string><string>serve</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>#{log}</string>
      <key>StandardErrorPath</key><string>#{log}</string>
      <key>EnvironmentVariables</key>
      <dict><key>PATH</key><string>#{agent_path()}</string></dict>
    </dict>
    </plist>
    """
  end

  def launchd_path, do: Path.expand("~/Library/LaunchAgents/dev.sprat.serve.plist")

  # The login PATH minus entries that don't survive: cmux's per-launch shim
  # folder under /var/folders and the release's own erts/bin folders.
  defp agent_path do
    (System.get_env("PATH") || "")
    |> String.split(":", trim: true)
    |> Enum.reject(
      &(String.contains?(&1, "cmux-cli-shims") or String.contains?(&1, "/rel/sprat_rt/"))
    )
    |> Enum.concat([Path.expand("~/.local/bin"), "/opt/homebrew/bin", "/usr/bin", "/bin"])
    |> Enum.uniq()
    |> Enum.join(":")
  end
end
