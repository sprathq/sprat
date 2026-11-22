defmodule Sprat.Terminal.Width do
  @moduledoc """
  Terminal display width: East Asian Width, emoji (incl. ZWJ/flags) and
  combining marks, plus wrapping/truncation built on it.

  Grapheme *segmentation* is `String.graphemes/1` (Unicode UAX #29), which
  already clusters ZWJ emoji sequences and combining marks correctly; we only
  classify each cluster's display width (0/1/2) via a curated wcwidth-style
  range table (ponytail: curated ranges, not the full East Asian Width /
  emoji-data.txt tables — sufficient for terminal rendering; extend the
  ranges below if a real character is found misclassified).
  """

  # {first, last, width} — checked in order, first match wins, else width 1.
  @ranges [
    {0x0300, 0x036F, 0},
    {0x0483, 0x0489, 0},
    {0x0591, 0x05BD, 0},
    {0x200B, 0x200F, 0},
    {0x2028, 0x202E, 0},
    {0xFE00, 0xFE0F, 0},
    {0xFE20, 0xFE2F, 0},
    {0x1AB0, 0x1AFF, 0},
    {0x20D0, 0x20FF, 0},
    {0x1100, 0x115F, 2},
    {0x2329, 0x232A, 2},
    {0x2E80, 0x303E, 2},
    {0x3041, 0x33FF, 2},
    {0x3400, 0x4DBF, 2},
    {0x4E00, 0x9FFF, 2},
    {0xA000, 0xA4CF, 2},
    {0xAC00, 0xD7A3, 2},
    {0xF900, 0xFAFF, 2},
    {0xFE30, 0xFE4F, 2},
    {0xFF00, 0xFF60, 2},
    {0xFFE0, 0xFFE6, 2},
    {0x20000, 0x3FFFD, 2},
    {0x1F1E6, 0x1F1FF, 2},
    {0x1F300, 0x1FAFF, 2},
    {0x1F000, 0x1F0FF, 2}
    # ponytail note (not a range, a correction): U+2600-27BF (Misc
    # Symbols/Dingbats) used to be classed wide here, on the assumption
    # every codepoint in the block needs 2 columns. Real terminals
    # (tmux/xterm/iTerm/Alacritty) render the ones this codebase actually
    # uses from that block — ✓ U+2713 (Theme's "done" glyph), ✉ U+2709
    # (MessageFlow's assignment glyph), ⚖ U+2696 (decision), ✕ U+2715
    # (cancel) — as a single column (no VS16 emoji-presentation selector
    # follows them), and Screen budgeted a phantom second column + a
    # `:cont` cell for each one. That extra `:cont` gets silently
    # skipped by `render_cells/3` (correct for genuinely wide glyphs,
    # since the terminal auto-advances two columns for those on its
    # own), so this dropped one real character of every row containing
    # one of these glyphs and left every later write on that row a
    # column further right than the real cursor — the flow overlay
    # artifact (a stray leftover character after closing it) traced
    # back to exactly this. Found via a real tmux capture, a
    # `Screen.diff` cell-by-cell instrumentation, and finally checking
    # this table against `IO.inspect(hex: ...)` — not a hunch.
  ]

  @doc "Display width of a string, ignoring ANSI SGR escapes."
  def width(string) when is_binary(string) do
    string
    |> strip_ansi()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  @doc "Display width of one extended grapheme cluster."
  def grapheme_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      Enum.count(codepoints) > 1 and 0x200D in codepoints -> 2
      true -> codepoints |> Enum.map(&cp_width/1) |> Enum.max(fn -> 1 end)
    end
  end

  @doc """
  Word-wrap `text` (a single logical line, may contain ANSI SGR codes) to
  `width` display columns. Never returns a line whose display width exceeds
  `width`; splits words wider than `width` themselves as a last resort.
  """
  def wrap(text, width) when is_binary(text) and width > 0 do
    text
    |> String.split(~r/(?<=\s)/)
    |> Enum.reduce([""], fn word, [line | rest] ->
      candidate = line <> word

      cond do
        width(candidate) <= width ->
          [candidate | rest]

        # The word itself (not just "doesn't fit the rest of this line")
        # is wider than the whole width — nothing but a hard grapheme
        # split can ever place it, on any line.
        width(word) > width ->
          wrap_overflow(word, width) ++ drop_if_empty(line, rest)

        # The word fits on a line by itself; it just doesn't fit in what's
        # left of the current one, so it starts a fresh line — as `word`
        # itself, trailing separator space and all, not
        # `String.trim_trailing/1`'d first. Trimming here (the bug a real
        # tmux capture caught: a long streamed answer rendered as
        # "...application and\nitsdependencies into a release...", one
        # `s` and one space short of "its dependencies") threw away the
        # space that was this word's *own* separator from the word after
        # it, since only the final `Enum.map(&String.trim_trailing/1)`
        # pass below is supposed to trim line-final whitespace — trimming
        # early here trimmed a line-*internal* boundary by mistake.
        true ->
          [word | drop_if_empty(line, rest)]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> then(fn lines -> if lines == [], do: [""], else: lines end)
  end

  def wrap(_text, _width), do: [""]

  defp drop_if_empty("", rest), do: rest
  defp drop_if_empty(line, rest), do: [line | rest]

  # A single word/token wider than `width` on its own: hard-split by grapheme.
  defp wrap_overflow(word, width) do
    word
    |> String.graphemes()
    |> Enum.chunk_while(
      {[], 0},
      fn g, {chunk, w} ->
        gw = grapheme_width(g)

        if w + gw > width and chunk != [] do
          {:cont, chunk |> Enum.reverse() |> Enum.join(), {[g], gw}}
        else
          {:cont, {[g | chunk], w + gw}}
        end
      end,
      fn
        {[], _w} -> {:cont, []}
        {chunk, _w} -> {:cont, chunk |> Enum.reverse() |> Enum.join(), []}
      end
    )
    |> Enum.reverse()
  end

  @doc """
  Truncate `text` to `width` display columns, appending `suffix` (default
  "…") if truncated. ANSI SGR codes (`\\e[...m`) are stripped first, same
  as `width/1` — a truncated line is column-laid-out cell-by-cell
  downstream (`Screen.text_cells/3`), which has no concept of an escape
  code as a zero-width style change; leaving one in would burn real
  column budget on invisible bytes and truncate real content short.
  """
  def truncate(text, width, suffix \\ "…") when is_binary(text) and width > 0 do
    if width(text) <= width do
      text
    else
      budget = max(width - width(suffix), 0)

      body =
        text
        |> strip_ansi()
        |> String.graphemes()
        |> Enum.reduce_while({[], 0}, fn g, {acc, w} ->
          gw = grapheme_width(g)
          if w + gw > budget, do: {:halt, {acc, w}}, else: {:cont, {[g | acc], w + gw}}
        end)
        |> elem(0)
        |> Enum.reverse()
        |> Enum.join()

      body <> suffix
    end
  end

  @doc "Strips ANSI SGR escape sequences (`\\e[...m`) from `text` — used everywhere display width or column layout must ignore them."
  def strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  defp cp_width(cp), do: Enum.find_value(@ranges, 1, fn {lo, hi, w} -> cp in lo..hi and w end)
end
