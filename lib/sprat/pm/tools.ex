defmodule Sprat.PM.Tools do
  @moduledoc """
  The tools Sprat's PM runs get beyond Claude Code's own read/web tools
  (spec-v4 §8.2), served over MCP by `Sprat.PM.MCPServer`.

  All read-only except `run_check`, which runs an allow-listed command in a
  throwaway worktree, never in the agent's checkout. Roadmap marks are not a
  tool: the PM *decides* `blocked_item`, and the engine applies it after
  `Sprat.PM.Policy` (so every write is policy-checked and revertible).
  """

  alias Sprat.Observer.{ConfigDirs, Transcript}

  @doc "Tool definitions in MCP `tools/list` shape."
  def definitions do
    [
      %{
        name: "roadmap_get",
        description:
          "The project's roadmap as Sprat sees it (phases, items with ids like C.4, states, blocked reasons, sources) in the .sprat/roadmap.md format, plus the current position.",
        inputSchema:
          obj(%{project_root: str("Absolute path of the project repository")}, [:project_root])
      },
      %{
        name: "roadmap_unblocked",
        description:
          "Items in the project's active phase that are neither done nor blocked, in order. Use it to pick what to give an agent whose current item is blocked.",
        inputSchema:
          obj(%{project_root: str("Absolute path of the project repository")}, [:project_root])
      },
      %{
        name: "fleet_search",
        description:
          "Search every Claude Code transcript on this machine (all projects, last 120 days) for a text, e.g. an error message. Returns where it occurred and what happened in the turns after it, which often shows how it was fixed before.",
        inputSchema:
          obj(
            %{
              query:
                str("Exact text to search for, e.g. the distinctive part of an error message"),
              limit: %{type: "integer", description: "Max hits (default 8)"}
            },
            [:query]
          )
      },
      %{
        name: "memory_search",
        description:
          "Search the owner's MemPalace memory (past decisions, notes, project history across all projects). Optionally limit to one wing (project).",
        inputSchema:
          obj(%{query: str("What to look for"), wing: str("Optional wing (project) name")}, [
            :query
          ])
      },
      %{
        name: "run_check",
        description:
          "Run an allow-listed check command (tests, build, lint) for the project in a throwaway git worktree at HEAD, never in the agent's checkout. Returns exit code and the tail of the output.",
        inputSchema:
          obj(
            %{
              project_root: str("Absolute path of the project repository"),
              command: str("The exact command, e.g. `mix test test/foo_test.exs`")
            },
            [:project_root, :command]
          )
      }
    ]
  end

  @doc "Dispatches a tool call. Returns `{:ok, text}` or `{:error, text}`."
  def call(name, args, opts \\ [])

  def call("roadmap_get", %{"project_root" => root}, _opts) do
    with {:ok, root} <- existing_dir(root) do
      now = DateTime.utc_now()
      {roadmap, commits} = Sprat.Roadmap.load(root, now: now)

      position =
        Sprat.Roadmap.Position.compute(
          roadmap,
          Sprat.Roadmap.Progress.from_git(commits, roadmap),
          now
        )

      {:ok,
       Sprat.Roadmap.File.render(roadmap) <>
         "\n\nposition: phase #{position.phase_id} #{position.done}/#{position.total}, " <>
         "next item #{position.item_id} #{position.item_text}\n" <>
         notes(roadmap)}
    end
  end

  def call("roadmap_unblocked", %{"project_root" => root}, _opts) do
    with {:ok, root} <- existing_dir(root) do
      {roadmap, _} = Sprat.Roadmap.load(root)
      items = Sprat.Roadmap.unblocked(roadmap)

      case items do
        [] -> {:ok, "No unblocked items in the active phase."}
        items -> {:ok, Enum.map_join(items, "\n", &"#{&1.id} #{&1.text}")}
      end
    end
  end

  def call("fleet_search", %{"query" => query} = args, opts) do
    limit = Map.get(args, "limit", 8)
    {:ok, fleet_search(query, limit, opts)}
  end

  def call("memory_search", %{"query" => query} = args, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    bin = System.find_executable("mempalace") || Path.expand("~/.local/bin/mempalace")

    if File.exists?(bin) do
      wing = if w = args["wing"], do: ["--wing", w], else: []

      case cmd.(bin, ["search", query, "--results", "6"] ++ wing, stderr_to_stdout: true) do
        {out, 0} -> {:ok, truncate(out, 6000)}
        {out, code} -> {:error, "mempalace exited #{code}: #{truncate(out, 500)}"}
      end
    else
      {:error, "MemPalace is not installed on this machine."}
    end
  end

  def call("run_check", %{"project_root" => root, "command" => command}, opts) do
    with {:ok, root} <- existing_dir(root),
         :ok <- allowed_check(root, command, opts) do
      run_check(root, command, opts)
    end
  end

  def call(name, _args, _opts), do: {:error, "Unknown tool or missing arguments: #{name}"}

  # -- fleet search -------------------------------------------------------------

  @doc false
  def fleet_search(query, limit, opts \\ []) do
    dirs = Keyword.get_lazy(opts, :config_dirs, fn -> ConfigDirs.list([]) end)
    cutoff = System.os_time(:second) - 120 * 86_400

    files =
      dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([&1, "projects", "*", "*.jsonl"])))
      |> Enum.filter(fn f ->
        case File.stat(f, time: :posix) do
          {:ok, %{mtime: m}} -> m >= cutoff
          _ -> false
        end
      end)

    hits = grep(files, query, limit * 3)

    hits
    |> Enum.uniq_by(fn {file, _line} -> file end)
    |> Enum.take(limit)
    |> Enum.map(fn {file, line} -> describe_hit(file, line) end)
    |> case do
      [] -> "No transcript on this machine mentions that text."
      parts -> Enum.join(parts, "\n\n---\n\n")
    end
  end

  defp grep([], _query, _max), do: []

  defp grep(files, query, max) do
    rg = System.find_executable("rg")

    {out, _} =
      if rg do
        System.cmd(rg, ["-n", "-F", "--max-count", "2", "--no-heading", "--", query | files],
          stderr_to_stdout: false
        )
      else
        System.cmd("grep", ["-n", "-F", "-m", "2", "--", query | files], stderr_to_stdout: false)
      end

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn l ->
      case Regex.run(~r/^(.+\.jsonl):(\d+):/, l) do
        [_, file, n] -> [{file, String.to_integer(n)}]
        _ -> []
      end
    end)
    |> Enum.take(max)
  end

  defp describe_hit(file, line) do
    project = file |> Path.dirname() |> Path.basename()
    session = Path.basename(file, ".jsonl")

    following =
      file
      |> File.stream!()
      |> Stream.with_index(1)
      |> Stream.drop(line - 1)
      |> Stream.take(80)
      |> Enum.flat_map(fn {l, n} -> Transcript.parse_line(l, n) end)
      |> Enum.flat_map(&summarise_event/1)
      |> Enum.take(14)

    "#{project} · session #{session} · line #{line}\n" <> Enum.join(following, "\n")
  rescue
    _ -> "#{file}:#{line}"
  end

  defp summarise_event(%{kind: :assistant_text, data: d}),
    do: ["assistant: " <> one_line(d[:text] || d["text"], 300)]

  defp summarise_event(%{kind: :user_text, data: d}),
    do: ["user: " <> one_line(d[:text] || d["text"], 200)]

  defp summarise_event(%{kind: :tool_use, data: d}) do
    input = d[:input] || d["input"] || %{}
    detail = input["command"] || input["file_path"] || input["pattern"] || ""
    ["tool: #{d[:name] || d["name"]} #{one_line(to_string(detail), 160)}"]
  end

  defp summarise_event(%{kind: :tool_result, data: d}) do
    if d[:is_error] || d["is_error"],
      do: ["error: " <> one_line(d[:text] || d["text"] || "", 200)],
      else: []
  end

  defp summarise_event(_), do: []

  # -- checks -------------------------------------------------------------------

  @default_allowed ~w(mix\ test mix\ compile mix\ format npm\ test npm\ run\ test npm\ run\ build
                      pnpm\ test yarn\ test npx\ tsc flutter\ test flutter\ analyze dart\ test
                      pytest python\ -m\ pytest cargo\ test cargo\ build go\ test go\ build
                      xcodebuild\ test swift\ test bundle\ exec\ rspec)

  defp allowed_check(root, command, opts) do
    allowed = Keyword.get_lazy(opts, :allowed_checks, fn -> project_allowed(root) end)

    cond do
      String.match?(command, ~r/[;&|`$<>]/) ->
        {:error, "Refused: run_check takes one plain command, no shell operators."}

      Enum.any?(allowed, &(command == &1 or String.starts_with?(command, &1 <> " "))) ->
        :ok

      true ->
        {:error,
         "Refused: `#{command}` is not an allowed check for this project. Allowed: #{Enum.join(allowed, ", ")}"}
    end
  end

  defp project_allowed(root) do
    # The same file Verify runs on Stop (`#` lines are comments there too).
    @default_allowed ++ Sprat.Verify.load_checks(root)
  end

  defp run_check(root, command, opts) do
    timeout = Keyword.get(opts, :check_timeout_ms, 600_000)
    tmp = Path.join(System.tmp_dir!(), "sprat-check-#{System.unique_integer([:positive])}")

    with {_, 0} <-
           System.cmd("git", ["-C", root, "worktree", "add", "--detach", tmp, "HEAD"],
             stderr_to_stdout: true
           ) do
      # Reuse heavy dependency dirs read-mostly so a check doesn't refetch the world.
      for dir <- ~w(deps node_modules _build .dart_tool Pods),
          File.exists?(Path.join(root, dir)) do
        File.ln_s(Path.join(root, dir), Path.join(tmp, dir))
      end

      [bin | args] = OptionParser.split(command)

      task =
        Task.async(fn ->
          System.cmd(bin, args, cd: tmp, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}])
        end)

      result =
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, {out, code}} ->
            {:ok, "exit #{code} (in a throwaway worktree at HEAD)\n" <> tail(out, 4000)}

          nil ->
            {:ok, "timed out after #{div(timeout, 1000)}s"}
        end

      System.cmd("git", ["-C", root, "worktree", "remove", "--force", tmp],
        stderr_to_stdout: true
      )

      result
    else
      {out, _} -> {:error, "Could not create a worktree: #{truncate(out, 400)}"}
    end
  rescue
    e -> {:error, "run_check failed: #{Exception.message(e)}"}
  end

  # -- helpers ------------------------------------------------------------------

  defp existing_dir(path) do
    path = Path.expand(path)
    if File.dir?(path), do: {:ok, path}, else: {:error, "No such directory: #{path}"}
  end

  defp notes(%{notes: [_ | _] = notes}),
    do: "notes:\n" <> Enum.map_join(notes, "\n", &"- #{inspect_note(&1)}")

  defp notes(_), do: ""

  defp inspect_note(n) when is_binary(n), do: n
  defp inspect_note(n), do: inspect(n)

  defp obj(props, required),
    do: %{type: "object", properties: props, required: Enum.map(required, &to_string/1)}

  defp str(desc), do: %{type: "string", description: desc}

  defp one_line(nil, _), do: ""
  defp one_line(text, max), do: text |> String.replace(~r/\s+/, " ") |> truncate(max)

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp tail(text, max) do
    len = String.length(text)
    if len > max, do: "…" <> String.slice(text, len - max, max), else: text
  end
end
