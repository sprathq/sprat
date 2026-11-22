defmodule Sprat.Terminal.KeybindingsTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Keybindings

  @ctx %{composer_empty?: true, menu_open?: false}

  test "Esc interrupts" do
    assert {:interrupt, _} = Keybindings.dispatch(Keybindings.new(), :esc, @ctx, 0)
  end

  test "Esc Esc within the window edits an earlier message" do
    {_intent, state} = Keybindings.dispatch(Keybindings.new(), :esc, @ctx, 0)
    assert {:edit_earlier_message, _} = Keybindings.dispatch(state, :esc, @ctx, 100)
  end

  test "Esc after the window elapsed interrupts again instead of chaining" do
    {_intent, state} = Keybindings.dispatch(Keybindings.new(), :esc, @ctx, 0)
    assert {:interrupt, _} = Keybindings.dispatch(state, :esc, @ctx, 10_000)
  end

  test "Esc closes an open menu instead of interrupting" do
    ctx = %{@ctx | menu_open?: true}
    assert {:close_menu, _} = Keybindings.dispatch(Keybindings.new(), :esc, ctx, 0)
  end

  test "Ctrl+C on a non-empty composer clears it" do
    ctx = %{@ctx | composer_empty?: false}
    assert {:clear_composer, _} = Keybindings.dispatch(Keybindings.new(), :ctrl_c, ctx, 0)
  end

  test "Ctrl+C on an empty composer interrupts, twice within 2s exits" do
    {intent1, state} = Keybindings.dispatch(Keybindings.new(), :ctrl_c, @ctx, 0)
    assert intent1 == :interrupt
    assert {:exit, _} = Keybindings.dispatch(state, :ctrl_c, @ctx, 1_000)
  end

  test "Ctrl+C twice but more than 2s apart interrupts again, does not exit" do
    {_intent, state} = Keybindings.dispatch(Keybindings.new(), :ctrl_c, @ctx, 0)
    assert {:interrupt, _} = Keybindings.dispatch(state, :ctrl_c, @ctx, 3_000)
  end

  test "Ctrl+D exits only when the composer is empty" do
    assert {:exit, _} = Keybindings.dispatch(Keybindings.new(), :ctrl_d, @ctx, 0)
    ctx = %{@ctx | composer_empty?: false}
    assert {nil, _} = Keybindings.dispatch(Keybindings.new(), :ctrl_d, ctx, 0)
  end

  test "Shift+Tab cycles mode" do
    assert {{:mode, :cycle}, _} = Keybindings.dispatch(Keybindings.new(), :shift_tab, @ctx, 0)
  end

  test "Ctrl+O toggles verbose" do
    assert {:toggle_verbose, _} = Keybindings.dispatch(Keybindings.new(), {:ctrl, "o"}, @ctx, 0)
  end

  test "Ctrl+T toggles the checklist" do
    assert {:toggle_checklist, _} =
             Keybindings.dispatch(Keybindings.new(), {:ctrl, "t"}, @ctx, 0)
  end

  test "Ctrl+L redraws" do
    assert {:redraw, _} = Keybindings.dispatch(Keybindings.new(), {:ctrl, "l"}, @ctx, 0)
  end

  test "'?' opens help only when the composer is empty" do
    assert {:help, _} = Keybindings.dispatch(Keybindings.new(), {:char, "?"}, @ctx, 0)
    ctx = %{@ctx | composer_empty?: false}
    assert {nil, _} = Keybindings.dispatch(Keybindings.new(), {:char, "?"}, ctx, 0)
  end

  test "an ordinary character is not a global shortcut" do
    assert {nil, _} = Keybindings.dispatch(Keybindings.new(), {:char, "a"}, @ctx, 0)
  end
end
