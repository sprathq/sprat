defmodule Sprat.Spike.Wcwidth do
  @moduledoc """
  Terminal display width for point 6 (CJK, emoji incl. ZWJ/flags, combining
  marks).

  ponytail: grapheme *segmentation* is not reimplemented — `String.graphemes/1`
  already applies Unicode UAX #29 extended grapheme clustering, which is
  exactly what correctly groups a ZWJ emoji sequence (👨‍👩‍👧‍👦) or a flag
  (🇬🇧, two regional-indicator codepoints) into one cluster, and a base
  character plus combining marks into one cluster. We only classify each
  cluster's *display width* (0 / 1 / 2), using the well-known wide-character
  ranges (the East Asian Wide/Fullwidth ranges from Markus Kuhn's wcwidth.c)
  plus the common emoji blocks that terminals render at cell-width 2.

  This is a curated subset of Unicode, not the full East Asian Width /
  emoji-data.txt tables — good enough to prove the *approach* (grapheme
  cluster -> width) in the spike; V1 should vendor the real tables.
  """

  # {first, last, width} — checked in order, first match wins, else width 1.
  @ranges [
    # Combining marks / zero-width formatting (width 0)
    {0x0300, 0x036F, 0},
    {0x0483, 0x0489, 0},
    {0x0591, 0x05BD, 0},
    {0x200B, 0x200F, 0},
    {0x2028, 0x202E, 0},
    {0xFE00, 0xFE0F, 0},
    {0xFE20, 0xFE2F, 0},
    {0x1AB0, 0x1AFF, 0},
    {0x20D0, 0x20FF, 0},

    # East Asian Wide / Fullwidth (classic wcwidth.c ranges), width 2
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

    # Common emoji blocks, width 2
    {0x1F1E6, 0x1F1FF, 2},
    {0x1F300, 0x1FAFF, 2},
    {0x1F000, 0x1F0FF, 2},
    {0x2600, 0x27BF, 2},
    {0x2B00, 0x2BFF, 2}
  ]

  @doc "Display width of a full string: sum of grapheme cluster widths."
  def width(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  @doc "Display width of one extended grapheme cluster."
  def grapheme_width(grapheme) do
    codepoints = String.to_charlist(grapheme)

    cond do
      # ZWJ-joined multi-codepoint emoji sequence (e.g. family, kiss) -> 2 cells,
      # not sum-of-parts. A flag (two regional indicators, no ZWJ) already comes
      # out at 2 via the max() below, since each indicator alone is width 2.
      Enum.count(codepoints) > 1 and 0x200D in codepoints ->
        2

      true ->
        codepoints
        |> Enum.map(&cp_width/1)
        |> Enum.max(fn -> 1 end)
    end
  end

  defp cp_width(cp) do
    Enum.find_value(@ranges, 1, fn {lo, hi, w} -> cp in lo..hi and w end)
  end
end
