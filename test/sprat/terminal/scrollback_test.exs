defmodule Sprat.Terminal.ScrollbackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Scrollback

  describe "append/2 and viewport/2" do
    test "viewport is bottom-anchored by default" do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..20, &"line #{&1}"))
      assert Scrollback.viewport(sb, 3) == ["line 18", "line 19", "line 20"]
    end

    test "short buffers pad the viewport at the top with blanks" do
      sb = Scrollback.new() |> Scrollback.append(["a", "b"])
      assert Scrollback.viewport(sb, 4) == ["", "", "a", "b"]
    end

    test "bounded to max_lines, oldest dropped first" do
      sb = Scrollback.new(max_lines: 5) |> Scrollback.append(Enum.map(1..10, &"#{&1}"))
      assert Scrollback.viewport(sb, 5) == ~w(6 7 8 9 10)
    end

    test "appending returns to the bottom even after scrolling up" do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..10, &"#{&1}")) |> Scrollback.top()
      sb = Scrollback.append(sb, ["11"])
      assert Scrollback.viewport(sb, 1) == ["11"]
    end
  end

  describe "movement" do
    test "line_up/line_down move one line, clamped at the ends" do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..5, &"#{&1}"))
      sb = Scrollback.line_up(sb)
      assert sb.offset == 1
      assert Scrollback.viewport(sb, 1) == ["4"]

      # clamp at the top: five lines, offset can never exceed 4
      sb = Enum.reduce(1..20, sb, fn _, sb -> Scrollback.line_up(sb) end)
      assert sb.offset == 4

      sb = Scrollback.line_down(sb)
      assert sb.offset == 3
    end

    test "top/1 and bottom/1 jump to the ends" do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..5, &"#{&1}"))
      assert Scrollback.viewport(Scrollback.top(sb), 1) == ["1"]
      assert Scrollback.viewport(Scrollback.bottom(sb), 1) == ["5"]
    end

    test "page_up/page_down move by roughly a page, half_page by half" do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..100, &"#{&1}"))
      paged = Scrollback.page_up(sb, 10)
      assert paged.offset == 9
      halved = Scrollback.half_page_up(sb, 10)
      assert halved.offset == 5
    end
  end

  describe "search/2" do
    test "finds matches and next_match/prev_match cycle through them" do
      sb =
        Scrollback.new()
        |> Scrollback.append(["alpha", "beta", "gamma with alpha again", "delta"])
        |> Scrollback.search("alpha")

      assert sb.matches == [0, 2]
      assert Scrollback.viewport(sb, 1) == ["alpha"]

      sb = Scrollback.next_match(sb)
      assert Scrollback.viewport(sb, 1) == ["gamma with alpha again"]

      sb = Scrollback.next_match(sb)
      assert Scrollback.viewport(sb, 1) == ["alpha"]

      sb = Scrollback.prev_match(sb)
      assert Scrollback.viewport(sb, 1) == ["gamma with alpha again"]
    end

    test "no matches leaves the viewport untouched" do
      sb = Scrollback.new() |> Scrollback.append(["one", "two"]) |> Scrollback.search("zzz")
      assert sb.matches == []
      assert Scrollback.next_match(sb) == sb
    end
  end

  property "offset stays in bounds and viewport always returns `height` lines under arbitrary movement" do
    check all(
            line_count <- integer(0..200),
            height <- integer(1..40),
            moves <-
              list_of(
                member_of([:up, :down, :page_up, :page_down, :half_up, :half_down, :top, :bottom])
              )
          ) do
      sb = Scrollback.new() |> Scrollback.append(Enum.map(1..line_count//1, &"#{&1}"))

      sb =
        Enum.reduce(moves, sb, fn
          :up, sb -> Scrollback.line_up(sb)
          :down, sb -> Scrollback.line_down(sb)
          :page_up, sb -> Scrollback.page_up(sb, height)
          :page_down, sb -> Scrollback.page_down(sb, height)
          :half_up, sb -> Scrollback.half_page_up(sb, height)
          :half_down, sb -> Scrollback.half_page_down(sb, height)
          :top, sb -> Scrollback.top(sb)
          :bottom, sb -> Scrollback.bottom(sb)
        end)

      max_offset = max(line_count - 1, 0)
      assert sb.offset >= 0
      assert sb.offset <= max_offset
      assert length(Scrollback.viewport(sb, height)) == height
    end
  end
end
