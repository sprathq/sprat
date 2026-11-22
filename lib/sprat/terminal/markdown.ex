defmodule Sprat.Terminal.Markdown do
  @moduledoc """
  Earmark AST -> styled terminal lines at a given width: headings,
  bold/italic, inline code, fenced code blocks, lists, links, and tables
  with column wrapping.

  Honors `NO_COLOR` (disables ANSI styling) and ASCII-glyph fallback
  (`SPRAT_ASCII=1` or a non-UTF-8 locale) in place of Unicode bullets.
  """

  alias IO.ANSI
  alias Sprat.Terminal.{Glyphs, Width}

  @doc "Render a Markdown string to a list of already-wrapped ANSI lines."
  def to_lines(markdown, width, opts \\ []) do
    color? = color_enabled?(opts)
    ascii? = ascii_fallback?(opts)
    {:ok, ast, _} = Earmark.as_ast(markdown)
    Enum.flat_map(ast, &block_to_lines(&1, width, color?, ascii?))
  end

  defp block_to_lines({"h" <> level, _, inline, _}, width, color?, _ascii?) do
    n = level |> String.to_integer() |> min(6)
    prefix = String.duplicate("#", n) <> " "
    text = style(color?, [ANSI.bright(), ANSI.cyan()], prefix <> inline_text(inline, color?))
    Width.wrap(text, width) ++ [""]
  end

  defp block_to_lines({"p", _, inline, _}, width, color?, _ascii?) do
    Width.wrap(inline_text(inline, color?), width) ++ [""]
  end

  defp block_to_lines({"ul", _, items, _}, width, color?, ascii?) do
    list_lines(items, width, color?, ascii?, "  #{Glyphs.bullet(ascii?)} ")
  end

  defp block_to_lines({"ol", _, items, _}, width, color?, _ascii?) do
    items
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{"li", _, inline, _}, i} ->
      Width.wrap("  #{i}. " <> inline_text(inline, color?), width)
    end)
    |> Kernel.++([""])
  end

  defp block_to_lines({"blockquote", _, blocks, _}, width, color?, ascii?) do
    Enum.flat_map(blocks, &block_to_lines(&1, width - 2, color?, ascii?))
    |> Enum.map(&("  " <> &1))
  end

  defp block_to_lines({"pre", _, [{"code", _, [code], _}], _}, _width, color?, _ascii?) do
    code
    |> String.split("\n")
    |> Enum.map(&style(color?, [ANSI.faint()], "  " <> &1))
    |> Kernel.++([""])
  end

  defp block_to_lines({"table", _, rows, _}, width, color?, ascii?) do
    table_lines(rows, width, color?, ascii?) ++ [""]
  end

  defp block_to_lines({"hr", _, _, _}, width, _color?, ascii?) do
    ch = if ascii?, do: "-", else: "─"
    [String.duplicate(ch, width), ""]
  end

  defp block_to_lines(_other, _width, _color?, _ascii?), do: []

  # A list item's children are either flat inline content (`- REST`, no
  # nesting — Earmark hands back a plain list of text/inline-tag nodes) or,
  # once the item has a nested list under it (`- REST\n  - Collaboration:
  # ...`), a `p` holding the item's own text followed by a nested `ul`/`ol`
  # block. The old version of this function called `inline_text/2` on
  # `inline` unconditionally, and `inline_text/2`'s catch-all clause (for
  # tags it doesn't special-case, which includes `p` *and* `ul`/`ol`)
  # recurses into a tag's children and joins them with no separator — so a
  # nested list's items got flattened straight into the parent item's own
  # line with no space or newline between them at all
  # ("RESTCollaboration: ...Velocity: ..."), read as literal corruption in
  # a real tmux capture of a streamed Markdown answer. Splitting the
  # leading (inline) content from the trailing (block) content here, and
  # rendering the trailing part back through `block_to_lines/4` at a
  # deeper indent (same pattern `blockquote` already uses), is what a
  # nested list actually needs: its own lines, not concatenation.
  defp list_lines(items, width, color?, ascii?, prefix) do
    Enum.flat_map(items, fn {"li", _, children, _} ->
      li_lines(children, width, color?, ascii?, prefix)
    end) ++ [""]
  end

  defp li_lines(children, width, color?, ascii?, prefix) do
    {leading, nested} = Enum.split_while(children, &(not nested_block?(&1)))
    own_lines = Width.wrap(prefix <> inline_text(leading, color?), width)

    nested_lines =
      nested
      |> Enum.flat_map(&block_to_lines(&1, width - 2, color?, ascii?))
      |> Enum.map(&("  " <> &1))

    own_lines ++ nested_lines
  end

  defp nested_block?({"ul", _, _, _}), do: true
  defp nested_block?({"ol", _, _, _}), do: true
  defp nested_block?(_), do: false

  defp table_lines(
         [{"thead", _, [{"tr", _, header_cells, _}], _}, {"tbody", _, body_rows, _}],
         width,
         color?,
         ascii?
       ) do
    header = Enum.map(header_cells, fn {_, _, inline, _} -> inline_text(inline, color?) end)

    body =
      Enum.map(body_rows, fn {"tr", _, cells, _} ->
        Enum.map(cells, fn {_, _, inline, _} -> inline_text(inline, color?) end)
      end)

    col_count = length(header)
    col_width = max(div(width - (col_count + 1), max(col_count, 1)), 3)
    sep = if ascii?, do: "-", else: "─"

    ellipsis = if ascii?, do: "...", else: "…"

    render_row = fn cells ->
      cells
      |> Enum.map(&Width.truncate(&1, col_width, ellipsis))
      |> Enum.map(&pad(&1, col_width))
      |> Enum.join(" | ")
    end

    [
      style(color?, [ANSI.bright()], render_row.(header)),
      String.duplicate(sep, min(width, col_count * (col_width + 3)))
      | Enum.map(body, render_row)
    ]
  end

  defp table_lines(_rows, _width, _color?, _ascii?), do: []

  defp pad(text, width) do
    pad = max(width - Width.width(text), 0)
    text <> String.duplicate(" ", pad)
  end

  defp inline_text(inline, color?) when is_list(inline),
    do: Enum.map_join(inline, "", &inline_text(&1, color?))

  defp inline_text(text, _color?) when is_binary(text), do: text

  defp inline_text({"strong", _, inline, _}, color?),
    do: style(color?, [ANSI.bright()], inline_text(inline, color?))

  defp inline_text({"em", _, inline, _}, color?),
    do: style(color?, [ANSI.italic()], inline_text(inline, color?))

  defp inline_text({"code", _, inline, _}, color?),
    do: style(color?, [ANSI.faint()], inline_text(inline, color?))

  defp inline_text({"a", attrs, inline, _}, color?) do
    href = Enum.find_value(attrs, "", fn {k, v} -> k == "href" && v end)
    text = inline_text(inline, color?)
    if href == "" or href == text, do: text, else: "#{text} (#{href})"
  end

  defp inline_text({_tag, _, inline, _}, color?), do: inline_text(inline, color?)

  defp style(true, codes, text), do: IO.iodata_to_binary(codes) <> text <> ANSI.reset()
  defp style(false, _codes, text), do: text

  defp color_enabled?(opts), do: Glyphs.color?(opts)
  defp ascii_fallback?(opts), do: Glyphs.ascii?(opts)
end
