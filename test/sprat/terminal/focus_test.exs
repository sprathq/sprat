defmodule Sprat.Terminal.FocusTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Focus

  describe "chords work in both modes" do
    test "Alt+1..6 jump to a zone by number, in INSERT" do
      focus = Focus.new(mode: :insert)
      {focus, :none} = Focus.handle_key(focus, {:alt, "4"}, %{})
      assert Focus.current(focus) == :inspector
    end

    test "Alt+1..6 jump to a zone by number, in NAV" do
      focus = Focus.new(mode: :nav)
      {focus, :none} = Focus.handle_key(focus, {:alt, "6"}, %{})
      assert Focus.current(focus) == :composer
    end

    test "Alt+n / Alt+p move next/previous regardless of mode" do
      focus = Focus.new(mode: :insert) |> Focus.jump(:mission)
      {focus, :none} = Focus.handle_key(focus, {:alt, "n"}, %{})
      assert Focus.current(focus) == :agents
      {focus, :none} = Focus.handle_key(focus, {:alt, "p"}, %{})
      assert Focus.current(focus) == :mission
    end

    test "Alt+f opens the flow overlay as a global intent, in either mode" do
      for mode <- [:insert, :nav] do
        {_focus, action} = Focus.handle_key(Focus.new(mode: mode), {:alt, "f"}, %{})
        assert action == {:global, :open_flow_overlay}
      end
    end
  end

  describe "INSERT mode" do
    test "Esc leaves to NAV" do
      focus = Focus.new(mode: :insert)
      {focus, {:mode, :nav}} = Focus.handle_key(focus, :esc, %{})
      assert focus.mode == :nav
    end

    test "everything else routes to the composer" do
      focus = Focus.new(mode: :insert)
      assert {_focus, :route_composer} = Focus.handle_key(focus, {:char, "a"}, %{})
    end
  end

  describe "NAV mode" do
    setup do: {:ok, focus: Focus.new(mode: :nav)}

    test "Tab / Shift+Tab move next/previous zone", %{focus: focus} do
      # Focus.new/1 starts on Conversation (index 2, the design's default focus).
      {focus, :none} = Focus.handle_key(focus, :tab, %{})
      assert Focus.current(focus) == :inspector
      {focus, :none} = Focus.handle_key(focus, :shift_tab, %{})
      assert Focus.current(focus) == :conversation
    end

    test "digits 1..6 jump directly", %{focus: focus} do
      {focus, :none} = Focus.handle_key(focus, {:char, "1"}, %{})
      assert Focus.current(focus) == :mission
    end

    test "j/k and arrows route to the zone as scroll intents", %{focus: focus} do
      assert {_f, {:route_zone, :down}} = Focus.handle_key(focus, {:char, "j"}, %{})
      assert {_f, {:route_zone, :up}} = Focus.handle_key(focus, {:char, "k"}, %{})
      assert {_f, {:route_zone, :down}} = Focus.handle_key(focus, :down, %{})
    end

    test "g/G route to top/bottom", %{focus: focus} do
      assert {_f, {:route_zone, :top}} = Focus.handle_key(focus, {:char, "g"}, %{})
      assert {_f, {:route_zone, :bottom}} = Focus.handle_key(focus, {:char, "G"}, %{})
    end

    test "Enter routes to the zone and switches focus back to INSERT", %{focus: focus} do
      {focus, {:route_zone_and_mode, :enter, :insert}} = Focus.handle_key(focus, :enter, %{})
      assert focus.mode == :insert
    end

    test "i returns to INSERT without routing a key", %{focus: focus} do
      {focus, {:mode, :insert}} = Focus.handle_key(focus, {:char, "i"}, %{})
      assert focus.mode == :insert
    end

    test "Esc returns focus to Conversation", %{focus: focus} do
      focus = Focus.jump(focus, :inspector)
      {focus, :none} = Focus.handle_key(focus, :esc, %{})
      assert Focus.current(focus) == :conversation
      assert focus.mode == :nav
    end

    test "an unmapped key falls through to the zone (never silently dropped)", %{focus: focus} do
      assert {_f, {:route_zone, {:char, "z"}}} = Focus.handle_key(focus, {:char, "z"}, %{})
    end
  end
end
