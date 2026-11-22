defmodule Experiment.Codex do
  @moduledoc """
  Invokes the installed `codex` CLI and parses its JSONL event stream.

  Deviation from the brief: the brief asks to pipe the prompt on stdin
  (trailing `-`). Plain `Port`/`System.cmd` in OTP cannot half-close a
  child's stdin while continuing to read its stdout — there is no partial
  close, only a hard close of both directions at once — so a piped prompt
  makes codex block forever waiting for EOF that never comes. `codex exec`
  also accepts the prompt as a normal positional argument (confirmed via
  `codex exec --help`), so that's what this module does: the prompt is
  written to a file under the run directory and redirected into codex's
  stdin (`< file`) via a minimal `sh -c` wrapper. The command string is
  built only from paths and flags the harness itself generates — schema
  path, output path, prompt file path — never from model output, so the
  "never interpolate model output into a shell string" rule still holds;
  model text lives in the prompt *file*, not in the shell command.
  """

  @codex_exe System.find_executable("codex") || "codex"
  @default_timeout_ms 15 * 60 * 1000

  @doc """
  Run one `codex exec` call.

  Options:
    * `:schema` — path to the --output-schema file (required)
    * `:output_file` — path codex writes its last message to (required)
    * `:events_file` — path to write the raw JSONL event stream to (required)
    * `:run_dir` — scratch dir for the prompt file (required)
    * `:web_search` — include `-c web_search="live"` (default true; judge calls pass false)
    * `:timeout_ms` — per-call wall-clock budget (default 15 min)

  Returns `{:ok, %{stage_output: map, usage: map, web_search_calls: n, web_search_queries: [str]}}`
  or `{:error, reason}` where reason is `:timeout`, `{:exit_status, n}` or `{:invalid_output, detail}`.
  """
  def call(prompt, opts) do
    schema = Keyword.fetch!(opts, :schema)
    output_file = Keyword.fetch!(opts, :output_file)
    events_file = Keyword.fetch!(opts, :events_file)
    run_dir = Keyword.fetch!(opts, :run_dir)
    web_search? = Keyword.get(opts, :web_search, true)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    kind = Keyword.get(opts, :kind, :stage)

    File.mkdir_p!(run_dir)
    File.mkdir_p!(Path.dirname(output_file))
    File.mkdir_p!(Path.dirname(events_file))
    File.rm(output_file)

    prompt_file = Path.join(run_dir, "prompt-#{:erlang.unique_integer([:positive])}.txt")
    File.write!(prompt_file, prompt)

    cmd = build_command(schema, output_file, web_search?, prompt_file)

    result =
      case spawn_and_wait(cmd, timeout_ms) do
        {:ok, raw_output, 0} ->
          File.write!(events_file, raw_output)
          parse_success(raw_output, output_file, kind)

        {:ok, raw_output, status} ->
          File.write!(events_file, raw_output)
          {:error, {:exit_status, status}}

        {:error, :timeout, raw_output} ->
          File.write!(events_file, raw_output)
          {:error, :timeout}
      end

    File.rm(prompt_file)
    result
  end

  @doc "Run `call/2` once, then once more on failure. Returns {:ok, result} | {:error, last_reason}."
  def call_with_retry(prompt, opts) do
    case call(prompt, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        case call(prompt, opts) do
          {:ok, result} -> {:ok, result}
          {:error, reason2} -> {:error, reason2 || reason}
        end
    end
  end

  defp build_command(schema, output_file, web_search?, prompt_file) do
    search_flags = if web_search?, do: ["-c", ~s(web_search="live")], else: []

    args =
      [
        @codex_exe,
        "exec",
        "--json",
        "--ephemeral",
        "--skip-git-repo-check",
        "--ignore-user-config",
        "--ignore-rules",
        "-s",
        "read-only"
      ] ++
        search_flags ++
        ["--output-schema", schema, "-o", output_file]

    (args |> Enum.map(&shell_quote/1) |> Enum.join(" ")) <> " < " <> shell_quote(prompt_file)
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp spawn_and_wait(cmd, timeout_ms) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["-c", cmd]
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect(port, os_pid, deadline, [])
  end

  defp collect(port, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, [data | acc])

      {^port, {:exit_status, status}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        if os_pid,
          do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)

        Port.close(port)
        {:error, :timeout, acc |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  defp parse_success(raw_output, output_file, kind) do
    events =
      raw_output
      |> String.split("\n", trim: true)
      |> Enum.map(&safe_decode/1)
      |> Enum.reject(&is_nil/1)

    usage =
      events
      |> Enum.find_value(%{}, fn
        %{"type" => "turn.completed", "usage" => usage} -> usage
        _ -> nil
      end)

    web_search_items = Enum.filter(events, &match?(%{"item" => %{"type" => "web_search"}}, &1))

    queries =
      web_search_items
      |> Enum.flat_map(fn %{"item" => item} ->
        case item["action"] do
          %{"queries" => qs} when is_list(qs) -> qs
          %{"query" => q} when is_binary(q) and q != "" -> [q]
          _ -> []
        end
      end)

    web_search_calls =
      web_search_items
      |> Enum.map(& &1["item"]["id"])
      |> Enum.uniq()
      |> length()

    case File.read(output_file) do
      {:ok, content} ->
        case validate(kind, safe_decode(content)) do
          {:ok, output} ->
            {:ok,
             %{
               stage_output: output,
               usage: usage,
               web_search_calls: web_search_calls,
               web_search_queries: queries
             }}

          :error ->
            {:error, {:invalid_output, "missing required fields for #{kind}"}}
        end

      {:error, reason} ->
        {:error, {:invalid_output, reason}}
    end
  end

  defp validate(:stage, %{
         "artifact_markdown" => md,
         "sources" => sources,
         "assumptions" => assumptions,
         "handoff" => handoff
       })
       when is_binary(md) and is_list(sources) and is_list(assumptions) and is_binary(handoff) do
    {:ok,
     %{
       "artifact_markdown" => md,
       "sources" => sources,
       "assumptions" => assumptions,
       "handoff" => handoff
     }}
  end

  defp validate(:judge, %{"rubric" => rubric, "counts" => counts, "verdict" => verdict} = output)
       when is_map(rubric) and is_map(counts) and verdict in ["a", "b", "tie"] do
    {:ok, output}
  end

  defp validate(_kind, _decoded), do: :error

  defp safe_decode(text) do
    case JSON.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end
end
