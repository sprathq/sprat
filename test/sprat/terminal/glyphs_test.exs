defmodule Sprat.Terminal.GlyphsTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Glyphs

  test "color? defaults to true and honors an explicit override" do
    assert Glyphs.color?([]) == true
    assert Glyphs.color?(color: false) == false
  end

  test "ascii? defaults to false and honors an explicit override" do
    assert Glyphs.ascii?([]) == false
    assert Glyphs.ascii?(ascii: true) == true
  end

  test "run_status distinguishes passed/failed/timed out by glyph+word, in both glyph sets" do
    pairs = [
      Glyphs.run_status(0, false),
      Glyphs.run_status(1, false),
      Glyphs.run_status(nil, false)
    ]

    assert Enum.uniq(pairs) == pairs
    assert Glyphs.run_status(0, false) == {"✓", "passed"}
    assert Glyphs.run_status(1, false) == {"!", "failed"}
    assert Glyphs.run_status(137, false) == {"!", "failed"}
    assert Glyphs.run_status(nil, false) == {"⏲", "timed out"}

    ascii_pairs = [
      Glyphs.run_status(0, true),
      Glyphs.run_status(1, true),
      Glyphs.run_status(nil, true)
    ]

    assert Enum.uniq(ascii_pairs) == ascii_pairs
  end

  test "checklist_marker covers all three statuses in both glyph sets" do
    assert Glyphs.checklist_marker(:done, false) == "☒"
    assert Glyphs.checklist_marker(:active, false) == "◼"
    assert Glyphs.checklist_marker(:pending, false) == "☐"
    assert Glyphs.checklist_marker(:done, true) == "[x]"
    assert Glyphs.checklist_marker(:active, true) == "[>]"
    assert Glyphs.checklist_marker(:pending, true) == "[ ]"
  end
end
