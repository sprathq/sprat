defmodule Sprat.Spike.Markdown do
  @moduledoc """
  Point 4: Markdown -> ANSI lines via Earmark's AST, so the token stream can
  be rendered as it commits paragraph by paragraph.

  ponytail: covers the block/inline set the demo actually emits (heading,
  paragraph, list, code block, bold/italic/code-span) — not a full CommonMark
  renderer. Good enough to prove Earmark -> ANSI is viable; a real renderer
  is a normal-sized follow-up, not a spike risk.
  """

  alias IO.ANSI

  @doc "Render a Markdown string to a list of already-wrapped ANSI lines."
  def to_ansi_lines(markdown, width) do
    {:ok, ast, _} = Earmark.as_ast(markdown)

    ast
    |> Enum.flat_map(&block_to_lines(&1, width))
  end

  defp block_to_lines({"h" <> level, _, inline, _}, width) do
    n = String.to_integer(level)
    prefix = String.duplicate("#", n) <> " "
    text = ANSI.bright() <> ANSI.cyan() <> prefix <> inline_text(inline) <> ANSI.reset()
    wrap(text, width) ++ [""]
  end

  defp block_to_lines({"p", _, inline, _}, width) do
    wrap(inline_text(inline), width) ++ [""]
  end

  defp block_to_lines({"ul", _, items, _}, width) do
    Enum.flat_map(items, fn {"li", _, inline, _} ->
      wrap("  " <> ANSI.yellow() <> "-" <> ANSI.reset() <> " " <> inline_text(inline), width)
    end) ++ [""]
  end

  defp block_to_lines({"pre", _, [{"code", _, [code], _}], _}, _width) do
    code
    |> String.split("\n")
    |> Enum.map(&(ANSI.faint() <> "  " <> &1 <> ANSI.reset()))
    |> Kernel.++([""])
  end

  defp block_to_lines(_other, _width), do: []

  defp inline_text(inline) when is_list(inline), do: Enum.map_join(inline, "", &inline_text/1)
  defp inline_text(text) when is_binary(text), do: text

  defp inline_text({"strong", _, inline, _}),
    do: ANSI.bright() <> inline_text(inline) <> ANSI.normal()

  defp inline_text({"em", _, inline, _}),
    do: ANSI.italic() <> inline_text(inline) <> ANSI.not_italic()

  defp inline_text({"code", _, inline, _}), do: ANSI.faint() <> inline_text(inline) <> ANSI.reset()
  defp inline_text({_tag, _, inline, _}), do: inline_text(inline)

  # naive word-wrap respecting display width (point 6), ANSI-code aware
  # enough for the styles we emit above (they don't change width).
  defp wrap(text, width) do
    text
    |> String.split(~r/(?<=\s)/)
    |> Enum.reduce([""], fn word, [line | rest] ->
      candidate = line <> word
      visible = Sprat.Spike.Wcwidth.width(strip_ansi(candidate))

      if visible > width and line != "" do
        [String.trim_trailing(word), line | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&String.trim_trailing/1)
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")
end
