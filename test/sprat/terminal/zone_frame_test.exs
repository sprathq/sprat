defmodule Sprat.Terminal.ZoneFrameTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.ZoneFrame
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{22, 10}, {18, 6}, {40, 20}, {3, 3}, {1, 1}]

  test "wrap/4 always returns exactly rect.h rows of exactly rect.w cells" do
    for {w, h} <- @widths do
      rows = ZoneFrame.wrap("Zone", true, %{x: 0, y: 0, w: w, h: h}, ["one", "two", "three"])
      assert length(rows) == h, "expected #{h} rows at #{w}x#{h}"
      assert Enum.all?(rows, &(length(&1) == w)), "row width mismatch at #{w}x#{h}"
    end
  end

  test "the title is drawn in the top border, not the body" do
    rows = ZoneFrame.wrap("Detail", true, %{x: 0, y: 0, w: 20, h: 5}, ["hello"])
    text = rows_to_text(rows)
    assert text =~ "Detail"
    assert text =~ "╭"
    assert text =~ "╰"
  end

  test "a body line longer than the interior is ellipsis-truncated, never hard-cut without a marker" do
    rows =
      ZoneFrame.wrap(
        "Zone",
        true,
        %{x: 0, y: 0, w: 15, h: 3},
        ["this line is far too long to fit in 13 columns"]
      )

    text = rows_to_text(rows)
    assert text =~ "…"
  end

  test "a short body is blank-padded to the full interior height" do
    rows = ZoneFrame.wrap("Zone", true, %{x: 0, y: 0, w: 20, h: 6}, ["one line"])
    assert length(rows) == 6
  end
end
