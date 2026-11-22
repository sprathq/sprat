defmodule Sprat.Build.Scaffold do
  @moduledoc """
  Deterministic execution of the Scaffold stage (docs/spec-v2.md §5/§15
  Phase A) — code, not a model turn: the technical design already named
  a supported profile, so what's left is running that profile's declared
  commands and proving the result actually runs, not asking a model to
  improvise them.

  Order of operations, matching §5's Scaffold->Plan gate exactly:

    1. Grants: write (workspace), shell, network_install — each asked
       once per session and reused (§9), never implied.
    2. The profile's scaffold command, run with `Sprat.Store.Paths.projects_dir/0`
       (a per-mission *parent* directory) as its cwd, targeting the app
       name as a relative path — the scaffolder creates that directory
       itself. A scaffolder like `mix phx.new` (this version has no
       non-interactive way to force past its "directory already exists"
       prompt) refuses the moment its *target* directory already exists,
       including as a bare `git worktree add` stub, so the target can
       never pre-exist — never `.` inside an already-`git init`'d worktree
       (ponytail: this is the one place this module's order departs from
       "worktree first"; noted in the build report, not hidden).
    3. That scaffolded tree becomes the project repo's one commit
       (`git init` + `git add` + `git commit`), then a worktree on top of
       it via `Sprat.Workspace.create/4` — reusing that module exactly as
       any other build task would, per its own moduledoc.
    4. The profile's install command (`purpose: "install"`, network on),
       run through `Sprat.Agent.Tools.Shell.call/2` directly (a plain
       function call, not a model tool-call), so it's still recorded in
       `Sprat.Store.Runs` exactly as if a model had asked for it.
    5. A free port is picked (never the profile's stated default, per
       build brief item 4), recorded as an event, and handed to the run
       command as both a `PORT` env var and, where the profile's run
       command takes one, a substituted CLI arg.
    6. The run command is started, polled against the health check
       instead of slept on, then the whole process tree is killed —
       always, on every exit path, so nothing is left listening.

  Returns `:ok` or `{:error, reason}`. Every step's evidence is already
  durable in `Sprat.Store.Runs`/`Sprat.Store.Events` by the time this
  returns, whichever way it ends — the caller's gate check
  (`Sprat.Workflow.Gate.check(:scaffold_gate, ...)`) reads that evidence
  back rather than trusting this function's own return value.
  """

  alias Sprat.Build.Profile
  alias Sprat.Store.{Events, Grants, Paths}
  alias Sprat.{Session, Workspace}
  alias Sprat.Agent.Tools.Shell

  @doc """
  Runs the scaffold stage for `mission`/`task`. `opts` requires
  `:session_id`, `:store`; `:design` is the already-gate-passed
  `technical_design` artifact content (a string-keyed map).
  """
  def run(mission, task, design, opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    store = Keyword.fetch!(opts, :store)

    # A per-mission parent that itself is never the scaffolder's own
    # target directory (see the moduledoc's step 2) — `mix phx.new
    # <app_name>` / `npx create-next-app <app_name>` create `<app_name>`
    # themselves inside it, so the directory they actually check for
    # "already exists" never pre-exists.
    project_parent = Path.join(Paths.projects_dir(), mission.id)
    name = app_name(mission)
    project_dir = Path.join(project_parent, name)

    with {:ok, profile} <- fetch_profile(design),
         :ok <- ensure_grants(store, session_id, mission.id),
         :ok <- File.mkdir_p(project_parent),
         scaffold_context <-
           shell_context(store, session_id, mission, task, project_parent, profile),
         {:ok, _} <- run_command(scaffold_context, Profile.scaffold_command(profile, name)),
         {:ok, workspace} <-
           commit_and_create_workspace(store, session_id, mission, task, project_dir),
         context <- shell_context(store, session_id, mission, task, workspace.root, profile),
         {:ok, _} <- run_command(context, profile.install, purpose: "install"),
         {:ok, port} <- pick_and_record_port(store, session_id, mission, task) do
      probe_run(context, workspace, profile, port)
    end
  end

  defp fetch_profile(design) do
    name = design["profile"]

    case Profile.fetch(name) do
      nil -> {:error, {:unsupported_profile, name}}
      profile -> {:ok, profile}
    end
  end

  # Build brief item 4 / §9: "Separate grants, each asked for once and
  # recorded: write to this workspace, run shell, install dependencies
  # (network)." Reused across the whole session, same as
  # `Sprat.Orchestrator`'s fetch-approval grants.
  defp ensure_grants(store, session_id, mission_id) do
    ~w(write_workspace shell network_install)
    |> Enum.reduce_while(:ok, fn action, :ok ->
      case ensure_grant(store, session_id, mission_id, action) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_grant(store, session_id, mission_id, action) do
    if Grants.approved?(store, session_id, action, "session", "build") do
      :ok
    else
      prompt = %{
        title: "Scaffold needs: #{action}",
        lines: ["This build mission wants to #{grant_description(action)}."],
        options: ["Yes", "No"],
        selected: 0
      }

      case Session.await_permission(session_id, prompt) do
        {:ok, 0} ->
          Grants.record(store, session_id, %{
            action: action,
            resource: "build",
            resource_scope: "session",
            lifetime: "session",
            decision: "approved",
            mission_id: mission_id
          })

          :ok

        _ ->
          Grants.record(store, session_id, %{
            action: action,
            resource: "build",
            resource_scope: "session",
            lifetime: "session",
            decision: "denied",
            mission_id: mission_id
          })

          {:error, {:grant_denied, action}}
      end
    end
  end

  defp grant_description("write_workspace"), do: "write files into a build worktree"
  defp grant_description("shell"), do: "run shell commands (scaffold, install, tests, server)"
  defp grant_description("network_install"), do: "reach the network to install dependencies"

  defp commit_and_create_workspace(store, session_id, mission, task, project_dir) do
    git!(project_dir, ["init", "-q", "-b", "main"])
    git!(project_dir, ["config", "user.email", "sprat@localhost"])
    git!(project_dir, ["config", "user.name", "Sprat"])
    git!(project_dir, ["add", "-A"])
    git!(project_dir, ["commit", "-q", "-m", "scaffold"])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: project_dir, stderr_to_stdout: true)
    base_revision = String.trim(sha)

    Workspace.create(project_dir, base_revision, task.id,
      store: store,
      session_id: session_id,
      mission_id: mission.id
    )
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  defp shell_context(store, session_id, mission, task, root, profile) do
    %{
      worktree_root: root,
      granted: %{shell: true, network_install: true},
      mission_id: mission.id,
      task_id: task.id,
      store: store,
      session_id: session_id,
      secrets: [],
      allowed_executables: profile.allowed_executables
    }
  end

  # `Sprat.Agent.Tools.Shell`'s own default timeout (120s) is sized for a
  # model-driven turn, not a from-scratch dependency install — a fresh
  # `mix deps.get` compiling Phoenix and its deps from an empty local hex
  # cache genuinely needs longer. `purpose: "install"` gets a wider
  # ceiling; every other command keeps the tool's own default.
  @install_timeout_ms 300_000

  defp run_command(context, command, opts \\ []) do
    purpose = Keyword.get(opts, :purpose, "other")
    args = %{"command" => command.executable, "args" => command.args, "purpose" => purpose}

    args =
      if purpose == "install", do: Map.put(args, "timeout_ms", @install_timeout_ms), else: args

    Shell.call(args, context)
  end

  # A free port is picked by binding an ephemeral port and releasing it
  # immediately — a genuine, if small, TOCTOU race against another
  # process grabbing it before the run command binds (ponytail: no
  # stdlib primitive hands out a port and holds it reserved; acceptable
  # for a single local dev server, revisit if this scaffold stage is ever
  # run with real concurrency on the same host).
  defp pick_free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Never the profile's stated default (build brief item 4) — the picked
  # port is handed to the run command both as a `PORT` env var (what
  # `mix phx.new`'s own generated `config/runtime.exs` reads
  # unconditionally) and, for a profile whose run command takes a CLI
  # flag, substituted into its args (`Profile.run_command/2`) — and
  # always recorded as an event, so which port a run used is never a
  # guess.
  defp pick_and_record_port(store, session_id, mission, task) do
    port = pick_free_port()

    Events.append(store, session_id, "scaffold.port_selected", %{
      mission_id: mission.id,
      task_id: task.id,
      payload: %{"port" => port}
    })

    {:ok, port}
  end

  # -- start, poll the health check, stop cleanly ---------------------------

  defp probe_run(context, workspace, profile, port) do
    command = Profile.run_command(profile, port)

    case System.find_executable(command.executable) do
      nil ->
        run_result = {:exited, nil, "#{command.executable} not found on PATH"}
        record_run_evidence(context, command, workspace.root, 0, run_result)
        record_health_evidence(context, workspace.root, profile.health_check, port, run_result)
        {:error, {:executable_not_found, command.executable}}

      exe ->
        do_probe_run(context, workspace, profile, port, command, exe)
    end
  end

  defp do_probe_run(context, workspace, profile, port, command, exe) do
    env = Map.put(minimal_env(), "PORT", to_string(port))

    prt =
      Port.open({:spawn_executable, String.to_charlist(exe)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(command.args, &String.to_charlist/1),
        cd: String.to_charlist(workspace.root),
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    os_pid = port_os_pid(prt)
    hc = profile.health_check
    started = System.monotonic_time(:millisecond)
    deadline = started + hc.timeout_ms
    url = "http://127.0.0.1:#{port}#{hc.path}"

    result = poll_loop(prt, os_pid, hc, url, deadline, "")
    duration_ms = System.monotonic_time(:millisecond) - started

    # Always — success, timeout, or crash — nothing is left listening.
    Shell.kill_tree(os_pid)
    safe_close(prt)

    record_run_evidence(context, command, workspace.root, duration_ms, result)
    record_health_evidence(context, workspace.root, hc, port, result)

    case result do
      {:healthy, _output} -> :ok
      {:timeout, _output} -> {:error, :health_check_timeout}
      {:exited, status, _output} -> {:error, {:run_command_exited, status}}
    end
  end

  defp poll_loop(port, os_pid, hc, url, deadline, acc) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:timeout, acc}
    else
      receive do
        {^port, {:data, data}} ->
          poll_loop(port, os_pid, hc, url, deadline, acc <> data)

        {^port, {:exit_status, status}} ->
          {:exited, status, acc}
      after
        hc.poll_interval_ms ->
          case probe_health(url, hc) do
            :ok -> {:healthy, acc}
            :error -> poll_loop(port, os_pid, hc, url, deadline, acc)
          end
      end
    end
  end

  defp probe_health(url, hc) do
    case Req.get(url, retry: false, receive_timeout: 2_000) do
      {:ok, %{status: status}}
      when status >= hc.expect_status_min and status <= hc.expect_status_max ->
        :ok

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp record_run_evidence(context, command, cwd, duration_ms, result) do
    {exit_code, output} =
      case result do
        {:healthy, output} ->
          {0, output <> "\n[stopped by scaffold stage after health check passed]"}

        {:timeout, output} ->
          {0, output <> "\n[stopped by scaffold stage: health check timed out]"}

        {:exited, status, output} ->
          {status || 1, output}
      end

    record_run(
      context,
      command.executable,
      command.args,
      cwd,
      exit_code,
      duration_ms,
      output,
      "run"
    )
  end

  defp record_health_evidence(context, cwd, hc, port, result) do
    url = "http://127.0.0.1:#{port}#{hc.path}"

    {exit_code, output} =
      case result do
        {:healthy, _} ->
          {0, "GET #{url} -> healthy (#{hc.expect_status_min}-#{hc.expect_status_max})"}

        {:timeout, _} ->
          {1, "GET #{url} -> no healthy response within #{hc.timeout_ms}ms"}

        {:exited, status, _} ->
          {1, "GET #{url} -> run command exited (#{inspect(status)}) before it answered"}
      end

    record_run(context, "GET", [url], cwd, exit_code, 0, output, "health_check")
  end

  defp record_run(context, command, args, cwd, exit_code, duration_ms, output, purpose) do
    secrets = Map.get(context, :secrets, [])
    {redacted, _} = Sprat.Store.Redact.scrub(output, secrets)
    {:ok, blob_hash} = Sprat.Store.Blob.put(redacted, [])

    Sprat.Store.Runs.record(Map.fetch!(context, :store), %{
      mission_id: Map.fetch!(context, :mission_id),
      task_id: Map.get(context, :task_id),
      command: command,
      args: args,
      cwd: cwd,
      exit_code: exit_code,
      duration_ms: duration_ms,
      output_blob_hash: blob_hash,
      truncated: false,
      network: false,
      sandbox_strength: "partial",
      purpose: purpose
    })
  end

  defp app_name(mission) do
    mission.objective
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "sprat_app"
      name -> String.slice(name, 0, 30)
    end
    |> then(&("app_" <> &1))
  end

  defp minimal_env do
    current = System.get_env()
    Map.take(current, ["PATH", "HOME", "LANG", "MIX_HOME", "MIX_ARCHIVES"])
  end

  defp safe_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end
end
