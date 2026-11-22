defmodule Sprat.Terminal.WidthTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Width

  describe "width/1" do
    test "ascii text is one cell per character" do
      assert Width.width("hello") == 5
    end

    test "CJK characters are two cells wide" do
      assert Width.width("中文") == 4
    end

    test "emoji is two cells wide" do
      assert Width.width("😀") == 2
    end

    test "ZWJ emoji sequence is one cluster, two cells" do
      assert Width.width("👨‍👩‍👧‍👦") == 2
    end

    test "flag (regional indicator pair) is two cells" do
      assert Width.width("🇬🇧") == 2
    end

    test "combining marks contribute zero width" do
      assert Width.width("é") == 1
    end

    test "ignores ANSI SGR codes when measuring" do
      assert Width.width("\e[31mred\e[0m") == 3
    end

    test "mixed string" do
      assert Width.width("中文 😀 hi") == 4 + 1 + 2 + 1 + 2
    end
  end

  describe "wrap/2" do
    test "does not split short text" do
      assert Width.wrap("hello world", 20) == ["hello world"]
    end

    test "wraps at width boundary on whitespace" do
      lines = Width.wrap("the quick brown fox jumps", 10)
      assert Enum.all?(lines, &(Width.width(&1) <= 10))
    end

    # A real tmux capture of a streamed agent answer showed
    # "...application and\nitsdependencies into a release..." — a wrapped
    # word glued to the next one, one space short, because the word that
    # started the new line had its own trailing separator space trimmed
    # away before the next word could be appended to it. Rejoining wrapped
    # lines with a single space must reproduce the exact original word
    # sequence, not merge any two of them.
    test "wrapping and rejoining with a space never glues two words together" do
      text =
        "Deploying an Elixir application to production typically involves packaging your " <>
          "application and its dependencies into a release, then running that release on the " <>
          "target machine without needing Elixir or Erlang installed there separately."

      lines = Width.wrap(text, 40)
      assert Enum.all?(lines, &(Width.width(&1) <= 40))

      rejoined = lines |> Enum.map_join(" ", &String.trim/1) |> String.replace(~r/\s+/, " ")
      assert rejoined == String.replace(text, ~r/\s+/, " ")
    end

    test "hard-splits a single word wider than the width" do
      lines = Width.wrap(String.duplicate("a", 25), 10)
      assert Enum.all?(lines, &(Width.width(&1) <= 10))
      assert Enum.join(lines) == String.duplicate("a", 25)
    end

    test "never emits an empty result for non-empty input" do
      assert Width.wrap("x", 5) == ["x"]
    end

    test "a single grapheme wider than the target width cannot be split further" do
      # A wide (2-cell) character asked to wrap at width 1 has no valid
      # split point — it is emitted as its own (over-width) line rather
      # than silently dropped or corrupted. Real terminals are always far
      # wider than 2 columns, so this only matters at pathological widths.
      assert Width.wrap("中", 1) == ["中"]
    end

    test "handles wide characters without exceeding width" do
      lines = Width.wrap(String.duplicate("中", 10), 5)
      assert Enum.all?(lines, &(Width.width(&1) <= 5))
    end

    property "no wrapped line ever exceeds the target width" do
      # width starts at 2: a single wide (2-cell) grapheme cannot be split
      # to fit width 1 — see the dedicated unit test above for that case.
      check all(
              text <- StreamData.string(:printable, min_length: 1, max_length: 200),
              width <- StreamData.integer(2..60)
            ) do
        lines = Width.wrap(text, width)
        assert Enum.all?(lines, &(Width.width(&1) <= width))
      end
    end
  end

  describe "truncate/3" do
    test "returns text unchanged when it fits" do
      assert Width.truncate("hi", 10) == "hi"
    end

    test "truncates and appends the default ellipsis" do
      result = Width.truncate("hello world", 6)
      assert Width.width(result) <= 6
      assert String.ends_with?(result, "…")
    end

    test "accepts a custom suffix" do
      result = Width.truncate("hello world", 6, "...")
      assert String.ends_with?(result, "...")
      assert Width.width(result) <= 6
    end
  end

  describe "grapheme_width/1" do
    # U+2600-27BF (Misc Symbols/Dingbats) used to be classed wide
    # wholesale here — real terminals render these specific glyphs (no
    # VS16 emoji-presentation selector follows them) as a single column,
    # and the mismatch dropped a character and misaligned every later
    # write on the same row (traced from a real tmux artifact left after
    # closing the flow overlay, all the way back to this table).
    test "checkmark, envelope, scales and X (Theme/MessageFlow glyphs) are narrow, not wide" do
      for glyph <- ["✓", "✉", "⚖", "✕"] do
        assert Width.grapheme_width(glyph) == 1, "expected #{inspect(glyph)} to be width 1"
      end
    end

    test "a row containing one of these glyphs plus text pads to exactly the requested width, with no phantom :cont cell" do
      cells = Sprat.Terminal.Screen.text_cells("✓ Intake", 28)
      assert length(cells) == 28
      refute Enum.any?(cells, &(&1 == :cont))
    end
  end
end
