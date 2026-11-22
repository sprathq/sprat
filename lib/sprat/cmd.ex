defmodule Sprat.Cmd do
  @moduledoc """
  Runs an external command the way the engine needs it: stdin closed, output
  collected, and killed (the whole OS process, not just the port) if it runs
  past its deadline.

  The engine is one process; a single `cmux`, `git` or `claude` call that
  never returns would freeze every tick, every board command and the
  snapshot the board reads. Everything the engine runs goes through here.

  Returns what `System.cmd/3` returns, `{output, exit_status}`, with
  `{output_so_far, :timeout}` when the deadline passed, and `{"", 127}` when
  the executable is missing.
  """

  require Logger

  @default_timeout 10_000

  @doc """
  Options: `:timeout` (ms, default 10s), `:cd`, `:env` (`[{name, value}]`),
  and `:stderr_to_stdout` (default true).
  """
  @spec run(String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer() | :timeout}
  def run(bin, args, opts \\ []) do
    case resolve(bin) do
      nil ->
        {"", 127}

      exe ->
        # Every program Sprat runs is counted in `Sprat.Activity` (how often,
        # how long, how it ended); slow and stopped runs reach its stream.
        token = Sprat.Activity.command_started(exe, args)
        {_out, status} = result = spawn_and_wait(exe, args, opts)
        Sprat.Activity.command_done(token, status)
        result
    end
  end

  @doc "A `System.cmd/3`-compatible function with the given deadline."
  def with_timeout(ms),
    do: fn bin, args, opts -> run(bin, args, Keyword.put(opts, :timeout, ms)) end

  defp resolve(bin) do
    if String.contains?(bin, "/"),
      do: if(File.exists?(bin), do: bin),
      else: System.find_executable(bin)
  end

  defp spawn_and_wait(exe, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    sh = System.find_executable("sh") || "/bin/sh"

    port_opts =
      [
        :binary,
        :exit_status,
        :eof,
        :hide,
        args: ["-c", ~s(exec "$0" "$@" < /dev/null), exe | args]
      ] ++
        if(Keyword.get(opts, :stderr_to_stdout, true), do: [:stderr_to_stdout], else: []) ++
        cd(opts[:cd]) ++ env(opts[:env])

    port = Port.open({:spawn_executable, sh}, port_opts)
    os_pid = Port.info(port, :os_pid) |> then(fn {:os_pid, p} -> p end)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, os_pid, exe, deadline, {[], false, nil})
  rescue
    e -> {Exception.message(e), 127}
  end

  # With `:eof` the port reports end of output and the exit status
  # separately; waiting for both means no trailing output is lost to an exit
  # status that arrived first.
  defp collect(port, _os_pid, _exe, _deadline, {acc, true, status}) when status != nil do
    safe_close(port)
    {IO.iodata_to_binary(acc), status}
  end

  defp collect(port, os_pid, exe, deadline, {acc, eof?, status}) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, exe, deadline, {[acc | data], eof?, status})

      {^port, :eof} ->
        collect(port, os_pid, exe, deadline, {acc, true, status})

      {^port, {:exit_status, code}} ->
        collect(port, os_pid, exe, deadline, {acc, eof?, code})
    after
      left ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        safe_close(port)
        flush(port)
        Logger.warning("sprat: #{Path.basename(exe)} did not finish in time and was stopped")
        {IO.iodata_to_binary(acc), :timeout}
    end
  end

  defp cd(nil), do: []
  defp cd(dir), do: [cd: String.to_charlist(dir)]

  defp env(nil), do: []

  defp env(vars),
    do: [
      env: Enum.map(vars, fn {k, v} -> {String.to_charlist(k), v && String.to_charlist(v)} end)
    ]

  defp safe_close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end
end
