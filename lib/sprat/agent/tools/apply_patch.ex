defmodule Sprat.Agent.Tools.ApplyPatch do
  @moduledoc """
  `apply_patch` tool (docs/spec-v2.md §7/§9): applies a unified diff to one
  file within a build task's worktree, after verifying the file's current
  content hash matches the precondition the caller supplies. A patch whose
  context lines don't match the file exactly is refused — this module
  never fuzzes a mismatched hunk into "close enough".

  `context` — same contract as `Sprat.Agent.Tools.WriteFile`:
  `:worktree_root` (required), `:granted` (`%{workspace_write: boolean}`),
  optional `:store`/`:session_id`/`:mission_id`/`:task_id`/`:secrets`.

  Args: `"path"`, `"diff"` (a unified diff, `@@ -l,s +l,s @@` hunks,
  ` `/`-`/`+`-prefixed lines), `"expected_hash"` (lowercase hex sha256 of
  the file's current content — from a prior `read_file`/`write_file`
  result, or computed by the caller).
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Agent.Tools.Files
  alias Sprat.Store.Events

  @impl true
  def name, do: "apply_patch"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "apply_patch",
        "description" =>
          "Apply a unified diff to a file, confined to the task's worktree, after " <>
            "verifying the file's current content hash.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{"type" => "string"},
            "diff" => %{"type" => "string"},
            "expected_hash" => %{"type" => "string"}
          },
          "required" => ["path", "diff", "expected_hash"]
        }
      }
    }
  end

  @impl true
  def call(%{"path" => path, "diff" => diff, "expected_hash" => expected_hash}, context) do
    with :ok <- check_grant(context),
         {:ok, real} <- Files.safe_path(worktree_root(context), path),
         {:ok, before} <- read_existing(real),
         :ok <- check_precondition(before, expected_hash),
         {:ok, after_content} <- apply_unified_diff(before, diff) do
      File.write!(real, after_content)
      record_patch(context, path, before, after_content)
      {:ok, %{"path" => path, "bytes_written" => byte_size(after_content)}}
    else
      {:error, %{"kind" => _} = error} ->
        {:error, error}

      {:error, reason} when reason in [:path_escapes_root, :denied_pattern, :invalid_path] ->
        {:error, %{"kind" => "path_denied", "message" => "refused: #{path} (#{reason})"}}

      {:error, reason} ->
        {:error, %{"kind" => "apply_failed", "message" => inspect(reason)}}

      other ->
        other
    end
  end

  def call(_args, _context),
    do: {:error, "expected {\"path\": ..., \"diff\": ..., \"expected_hash\": ...}"}

  defp check_grant(context) do
    if get_in(context, [:granted, :workspace_write]) do
      :ok
    else
      {:needs_approval, %{action: "workspace_write", reason: :grant_not_yet_given}}
    end
  end

  defp worktree_root(context), do: Map.fetch!(context, :worktree_root)

  defp read_existing(real) do
    case File.read(real) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_precondition(content, expected_hash) do
    actual = content_hash(content)

    if actual == String.downcase(expected_hash) do
      :ok
    else
      {:error,
       %{
         "kind" => "precondition_mismatch",
         "message" =>
           "file content hash is #{actual}, expected #{expected_hash} — the file has " <>
             "changed since this patch was generated. Refusing to apply against stale context."
       }}
    end
  end

  @doc "sha256 hex digest of file content — the precondition `apply_patch` checks against."
  def content_hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # -- unified diff (strict: no fuzzy matching) --------------------------

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  @doc """
  Applies a unified diff to `original` text. Every context (` `) and
  removal (`-`) line in the diff must match `original` at that position
  exactly; the first mismatch refuses the whole patch with
  `{:error, %{"kind" => "context_mismatch", ...}}` rather than attempting
  any fuzzy realignment.
  """
  def apply_unified_diff(original, diff) do
    original_lines = split_lines(original)

    diff
    |> split_lines()
    |> drop_trailing_blank()
    |> Enum.reject(&(&1 == "\\ No newline at end of file"))
    |> Enum.reject(&String.starts_with?(&1, ["---", "+++"]))
    |> parse_hunks()
    |> case do
      {:ok, hunks} -> apply_hunks(hunks, original_lines)
      {:error, _} = error -> error
    end
  end

  defp parse_hunks(lines), do: parse_hunks(lines, [])

  defp parse_hunks([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_hunks([line | rest], acc) do
    case Regex.run(@hunk_header, line) do
      [_, old_start | _] ->
        {hunk_lines, rest} = Enum.split_while(rest, &(not Regex.match?(@hunk_header, &1)))
        hunk = %{old_start: String.to_integer(old_start), lines: hunk_lines}
        parse_hunks(rest, [hunk | acc])

      nil ->
        {:error, {:unparseable_diff_line, line}}
    end
  end

  defp apply_hunks(hunks, original_lines) do
    original = List.to_tuple(original_lines)
    total = tuple_size(original)

    Enum.reduce_while(hunks, {0, []}, fn hunk, {old_pos, output} ->
      before_hunk = hunk.old_start - 1

      if before_hunk < old_pos do
        {:halt, {:error, {:overlapping_or_out_of_order_hunk, hunk.old_start}}}
      else
        carried = slice(original, old_pos, before_hunk)

        case apply_hunk_lines(hunk.lines, original, before_hunk, total, output ++ carried) do
          {:ok, new_pos, new_output} -> {:cont, {new_pos, new_output}}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
    |> case do
      {:error, reason} ->
        {:error, context_mismatch_error(reason)}

      {old_pos, output} ->
        {:ok, (output ++ slice(original, old_pos, total)) |> Enum.join("\n")}
    end
  end

  defp apply_hunk_lines([], _original, old_pos, _total, output), do: {:ok, old_pos, output}

  defp apply_hunk_lines([line | rest], original, old_pos, total, output) do
    case classify(line) do
      {:context, text} -> match_and_advance(rest, original, old_pos, total, output, text, true)
      {:remove, text} -> match_and_advance(rest, original, old_pos, total, output, text, false)
      {:add, text} -> apply_hunk_lines(rest, original, old_pos, total, output ++ [text])
    end
  end

  defp match_and_advance(rest, original, old_pos, total, output, expected, keep?) do
    if old_pos >= total do
      {:error, {:past_end_of_file, old_pos, expected}}
    else
      actual = elem(original, old_pos)

      if actual == expected do
        next_output = if keep?, do: output ++ [actual], else: output
        apply_hunk_lines(rest, original, old_pos + 1, total, next_output)
      else
        {:error, {:line_mismatch, old_pos + 1, expected, actual}}
      end
    end
  end

  defp classify("+" <> text), do: {:add, text}
  defp classify("-" <> text), do: {:remove, text}
  defp classify(" " <> text), do: {:context, text}
  defp classify(""), do: {:context, ""}
  defp classify(text), do: {:context, text}

  defp context_mismatch_error({:line_mismatch, line_no, expected, actual}) do
    %{
      "kind" => "context_mismatch",
      "message" =>
        "patch context does not match at line #{line_no}: expected #{inspect(expected)}, " <>
          "found #{inspect(actual)}. Refusing to fuzz the match."
    }
  end

  defp context_mismatch_error({:past_end_of_file, old_pos, expected}) do
    %{
      "kind" => "context_mismatch",
      "message" =>
        "patch expects a line at position #{old_pos + 1} (#{inspect(expected)}) past the end " <>
          "of the file."
    }
  end

  defp context_mismatch_error({:overlapping_or_out_of_order_hunk, old_start}) do
    %{
      "kind" => "malformed_patch",
      "message" => "hunk starting at line #{old_start} overlaps or precedes an earlier hunk."
    }
  end

  defp context_mismatch_error(other) do
    %{"kind" => "malformed_patch", "message" => inspect(other)}
  end

  defp slice(_tuple, from, to) when from >= to, do: []
  defp slice(tuple, from, to), do: for(i <- from..(to - 1), do: elem(tuple, i))

  defp split_lines(text), do: String.split(text, "\n")

  # A unified diff's own trailing "\n" produces one extra empty element when
  # split — a text-file-ending artifact, never a real hunk line — so it's
  # dropped before hunks are parsed, the same way `\ No newline at end of
  # file` markers and the `---`/`+++` file headers are.
  defp drop_trailing_blank(lines) do
    case List.last(lines) do
      "" -> List.delete_at(lines, -1)
      _ -> lines
    end
  end

  defp record_patch(context, path, before, after_content) do
    with session_id when is_binary(session_id) <- Map.get(context, :session_id) do
      Events.append(
        Map.get(context, :store, Sprat.Store),
        session_id,
        "tool.apply_patch",
        %{
          mission_id: Map.get(context, :mission_id),
          task_id: Map.get(context, :task_id),
          payload: %{
            "path" => path,
            "bytes_before" => byte_size(before),
            "bytes_after" => byte_size(after_content)
          }
        },
        Map.get(context, :secrets, [])
      )
    end

    :ok
  end
end
