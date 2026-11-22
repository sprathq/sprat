defmodule Sprat.Terminal.ComposerTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Composer

  defp type(state, chars) when is_binary(chars) do
    chars
    |> String.graphemes()
    |> Enum.reduce(state, fn ch, state ->
      {:ok, state} = Composer.handle_event(state, {:char, ch})
      state
    end)
  end

  defp send_event(state, event) do
    {:ok, state} = Composer.handle_event(state, event)
    state
  end

  test "typing appends to the buffer" do
    state = Composer.new() |> type("hi")
    assert state.text == "hi"
    assert state.cursor == 2
  end

  test "backspace removes the previous grapheme" do
    state = Composer.new() |> type("hi") |> send_event(:backspace)
    assert state.text == "h"
  end

  test "Enter submits and clears the composer" do
    state = Composer.new() |> type("hello")
    assert {:submit, "hello", new_state} = Composer.handle_event(state, :enter)
    assert new_state.text == ""
    assert new_state.cursor == 0
  end

  test "submitted text is pushed onto history" do
    state = Composer.new() |> type("hello")
    {:submit, _text, state} = Composer.handle_event(state, :enter)
    assert "hello" in state.history
  end

  test "trailing backslash then Enter inserts a newline instead of submitting" do
    state = Composer.new() |> type("line1\\")
    {:ok, state} = Composer.handle_event(state, :enter)
    assert state.text == "line1\n"
  end

  test "Alt+Enter inserts a newline" do
    state = Composer.new() |> type("a") |> send_event(:alt_enter)
    assert state.text == "a\n"
  end

  test "Shift+Enter inserts a newline" do
    state = Composer.new() |> type("a") |> send_event(:shift_enter)
    assert state.text == "a\n"
  end

  test "Ctrl+A / Ctrl+E move to line start/end" do
    state = Composer.new() |> type("hello")
    state = send_event(state, {:ctrl, "a"})
    assert state.cursor == 0
    state = send_event(state, {:ctrl, "e"})
    assert state.cursor == 5
  end

  test "Ctrl+K kills to end of line" do
    state = Composer.new() |> type("hello") |> send_event({:ctrl, "a"})
    state = send_event(state, {:ctrl, "k"})
    assert state.text == ""
  end

  test "Ctrl+U kills to start of line" do
    state = Composer.new() |> type("hello")
    state = send_event(state, {:ctrl, "u"})
    assert state.text == ""
  end

  test "Ctrl+W deletes the previous word" do
    state = Composer.new() |> type("hello world")
    state = send_event(state, {:ctrl, "w"})
    assert state.text == "hello "
  end

  test "Alt+Left/Right move by word" do
    state = Composer.new() |> type("hello world")
    state = send_event(state, {:left, [:alt]})
    assert state.cursor == 6

    state = send_event(state, {:right, [:alt]})
    assert state.cursor == 11
  end

  test "bracketed paste of a short block inserts the content directly" do
    state = Composer.new() |> send_event({:paste, "a\nb"})
    assert state.text == "a\nb"
  end

  test "bracketed paste of a long block collapses to a placeholder that expands on submit" do
    content = Enum.map_join(1..10, "\n", &"line#{&1}")
    state = Composer.new() |> send_event({:paste, content})
    assert state.text =~ "[Pasted text #1 +10 lines]"

    {:submit, submitted, _state} = Composer.handle_event(state, :enter)
    assert submitted == content
  end

  test "history navigation recalls previous entries with Up, restores draft with Down" do
    composer = Composer.new(history: ["second", "first"])
    composer = type(composer, "draft")
    composer = send_event(composer, :up)
    assert composer.text == "second"

    composer = send_event(composer, :up)
    assert composer.text == "first"

    composer = send_event(composer, :down)
    assert composer.text == "second"

    composer = send_event(composer, :down)
    assert composer.text == "draft"
  end

  test "slash menu filters the supplied command list" do
    composer =
      Composer.new(commands: [{"idea", "start idea"}, {"research", "start research"}])
      |> type("/re")

    assert %{matches: [{"research", _}]} = Composer.menu(composer)
  end

  test "menu is nil once a space follows the slash" do
    composer = Composer.new(commands: [{"idea", "d"}]) |> type("/idea ")
    assert Composer.menu(composer) == nil
  end

  test "Tab completes the selected menu entry" do
    composer =
      Composer.new(commands: [{"idea", "d"}, {"research", "d"}])
      |> type("/re")
      |> send_event(:tab)

    assert composer.text == "/research "
  end

  test "cursor_position tracks row/col across newlines" do
    composer = Composer.new() |> type("ab") |> send_event(:alt_enter) |> type("c")
    assert Composer.cursor_position(composer) == {1, 1}
  end

  describe "@-mention completion" do
    test "fuzzy-matches files against the @token at the cursor" do
      composer =
        Composer.new(files: ["docs/plan.md", "data/churn.csv", "src/app.ex"])
        |> type("look at @chn")

      assert %{matches: matches} = Composer.mention(composer)
      assert "data/churn.csv" in matches
    end

    test "no mention when there's no files list to match against" do
      composer = Composer.new() |> type("look at @anything")
      assert Composer.mention(composer) == nil
    end

    test "no mention mid-word (an email address, say)" do
      composer = Composer.new(files: ["foo.txt"]) |> type("me@foo.txt")
      assert Composer.mention(composer) == nil
    end

    test "mention closes once a space follows the token" do
      composer = Composer.new(files: ["a.txt"]) |> type("@a.txt ")
      assert Composer.mention(composer) == nil
    end

    test "Tab completes the selected mention into @path with a trailing space" do
      composer =
        Composer.new(files: ["docs/plan.md", "data/churn.csv"])
        |> type("look at @chn")
        |> send_event(:tab)

      assert composer.text == "look at @data/churn.csv "
    end

    test "Tab completion leaves the rest of the line (typed after the mention) intact" do
      composer =
        Composer.new(files: ["docs/plan.md"])
        |> type("look at @doc and tell me")

      # move the cursor back to just after "@doc" before completing
      composer = %{composer | cursor: Composer.length_of("look at @doc")}
      composer = send_event(composer, :tab)

      assert composer.text == "look at @docs/plan.md  and tell me"
    end

    test "Up/Down cycle the mention selection independently of history" do
      composer =
        Composer.new(files: ["a/one.txt", "b/one.txt"])
        |> type("@one")

      assert %{selected: 0} = Composer.mention(composer)
      composer = send_event(composer, :down)
      assert %{selected: 1} = Composer.mention(composer)
    end

    test "the slash menu and the @ mention menu don't both fire" do
      composer = Composer.new(commands: [{"idea", "d"}], files: ["idea.txt"]) |> type("/idea")
      assert Composer.menu(composer) != nil
      assert Composer.mention(composer) == nil
    end
  end
end
