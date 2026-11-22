defmodule Sprat.Terminal.Zones.PlaceholderTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Placeholder

  @rect %{x: 0, y: 0, w: 10, h: 4}

  describe "render/4 (pure: cells, no terminal)" do
    test "returns exactly rect.h rows, each exactly rect.w cells" do
      state = Placeholder.init(name: "Test", lines: ["one", "two"])
      rows = Placeholder.render(state, @rect, false, 0)
      assert length(rows) == @rect.h
      assert Enum.all?(rows, &(length(&1) == @rect.w))
    end

    test "the header row carries the zone name" do
      state = Placeholder.init(name: "Mission", lines: [])
      [header | _] = Placeholder.render(state, @rect, false, 0)
      text = header |> Enum.map(fn {ch, _style} -> ch end) |> Enum.join() |> String.trim()
      assert text == "Mission"
    end

    test "focused? changes the header's style but not its content" do
      state = Placeholder.init(name: "X", lines: [])
      [unfocused | _] = Placeholder.render(state, @rect, false, 0)
      [focused | _] = Placeholder.render(state, @rect, true, 0)
      assert Enum.map(unfocused, &elem(&1, 0)) == Enum.map(focused, &elem(&1, 0))
      refute unfocused == focused
    end

    test "body shows the bottom of the scrollback (bottom-anchored)" do
      state = Placeholder.init(name: "X", lines: Enum.map(1..20, &"line #{&1}"))
      rows = Placeholder.render(state, %{x: 0, y: 0, w: 12, h: 3}, false, 0)
      last_line = rows |> List.last() |> Enum.map(&elem(&1, 0)) |> Enum.join() |> String.trim()
      assert last_line == "line 20"
    end
  end

  describe "handle_key/2 scrolling" do
    test "up/down scroll the scrollback" do
      state = Placeholder.init(name: "X", lines: Enum.map(1..20, &"#{&1}"))
      {state, []} = Placeholder.handle_key(state, :up)
      assert state.scrollback.offset == 1
      {state, []} = Placeholder.handle_key(state, :down)
      assert state.scrollback.offset == 0
    end

    test "top/bottom jump" do
      state = Placeholder.init(name: "X", lines: Enum.map(1..20, &"#{&1}"))
      {state, []} = Placeholder.handle_key(state, :top)
      assert state.scrollback.offset == 19
      {state, []} = Placeholder.handle_key(state, :bottom)
      assert state.scrollback.offset == 0
    end

    test "an unrecognised key is dropped harmlessly (no crash, no intents)" do
      state = Placeholder.init(name: "X", lines: [])
      assert {^state, []} = Placeholder.handle_key(state, {:char, "z"})
    end
  end

  test "set_text/2 replaces the buffer wholesale" do
    state = Placeholder.init(name: "X", lines: ["old"])
    state = Placeholder.set_text(state, "new1\nnew2")
    assert Sprat.Terminal.Scrollback.viewport(state.scrollback, 2) == ["new1", "new2"]
  end
end
