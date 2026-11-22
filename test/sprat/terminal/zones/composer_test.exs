defmodule Sprat.Terminal.Zones.ComposerTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Composer
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @rect %{x: 0, y: 0, w: 20, h: 3}

  test "typing appends to the composer text, submit emits {:submit, text}" do
    state = Composer.init([])
    {state, []} = Composer.handle_key(state, {:char, "h"})
    {state, []} = Composer.handle_key(state, {:char, "i"})
    assert state.composer.text == "hi"

    {_state, [{:submit, "hi"}]} = Composer.handle_key(state, :enter)
  end

  test "empty?/1 and menu_open?/1 report composer state for global-keybinding context" do
    state = Composer.init([])
    assert Composer.empty?(state)
    {state, []} = Composer.handle_key(state, {:char, "x"})
    refute Composer.empty?(state)
    refute Composer.menu_open?(state)
  end

  test "menu_open?/1 is true while an @-mention has matches" do
    state = Composer.init(files: ["notes.txt"])

    state =
      Enum.reduce(String.graphemes("@not"), state, fn ch, state ->
        {state, []} = Composer.handle_key(state, {:char, ch})
        state
      end)

    assert Composer.menu_open?(state)
  end

  test "render/4 returns exactly rect.h rows of exactly rect.w cells" do
    state = Composer.init([])
    rows = Composer.render(state, @rect, true, 0)
    assert length(rows) == @rect.h
    assert Enum.all?(rows, &(length(&1) == @rect.w))
  end

  test "clear/1 resets typed text (Ctrl+C with unsent text — spec §10 Keybindings)" do
    state = Composer.init([])
    {state, []} = Composer.handle_key(state, {:char, "x"})
    refute Composer.empty?(state)

    state = Composer.clear(state)
    assert Composer.empty?(state)
  end

  # Bug: a line longer than the composer's own width was hard-cut at the
  # border with the rest invisible — you couldn't see what you were
  # typing. Real tmux capture confirmed it. Fixed with a horizontal
  # scroll that follows the cursor (design's "Multi-line composer": wrap
  # or scroll — scroll chosen since the zoned layout's composer height is
  # fixed).
  describe "render/4 (long line scrolls to follow the cursor)" do
    test "typing past the visible width keeps the cursor (and what was just typed) on screen" do
      rect = %{x: 0, y: 0, w: 20, h: 3}
      state = Composer.init([])

      state =
        Enum.reduce(String.graphemes(String.duplicate("x", 30) <> "END"), state, fn ch, state ->
          {state, []} = Composer.handle_key(state, {:char, ch})
          state
        end)

      text = Composer.render(state, rect, true, 0) |> rows_to_text()
      assert text =~ "END"
    end

    test "a long line is not simply truncated — it still fits within rect.w cells" do
      rect = %{x: 0, y: 0, w: 15, h: 3}
      state = Composer.init([])

      state =
        Enum.reduce(String.graphemes(String.duplicate("y", 40)), state, fn ch, state ->
          {state, []} = Composer.handle_key(state, {:char, ch})
          state
        end)

      rows = Composer.render(state, rect, true, 0)
      assert Enum.all?(rows, &(length(&1) == rect.w))
    end
  end

  # Bug: bracketed paste was silently swallowed in the zoned Composer zone
  # (no placeholder, no text, nothing submitted) — a regression against
  # `Sprat.Terminal.Composer`, which already handles this correctly and is
  # simply wrapped here. These pin the wrapping down at this layer too.
  describe "render/4 and handle_key/2 (paste)" do
    test "a paste over the collapse threshold shows the placeholder, not the raw text" do
      state = Composer.init([])
      paste = Enum.map_join(1..50, "\n", &"line #{&1}")
      {state, []} = Composer.handle_key(state, {:paste, paste})

      text = Composer.render(state, %{x: 0, y: 0, w: 40, h: 3}, true, 0) |> rows_to_text()
      assert text =~ "[Pasted text #1 +50 lines]"
      refute text =~ "line 1\nline 2"
    end

    test "submitting a pasted placeholder expands it back to the real multi-line content" do
      state = Composer.init([])
      paste = Enum.map_join(1..50, "\n", &"line #{&1}")
      {state, []} = Composer.handle_key(state, {:paste, paste})

      {state, [{:submit, submitted}]} = Composer.handle_key(state, :enter)
      assert submitted == paste
      assert Composer.empty?(state)
    end

    test "a short paste (at or under the collapse threshold) inserts the text directly, no placeholder" do
      state = Composer.init([])
      {state, []} = Composer.handle_key(state, {:paste, "a\nb"})

      rows = Composer.render(state, %{x: 0, y: 0, w: 40, h: 3}, true, 0)
      text = rows_to_text(rows)
      refute text =~ "Pasted text"

      # A three-row box holds one row of text, so the window follows the
      # caret — which a paste leaves on the last line.
      assert text =~ "b"
      assert length(rows) == 3
    end

    test "text longer than the box is clamped to it, never drawn past its rect" do
      # A three-line paste used to render five rows into a three-row box,
      # writing past the rect and tearing the layout apart — after which the
      # UI stopped repainting at all.
      # Three lines: at or under the collapse threshold, so this is real
      # multi-line text rather than a placeholder.
      state = Composer.init([])
      {state, []} = Composer.handle_key(state, {:paste, "one\ntwo\nthree"})

      for height <- 3..8 do
        rows = Composer.render(state, %{x: 0, y: 0, w: 40, h: height}, true, 0)

        assert length(rows) <= height,
               "h=#{height} rendered #{length(rows)} rows — past its rect"
      end

      # In the smallest box it fills exactly, and shows the caret's line.
      small = Composer.render(state, %{x: 0, y: 0, w: 40, h: 3}, true, 0)
      assert length(small) == 3
      assert rows_to_text(small) =~ "three"

      # With one row to spare, the hidden remainder is named rather than lost.
      assert Composer.render(state, %{x: 0, y: 0, w: 40, h: 4}, true, 0)
             |> rows_to_text() =~ "more line"
    end
  end
end
