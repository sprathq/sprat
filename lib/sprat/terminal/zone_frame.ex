defmodule Sprat.Terminal.ZoneFrame do
  @moduledoc """
  Shared bordered-box rendering for content zones (`docs/design/tui-zones.md`
  zone map mockup: every zone drawn as a titled box, the focused one
  bright, the rest dim — "the focused one holds focus; it shows a bright
  border and title, the rest are dimmed"). Every content zone's `render/4`
  builds its content as plain-string body lines and calls `wrap/4` last,
  instead of each reimplementing box-drawing (`Zones.Composer` is the only
  zone that drew its own border before this — see its `border/2`).

  `wrap/4` always returns exactly `rect.h` rows of exactly `rect.w` cells,
  the same contract every `Terminal.Zone.render/4` must satisfy: it pads
  short bodies and truncates long ones itself, so a zone never has to
  reason about that separately from its own content. A body line wider
  than the interior is ellipsis-truncated with `Terminal.Width.truncate/3`
  (display-width aware, never a byte-count hard cut) rather than silently
  dropping the overflow.
  """

  alias Sprat.Terminal.{Glyphs, Screen, Width}

  @doc "Wraps `body_lines` (plain strings, one intended screen row each) in a titled, bordered box exactly `rect.w`x`rect.h` cells."
  def wrap(title, focused?, rect, body_lines) when rect.w >= 2 and rect.h >= 1 do
    style = box_style(focused?)
    ascii? = Glyphs.ascii?()
    inner_w = rect.w - 2
    inner_h = max(rect.h - 2, 0)

    top = top_row(title, focused?, rect.w, style, ascii?)

    body =
      body_lines
      |> Enum.take(inner_h)
      |> pad_lines(inner_h)
      |> Enum.map(&body_row(&1, inner_w, style, ascii?))

    rows =
      if rect.h >= 2, do: [top | body] ++ [bottom_row(rect.w, style, ascii?)], else: [top]

    rows |> Enum.take(rect.h) |> pad_rows(rect)
  end

  # A rect narrower than 2 columns can't hold a left+right border at all —
  # falls back to plain (unbordered) text, same as any other zone content.
  def wrap(_title, _focused?, rect, body_lines) do
    body_lines
    |> Enum.take(rect.h)
    |> pad_lines(rect.h)
    |> Enum.map(&Screen.text_cells(Width.truncate(&1, rect.w), rect.w, Screen.default_style()))
  end

  defp box_style(true), do: %{fg: :cyan, bg: nil, attrs: [:bright]}
  defp box_style(false), do: %{fg: nil, bg: nil, attrs: [:faint]}

  defp pad_lines(lines, h), do: lines ++ List.duplicate("", max(h - length(lines), 0))

  defp pad_rows(rows, rect) do
    rows ++ List.duplicate(Screen.blank_row(rect.w), max(rect.h - length(rows), 0))
  end

  defp body_row(line, inner_w, style, ascii?) do
    # byte_size is a cheap, always-safe upper bound on display width (every
    # grapheme's UTF-8 encoding takes at least as many bytes as its
    # terminal column width, width capped at 2) — skips `Width.truncate/2`'s
    # full grapheme-width walk + ANSI-strip regex for the common case
    # (most body lines: blank padding, short labels) where it can't
    # possibly need truncating. Found via the repaint-time regression this
    # module introduced — re-measure with `bench_repaint.exs` after
    # touching this path.
    text =
      if byte_size(line) <= inner_w,
        do: line,
        else: Width.truncate(line, inner_w, Glyphs.ellipsis(ascii?))

    {_tl, _tr, _bl, _br, _h, v} = Glyphs.box_glyphs(ascii?)
    [{v, style}] ++ Screen.text_cells(text, inner_w, Screen.default_style()) ++ [{v, style}]
  end

  # Border rows are built as cell lists directly (`List.duplicate/2` for
  # the solid dash runs) rather than through a string + `Screen.text_cells/3`
  # round-trip — every box-drawing/dash character here is known-width-1,
  # so the per-grapheme width lookup that round-trip would do on every one
  # of them (the bulk of a wide zone's top/bottom row) is pure waste.
  # Found while re-measuring `bench_repaint.exs` after adding borders to
  # every zone pushed the 200x60 full-repaint time past budget.
  defp bottom_row(w, style, ascii?) do
    {_tl, _tr, bl, br, h, _v} = Glyphs.box_glyphs(ascii?)
    [{bl, style}] ++ List.duplicate({h, style}, w - 2) ++ [{br, style}]
  end

  defp top_row(title, focused?, w, style, ascii?) do
    {tl, tr, _bl, _br, h, _v} = Glyphs.box_glyphs(ascii?)
    inner = w - 2
    marker = if focused?, do: Glyphs.focus_marker(ascii?) <> " ", else: ""
    label = " #{marker}#{title} "
    label_cells = Screen.text_cells(label, Width.width(label), style)
    label_w = length(label_cells)

    cells =
      if label_w + 2 > inner do
        List.duplicate({h, style}, inner)
      else
        [{h, style}] ++ label_cells ++ List.duplicate({h, style}, inner - label_w - 1)
      end

    [{tl, style}] ++ cells ++ [{tr, style}]
  end
end
