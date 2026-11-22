defmodule Sprat.Terminal.LayoutTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Layout

  describe "compute/3 breakpoints (docs/design/tui-zones.md 'Responsive layout')" do
    test "wide: >= 120 cols places all six zones as three columns" do
      layout = Layout.compute(140, 40)
      assert layout.breakpoint == :wide

      assert Map.keys(layout.zones) |> Enum.sort() == [
               :agents,
               :composer,
               :conversation,
               :detail,
               :inspector,
               :mission
             ]
    end

    test "medium: 100..119 cols places mission/agents/conversation, overlays inspector/detail" do
      layout = Layout.compute(110, 40)
      assert layout.breakpoint == :medium
      assert Map.has_key?(layout.zones, :conversation)
      assert :inspector in layout.overlays
      assert :detail in layout.overlays
    end

    test "narrow: 80..99 cols is single-column conversation with a mission/agents header strip" do
      layout = Layout.compute(90, 40)
      assert layout.breakpoint == :narrow
      assert Map.has_key?(layout.zones, :conversation)
      assert :inspector in layout.overlays
      assert :agents in layout.overlays
    end

    test "single: < 80 cols shows exactly the focused zone, full screen" do
      layout = Layout.compute(70, 40, %{focused: :inspector})
      assert layout.breakpoint == :single
      assert Map.keys(layout.zones) == [:inspector]
      assert layout.zones.inspector.w == 70
    end

    test "single: < 24 rows also collapses to one zone regardless of width" do
      layout = Layout.compute(200, 20, %{focused: :conversation})
      assert layout.breakpoint == :single
      assert Map.keys(layout.zones) == [:conversation]
    end

    test "no zone is ever placed below its own min_size" do
      # Exception: the narrow breakpoint's Mission zone is a deliberately
      # compact "header strip" summary (the design's own words), not
      # Mission at native size — see Layout.compute/3's comment.
      for {cols, rows} <- [{80, 24}, {90, 30}, {100, 24}, {120, 24}, {200, 60}, {40, 15}] do
        layout = Layout.compute(cols, rows)

        for {id, rect} <- layout.zones, not (layout.breakpoint == :narrow and id == :mission) do
          {min_w, min_h} = Layout.min_size(id)
          assert rect.w >= min_w, "#{id} at #{cols}x#{rows}: w=#{rect.w} < min #{min_w}"
          assert rect.h >= min_h, "#{id} at #{cols}x#{rows}: h=#{rect.h} < min #{min_h}"
        end
      end
    end

    test "narrow breakpoint always shows the Mission header strip when there's any room for it" do
      layout = Layout.compute(90, 30)
      assert Map.has_key?(layout.zones, :mission)
      assert layout.zones.mission.h < elem(Layout.min_size(:mission), 1)
    end

    test "placed zone rects never exceed the terminal bounds" do
      for {cols, rows} <- [{80, 24}, {100, 30}, {120, 24}, {200, 60}] do
        layout = Layout.compute(cols, rows)

        for {_id, rect} <- Map.put(layout.zones, :footer, layout.footer) do
          assert rect.x + rect.w <= cols
          assert rect.y + rect.h <= rows
        end
      end
    end
  end
end
