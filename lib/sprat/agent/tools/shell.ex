defmodule Sprat.Agent.Tools.Shell do
  @moduledoc """
  `shell` tool (docs/spec-v2.md §7/§9, spec-full.md §10/§11) — the
  dangerous one. Non-negotiable rules this module enforces:

    * **Explicit argument array, never a shell string.** `call/2` only
      accepts `"command"` (a bare executable name — no `/`, so a caller
      can't smuggle a path past the allow list) plus `"args"` (a list of
      strings). It spawns via `Port.open({:spawn_executable, ...}, args:
      ...)`, never `System.cmd("sh", ["-c", text])` — there is no code
      path here that concatenates model output into a string a shell then
      interprets.
    * **Allow list per call.** `context[:allowed_executables]` (default
      #{inspect(~w(mix npm git node elixir))}); anything else is refused
      by name, not silently dropped.
    * **Timeout with a real process-tree kill.** A command that outlives
      its timeout, and every descendant it has spawned by then (found via
      `pgrep -P`, walked breadth-first, killed leaves-first with
      `SIGKILL`), is killed — not just the BEAM's own port/child, which is
      only the immediate process (spec-full §11: BEAM worker termination
      alone doesn't guarantee grandchildren stop).
    * **Explicit, minimal environment.** Every variable inherited from
      this OS process is unset unless it's `PATH`/`HOME` or explicitly
      declared via `context[:env]`; nothing else leaks into the child by
      default.
    * **Network off by default.** Only `"purpose": "install"` may run with
      network reachable, and only with the `network_install` grant present
      — every such run is recorded with `network: true`.
    * **Sandbox strength is `"partial"`, honestly**: this module confines
      *cwd*, the argument array, the environment and the allow list, and
      kills the real process tree on timeout — but it does not sandbox
      what an allowed executable can itself read or write on the
      filesystem, or open a socket to, at the OS level (spec-full §10:
      "File checks alone do not sandbox a general-purpose shell"). Every
      recorded run says `"partial"`, never `"enforced"`.

  `context` required: `:worktree_root`, `:granted` (`%{shell: boolean,
  network_install: boolean}`), `:mission_id`. Optional: `:task_id`,
  `:store`, `:secrets`, `:env` (map of extra vars to set),
  `:allowed_executables`, `:blob_root`.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Store.{Blob, Paths, Redact, Runs}

  @impl true
  def name, do: "shell"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "shell",
        "description" =>
          "Run an allow-listed executable with an explicit argument array, inside the " <>
            "task's worktree.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "command" => %{"type" => "string", "description" => "bare executable name"},
            "args" => %{"type" => "array", "items" => %{"type" => "string"}},
            "purpose" => %{"type" => "string", "enum" => Runs.purposes()},
            "timeout_ms" => %{"type" => "integer"}
          },
          "required" => ["command", "args", "purpose"]
        }
      }
    }
  end

  @default_allow ~w(mix npm git node elixir)
  @default_timeout_ms 120_000
  @max_output_bytes 200_000
  @sandbox_strength "partial"
  @kill_poll_interval_ms 500

  @impl true
  def call(%{"command" => command, "args" => args} = params, context)
      when is_binary(command) and is_list(args) do
    purpose = Map.get(params, "purpose", "other")
    timeout_ms = Map.get(params, "timeout_ms", @default_timeout_ms)

    with :ok <- validate_args(args),
         :ok <- validate_purpose(purpose),
         :ok <- check_grant(context, :shell),
         :ok <- check_network_grant(purpose, context),
         {:ok, exe} <- resolve_executable(command, context) do
      run(exe, command, args, purpose, timeout_ms, context)
    end
  end

  def call(_args, _context),
    do:
      {:error,
       "expected {\"command\": \"<bare name>\", \"args\": [\"...\"], \"purpose\": \"...\"} — " <>
         "args must be an explicit array, never a shell string"}

  defp validate_args(args) do
    if Enum.all?(args, &is_binary/1),
      do: :ok,
      else: {:error, %{"kind" => "invalid_args", "message" => "every arg must be a string"}}
  end

  defp validate_purpose(purpose) do
    if purpose in Runs.purposes(),
      do: :ok,
      else:
        {:error,
         %{
           "kind" => "invalid_purpose",
           "message" => "purpose must be one of #{inspect(Runs.purposes())}"
         }}
  end

  defp check_grant(context, :shell) do
    if get_in(context, [:granted, :shell]),
      do: :ok,
      else: {:needs_approval, %{action: "shell", reason: :grant_not_yet_given}}
  end

  defp check_network_grant("install", context) do
    if get_in(context, [:granted, :network_install]),
      do: :ok,
      else: {:needs_approval, %{action: "network_install", reason: :grant_not_yet_given}}
  end

  defp check_network_grant(_purpose, _context), do: :ok

  defp resolve_executable(command, context) do
    allow_list = Map.get(context, :allowed_executables, @default_allow)

    cond do
      String.contains?(command, "/") ->
        {:error,
         %{
           "kind" => "executable_denied",
           "message" => "#{command} is not a bare executable name"
         }}

      command not in allow_list ->
        {:error,
         %{
           "kind" => "executable_denied",
           "message" => "#{command} is not on this profile's allow list #{inspect(allow_list)}"
         }}

      true ->
        case System.find_executable(command) do
          nil ->
            {:error, %{"kind" => "executable_not_found", "message" => "#{command} not found"}}

          path ->
            {:ok, path}
        end
    end
  end

  defp run(exe, command, args, purpose, timeout_ms, context) do
    worktree_root = Map.fetch!(context, :worktree_root)
    env = minimal_env(Map.get(context, :env, %{}))

    port =
      Port.open({:spawn_executable, String.to_charlist(exe)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &String.to_charlist/1),
        cd: String.to_charlist(worktree_root),
        env: port_env(env)
      ])

    os_pid = port_os_pid(port)
    started = System.monotonic_time(:millisecond)

    {output, exit_code, truncated?, timed_out?} =
      collect(port, os_pid, timeout_ms, started, "", false)

    duration_ms = System.monotonic_time(:millisecond) - started
    secrets = Map.get(context, :secrets, [])
    {redacted_output, _redacted?} = Redact.scrub(output, secrets)
    {:ok, blob_hash} = Blob.put(redacted_output, [], blob_root(context))

    network? = purpose == "install"

    record_run(context, command, args, worktree_root, exit_code, duration_ms, blob_hash,
      truncated?: truncated?,
      network?: network?,
      purpose: purpose
    )

    build_result(
      command,
      timeout_ms,
      timed_out?,
      exit_code,
      redacted_output,
      truncated?,
      blob_hash
    )
  end

  defp build_result(command, timeout_ms, true, _exit_code, _output, _truncated?, blob_hash) do
    {:error,
     %{
       "kind" => "timeout",
       "message" => "#{command} timed out after #{timeout_ms}ms; its process tree was killed",
       "blob_hash" => blob_hash
     }}
  end

  defp build_result(_command, _timeout_ms, false, 0, output, truncated?, blob_hash) do
    {:ok,
     %{"exit_code" => 0, "output" => output, "truncated" => truncated?, "blob_hash" => blob_hash}}
  end

  defp build_result(_command, _timeout_ms, false, exit_code, output, truncated?, blob_hash) do
    {:error,
     %{
       "kind" => "nonzero_exit",
       "exit_code" => exit_code,
       "output" => output,
       "truncated" => truncated?,
       "blob_hash" => blob_hash
     }}
  end

  defp record_run(context, command, args, cwd, exit_code, duration_ms, blob_hash, opts) do
    Runs.record(Map.get(context, :store, Sprat.Store), %{
      mission_id: Map.fetch!(context, :mission_id),
      task_id: Map.get(context, :task_id),
      command: command,
      args: args,
      cwd: cwd,
      exit_code: exit_code,
      duration_ms: duration_ms,
      output_blob_hash: blob_hash,
      truncated: Keyword.fetch!(opts, :truncated?),
      network: Keyword.fetch!(opts, :network?),
      sandbox_strength: @sandbox_strength,
      purpose: Keyword.fetch!(opts, :purpose)
    })
  end

  # -- output capture -----------------------------------------------------

  defp collect(port, os_pid, timeout_ms, started, acc, truncated?) do
    remaining = timeout_ms - (System.monotonic_time(:millisecond) - started)

    if remaining <= 0 do
      kill_tree(os_pid)
      safe_close(port)
      {acc, nil, truncated?, true}
    else
      receive do
        {^port, {:data, data}} ->
          {acc, truncated?} = append_capped(acc, data, truncated?)
          collect(port, os_pid, timeout_ms, started, acc, truncated?)

        {^port, {:exit_status, status}} ->
          {acc, status, truncated?, false}
      after
        min(remaining, @kill_poll_interval_ms) ->
          collect(port, os_pid, timeout_ms, started, acc, truncated?)
      end
    end
  end

  defp append_capped(acc, _data, true), do: {acc, true}

  defp append_capped(acc, data, false) do
    combined = acc <> data

    if byte_size(combined) > @max_output_bytes do
      {binary_part(combined, 0, @max_output_bytes) <> "\n...[truncated]", true}
    else
      {combined, false}
    end
  end

  defp safe_close(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  # -- process-tree kill ---------------------------------------------------

  @doc false
  def kill_tree(nil), do: :ok

  def kill_tree(os_pid) do
    os_pid
    |> collect_descendants()
    |> Enum.reverse()
    |> Enum.each(fn pid ->
      System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
    end)
  end

  defp collect_descendants(root_pid), do: bfs([root_pid], [root_pid])

  defp bfs([], acc), do: acc

  defp bfs(frontier, acc) do
    children = frontier |> Enum.flat_map(&children_of/1) |> Enum.reject(&(&1 in acc))

    case children do
      [] -> acc
      more -> bfs(more, acc ++ more)
    end
  end

  defp children_of(pid) do
    case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        output |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)

      _ ->
        []
    end
  end

  # -- environment ----------------------------------------------------------

  # Explicit and minimal: every variable inherited from this OS process is
  # unset unless it's PATH/HOME or was explicitly declared by the caller
  # (`extra`) — a secret loaded "by name" per §9 lands here, named
  # explicitly, never by blanket inheritance.
  defp minimal_env(extra) do
    current = System.get_env()

    keep =
      %{"PATH" => Map.get(current, "PATH", ""), "HOME" => Map.get(current, "HOME", "")}
      |> Map.merge(extra)

    unset =
      current
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(keep, &1))
      |> Map.new(&{&1, nil})

    Map.merge(unset, keep)
  end

  defp port_env(env) do
    Enum.map(env, fn
      {k, nil} -> {String.to_charlist(k), false}
      {k, v} -> {String.to_charlist(k), String.to_charlist(v)}
    end)
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp blob_root(context), do: Map.get(context, :blob_root) || Paths.blobs_dir()
end
