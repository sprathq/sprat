defmodule Sprat.Recap do
  @moduledoc """
  What a session did over the last few hours, read from its transcript: what
  the owner and Sprat asked, where the agent ended each turn, which
  repositories it edited, its commits, test runs and stops.

  Built without a model, so it is free and instant, and it follows the work
  wherever it went: a session started in one folder that edits another repo
  shows that repo.

  The engine keeps only a session's last events, so the recap reads the
  transcript file itself, its tail only (`@tail_bytes`), and the transcripts
  of the subagents it ran (`<session>/subagents/*.jsonl`): their edits, test
  runs and commits are the session's work too; their chat is not.
  """

  alias Sprat.Observer.Transcript

  @tail_bytes 24 * 1024 * 1024
  @text 220

  @type entry :: %{at: DateTime.t() | nil, kind: atom(), text: String.t()}
  @type t :: %{
          since: DateTime.t(),
          from: DateTime.t() | nil,
          cut?: boolean(),
          counts: %{atom() => non_neg_integer()},
          repos: [{String.t(), non_neg_integer()}],
          timeline: [entry()]
        }

  @doc """
  Reads the transcript at `path` and recaps it since `since`. `cut?` is true
  when the tail read starts after `since` (older events were not read).
  """
  @spec from_file(String.t(), DateTime.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_file(path, since, opts \\ []) do
    tail = Keyword.get(opts, :tail_bytes, @tail_bytes)

    with {:ok, events, offset} <- read_events(path, tail) do
      first_at = Enum.find_value(events, & &1.at)
      cut? = offset > 0 and (first_at == nil or DateTime.compare(first_at, since) == :gt)

      events =
        (events ++ subagent_events(path, since, tail))
        |> Enum.sort_by(&if(&1.at, do: DateTime.to_unix(&1.at, :millisecond), else: 0))

      {:ok, %{build(events, since, opts) | cut?: cut?}}
    end
  end

  defp read_events(path, tail) do
    with {:ok, bin, offset} <- read_tail(path, tail) do
      lines = String.split(bin, "\n")
      # A tail read starts mid-line: drop that partial first line.
      lines = if offset > 0, do: tl(lines), else: lines

      events =
        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {l, n} -> if l == "", do: [], else: Transcript.parse_line(l, n) end)

      {:ok, events, offset}
    end
  end

  # Tool calls of the subagents written to since `since`; their prompts and
  # prose stay out (they are the session's own delegation, not the owner's).
  defp subagent_events(path, since, tail) do
    dir = Path.join(Path.rootname(path), "subagents")
    cutoff = DateTime.to_unix(since)

    dir
    |> Path.join("*.jsonl")
    |> Path.wildcard()
    |> Enum.filter(fn f ->
      match?({:ok, %File.Stat{mtime: m}} when m >= cutoff, File.stat(f, time: :posix))
    end)
    |> Enum.flat_map(fn f ->
      case read_events(f, tail) do
        {:ok, events, _} -> Enum.filter(events, &(&1.kind in [:tool_use, :tool_result]))
        _ -> []
      end
    end)
  end

  defp read_tail(path, bytes) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      offset = max(size - bytes, 0)

      try do
        case :file.pread(io, offset, size - offset) do
          {:ok, bin} -> {:ok, bin, offset}
          :eof -> {:ok, "", offset}
          {:error, e} -> {:error, e}
        end
      after
        File.close(io)
      end
    end
  end

  @doc """
  Recaps `events` (transcript events, oldest first) from `since` on.
  `repo_of` maps a directory to its repository root (default: the nearest
  ancestor holding `.git`).
  """
  @spec build([Sprat.Observer.Model.Event.t()], DateTime.t(), keyword()) :: t()
  def build(events, since, opts \\ []) do
    repo_of = Keyword.get(opts, :repo_of, &git_root/1)

    events =
      Enum.filter(events, fn e -> e.at == nil or DateTime.compare(e.at, since) != :lt end)

    results =
      for %{kind: :tool_result, data: d} <- events, id = d[:tool_use_id], into: %{} do
        {id, d[:is_error] == true}
      end

    acc = %{
      counts: %{you: 0, sprat: 0, turns: 0, edits: 0, commits: 0, tests: 0, failed: 0, limits: 0},
      repos: %{},
      timeline: [],
      last_said: nil,
      roots: %{}
    }

    acc =
      events
      |> Enum.reduce(acc, fn e, acc -> step(e, acc, results, repo_of) end)
      |> end_turn()

    %{
      since: since,
      from: Enum.find_value(events, & &1.at),
      cut?: false,
      counts: acc.counts,
      repos: acc.repos |> Enum.sort_by(fn {name, n} -> {-n, name} end),
      # A turn's end is known only at the next prompt: order by time.
      timeline:
        acc.timeline
        |> Enum.reverse()
        |> Enum.sort_by(&if(&1.at, do: DateTime.to_unix(&1.at, :millisecond), else: 0))
    }
  end

  # -- one event -------------------------------------------------------------------

  defp step(%{kind: :user_text, sidechain?: false, at: at, data: d}, acc, _results, _repo_of) do
    text = one(d[:text])

    cond do
      # Claude Code's own marker when the owner presses esc, not a prompt.
      text == "" or String.starts_with?(text, "[Request interrupted") ->
        acc

      String.starts_with?(text, "[sprat]") ->
        acc
        |> end_turn()
        |> bump(:sprat)
        |> add(at, :sprat, String.trim_leading(text, "[sprat] "))

      true ->
        acc |> end_turn() |> bump(:you) |> add(at, :you, text)
    end
  end

  defp step(%{kind: :assistant_text, sidechain?: false, at: at, data: d}, acc, _r, _repo_of) do
    case one(d[:text]) do
      "" -> acc
      text -> %{acc | last_said: {at, text}}
    end
  end

  defp step(%{kind: :tool_use, at: at, data: d} = e, acc, results, repo_of) do
    name = d[:name]
    input = d[:input] || %{}
    failed? = Map.get(results, d[:id]) == true

    cond do
      name in ~w(Edit Write MultiEdit NotebookEdit) ->
        acc
        |> bump(:edits)
        |> worked_in(dir_of(input["file_path"] || input["notebook_path"]), repo_of)

      name == "Bash" ->
        bash(acc, at, to_string(input["command"] || ""), failed?, repo_of, e)

      true ->
        acc
    end
  end

  defp step(%{kind: :api_error, at: at, data: d}, acc, _results, _repo_of) do
    if d[:limit?],
      do: acc |> bump(:limits) |> add(at, :stop, one(d[:text]) |> blank_to("usage limit")),
      else: acc
  end

  defp step(_e, acc, _results, _repo_of), do: acc

  defp bash(acc, at, cmd, failed?, repo_of, _e) do
    dir = bash_dir(cmd)
    acc = worked_in(acc, dir, repo_of)

    cond do
      commit?(cmd) and not failed? ->
        acc |> bump(:commits) |> add(at, :commit, commit_message(cmd))

      test?(cmd) and failed? ->
        acc |> bump(:tests) |> bump(:failed) |> add(at, :failed, one(cmd))

      test?(cmd) ->
        bump(acc, :tests)

      true ->
        acc
    end
  end

  # -- turns -------------------------------------------------------------------------

  # The agent's last words before the next prompt (or the end) close a turn.
  defp end_turn(%{last_said: nil} = acc), do: acc

  defp end_turn(%{last_said: {at, text}} = acc),
    do: %{acc | last_said: nil} |> bump(:turns) |> add(at, :said, text)

  # -- where it works ------------------------------------------------------------------

  # Counts an edit or a command in the repository holding `dir`.
  defp worked_in(acc, nil, _repo_of), do: acc

  defp worked_in(acc, dir, repo_of) do
    {root, acc} =
      case Map.fetch(acc.roots, dir) do
        {:ok, root} ->
          {root, acc}

        :error ->
          root = repo_of.(dir)
          {root, %{acc | roots: Map.put(acc.roots, dir, root)}}
      end

    case root do
      nil ->
        acc

      root ->
        %{acc | repos: Map.update(acc.repos, Path.basename(root), 1, &(&1 + 1))}
    end
  end

  defp dir_of(nil), do: nil

  defp dir_of(path) when is_binary(path),
    do: if(Path.type(path) == :absolute, do: Path.dirname(path))

  defp dir_of(_), do: nil

  @doc false
  def bash_dir(cmd) do
    case Regex.run(~r/(?:^|&&|;)\s*cd\s+("[^"]+"|'[^']+'|\S+)/, cmd) ||
           Regex.run(~r/\bgit\s+-C\s+("[^"]+"|'[^']+'|\S+)/, cmd) do
      [_, dir] ->
        dir = dir |> String.trim("\"") |> String.trim("'")
        if Path.type(dir) == :absolute, do: dir

      _ ->
        nil
    end
  end

  @doc false
  def git_root(dir) do
    cond do
      dir in ["/", "."] -> nil
      File.exists?(Path.join(dir, ".git")) -> dir
      true -> if Path.dirname(dir) == dir, do: nil, else: git_root(Path.dirname(dir))
    end
  end

  # -- commands ------------------------------------------------------------------------

  @test ~r/\b(mix test|flutter test|swift test|xcodebuild\b.*\btest\b|npm (run )?test|yarn test|pnpm test|bun test|pytest|go test|cargo test|gradlew\S*\s+\S*[tT]est|rspec|jest|vitest)/

  @doc false
  def test?(cmd), do: Regex.match?(@test, cmd)

  @commit ~r/(?:^|&&|;|\|\||\n|\bdo|\bthen)\s*git\s+(?:-C\s+\S+\s+)?commit\b/

  @doc "Whether `cmd` runs `git commit` (not one quoted inside a heredoc's text)."
  def commit?(cmd), do: Regex.match?(@commit, strip_heredocs(cmd))

  @doc "The first line of the message `cmd` commits with, or \"commit\"."
  def commit_message(cmd) do
    rest =
      case Regex.run(@commit, cmd, return: :index) do
        [{i, _}] -> binary_part(cmd, i, byte_size(cmd) - i)
        _ -> cmd
      end

    heredoc = Regex.run(~r/\s-[a-zA-Z]*m\s+"\$\(cat\s+<<-?\s*['"]?\w+['"]?\s*\n\s*(.+)/, rest)
    quoted = Regex.run(~r/\s-[a-zA-Z]*m\s*(?:"((?:[^"\\]|\\.)*)"|'([^']*)')/, rest)

    msg =
      cond do
        heredoc -> Enum.at(heredoc, 1)
        quoted -> quoted |> Enum.drop(1) |> Enum.find(&(&1 not in [nil, ""]))
        true -> nil
      end

    msg |> to_string() |> String.split("\n") |> hd() |> one() |> blank_to("commit")
  end

  defp strip_heredocs(cmd),
    do: Regex.replace(~r/<<-?\s*['"]?(\w+)['"]?[^\n]*\n.*?\n\s*\1\b/s, cmd, "<<…")

  # -- helpers -------------------------------------------------------------------------

  defp bump(acc, key), do: %{acc | counts: Map.update!(acc.counts, key, &(&1 + 1))}

  defp add(acc, at, kind, text),
    do: %{acc | timeline: [%{at: at, kind: kind, text: text} | acc.timeline]}

  defp blank_to("", default), do: default
  defp blank_to(t, _), do: t

  defp one(nil), do: ""

  defp one(t),
    do:
      t |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, @text)
end
