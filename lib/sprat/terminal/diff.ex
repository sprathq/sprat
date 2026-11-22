defmodule Sprat.Terminal.Diff do
  @moduledoc """
  Pure git-diff text -> display lines (docs/spec-v2.md §11 Diff tab). No
  IO, no store access, no shelling — `Sprat.Workspace.diff/2` is the only
  thing that runs `git diff`; this module only knows how to lay the text
  it already returned out on screen, the same split `Sprat.Export.Markdown`
  has for artifact JSON.

  `+`/`-` lines are shown exactly as `git diff` writes them, unindented —
  the leading `+`/`-` character *is* the glyph spec-v2.md §11 asks for
  ("distinguished by a leading glyph as well as colour"), so there is
  nothing to add on top of it; every other line (file/hunk headers,
  unchanged context) gets a two-space indent so the changed lines still
  stand out visually even with colour off.
  """

  @doc "`{added, removed}` line counts for a unified diff's body, ignoring the `+++`/`---` file-header lines."
  def counts(text) when text in [nil, ""], do: {0, 0}

  def counts(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({0, 0}, fn
      "+++" <> _, acc -> acc
      "---" <> _, acc -> acc
      "+" <> _, {a, r} -> {a + 1, r}
      "-" <> _, {a, r} -> {a, r + 1}
      _line, acc -> acc
    end)
  end

  @doc """
  Diff text as display lines, capped at `max_lines`. A diff longer than
  that is truncated with a "+N more lines" note naming exactly how much
  is hidden and pointing at `/export`, the same convention the artifact
  card uses (`Terminal.Zones.Detail.truncate_body/1`) — never a silent cut.
  """
  def render(text, max_lines \\ 200)
  def render(text, _max_lines) when text in [nil, ""], do: []

  def render(text, max_lines) do
    lines = text |> String.split("\n") |> Enum.map(&marked_line/1)

    if length(lines) <= max_lines do
      lines
    else
      hidden = length(lines) - max_lines
      Enum.take(lines, max_lines) ++ ["… #{hidden} more line(s) — /export writes the full diff"]
    end
  end

  defp marked_line("diff --git" <> _ = line), do: line
  defp marked_line("@@" <> _ = line), do: line
  defp marked_line("+++" <> _ = line), do: line
  defp marked_line("---" <> _ = line), do: line
  defp marked_line("+" <> _ = line), do: line
  defp marked_line("-" <> _ = line), do: line
  defp marked_line(line), do: "  " <> line
end
