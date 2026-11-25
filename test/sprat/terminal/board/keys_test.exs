defmodule Sprat.Terminal.Board.KeysTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Board.{Fixture, Keys, View}

  @now ~U[2026-11-23 14:02:00Z]
  @bc "/Users/owner/Projects/cupful"

  defp view, do: View.new(Fixture.snapshot(@now))

  defp press(view, keys) do
    Enum.reduce(List.wrap(keys), {view, []}, fn key, {v, cmds} ->
      {v, new} = Keys.handle(v, key)
      {v, cmds ++ new}
    end)
  end

  defp type(text), do: text |> String.graphemes() |> Enum.map(&{:char, &1})

  test "quit on q and ctrl+c, even with a composer open" do
    assert {_, [:quit]} = press(view(), {:char, "q"})
    assert {_, [:quit]} = press(view(), :ctrl_c)
    {v, _} = press(view(), {:char, "/"})
    assert {_, [:quit]} = press(v, :ctrl_c)
  end

  test "rail and line movement with arrows and hjkl" do
    {v, []} = press(view(), [:right, {:char, "l"}])
    assert v.rail_index == 2 and v.focus == :rail
    {v, []} = press(v, {:char, "h"})
    assert v.rail_index == 1
    {v, []} = press(v, [:down, {:char, "j"}])
    assert v.focus == :line and v.line_index == 1
    {v, []} = press(v, [:up, :up])
    assert v.focus == :rail
    {v, []} = press(v, List.duplicate(:right, 9))
    assert v.rail_index == 4
  end

  test "down past the line moves into served" do
    v = %{view() | focus: :line, line_index: 8}
    {v, []} = press(v, :down)
    assert v.focus == :served
    {v, []} = press(v, :up)
    assert v.focus == :line
  end

  test "enter opens the selected ticket in place, esc folds it" do
    {v, []} = press(view(), :enter)
    assert v.opened_ticket == "t-cert"
    {v, []} = press(v, :right)
    assert v.opened_ticket == "t-network" and v.rail_index == 1
    {v, []} = press(v, :esc)
    assert v.opened_ticket == nil
  end

  test "f fires the proposal; nothing to fire is a status, not a command" do
    assert {v, []} = press(view(), {:char, "f"})
    assert v.status =~ "nothing to fire"
    {v, cmds} = press(view(), [:right, {:char, "f"}])
    assert [{:fire, "t-network", "Keep the old network_id" <> _}] = cmds
    assert v.status =~ "fired"
  end

  test "e edits the proposal inline with the composer, f then fires the edit" do
    {v, []} = press(view(), [:right, :enter, {:char, "e"}])
    assert v.composer.purpose == :edit_proposal
    {v, []} = press(v, type(" Thanks.") ++ [:enter])
    assert v.composer == nil
    assert v.edited["t-network"] =~ ~r/shipped\. Thanks\.$/
    {_v, [{:fire, "t-network", text}]} = press(v, {:char, "f"})
    assert text =~ "Thanks."
  end

  test "esc cancels an edit without saving" do
    {v, []} = press(view(), [:right, :enter, {:char, "e"}] ++ type("zzz") ++ [:esc])
    assert v.composer == nil and v.edited == %{}
    assert v.opened_ticket == "t-network"
  end

  test "x dismisses at once on the board, asks a reason when opened" do
    assert {_, [{:dismiss, "t-cert", nil}]} = press(view(), {:char, "x"})
    {v, []} = press(view(), [:enter, {:char, "x"}])
    assert v.composer.purpose == :dismiss_reason
    {v, cmds} = press(v, type("imported it") ++ [:enter])
    assert cmds == [{:dismiss, "t-cert", "imported it"}]
    assert v.opened_ticket == nil
  end

  test "opened ticket: u reverts its writes, m mutes, c copies, E goes to the editor" do
    {v, []} = press(view(), :enter)
    assert {_, [{:revert, "w-b7"}]} = press(v, {:char, "u"})
    assert {_, [{:mute, "f-l1"}]} = press(v, {:char, "m"})
    assert {_, [{:copy, "Import the iOS" <> _}]} = press(v, {:char, "c"})
    assert {_, [{:edit_in_editor, "t-cert", _}]} = press(v, {:char, "E"})
  end

  test "enter on an opened ticket opens its session, esc returns to the project" do
    {v, [{:session_lines, "cf-4b"}]} = press(view(), [:right, :enter, :enter])
    assert v.screen == {:session, "cf-4b"}
    assert v.session_index == 7
    {v, []} = press(v, :enter)
    assert MapSet.member?(v.session_expanded, 7)
    assert {_, [{:open_session_terminal, "cf-4b"}]} = press(v, {:ctrl, "o"})
    {v, []} = press(v, :esc)
    assert v.screen == {:project, @bc}
    {v, []} = press(v, :esc)
    assert v.screen == :board
  end

  test "line row: enter opens the project, A cycles autonomy, r and b" do
    v = %{view() | focus: :line, line_index: 0}
    {pv, []} = press(v, :enter)
    assert pv.screen == {:project, @bc}
    assert {_, [{:set_autonomy, @bc, :act_resume}]} = press(v, {:char, "A"})
    assert {_, [{:reread_roadmap, @bc}]} = press(v, {:char, "r"})
    assert {_, [{:brief, :all}]} = press(v, {:char, "b"})

    studio = Enum.find_index(View.line(v), &(&1.name == "studio"))
    assert {_, [{:write_roadmap, _}]} = press(%{v | line_index: studio}, {:char, "r"})
  end

  test "project screen keys" do
    v = View.clamp(%{view() | screen: {:project, @bc}})
    assert {_, [{:fire, "t-network", _}]} = press(v, {:char, "f"})
    assert {_, [{:edit_roadmap, @bc}]} = press(v, {:char, "e"})
    assert {_, [{:write_roadmap, @bc}]} = press(v, {:char, "w"})
    assert {_, [{:brief, @bc}]} = press(v, {:char, "b"})
    assert {_, [{:set_autonomy, @bc, :act_resume}]} = press(v, {:char, "A"})
    {v2, [{:session_lines, "cf-4b"}]} = press(v, [:down, :enter])
    assert v2.screen == {:session, "cf-4b"}
    {v3, []} = press(v, :enter)
    assert v3.opened_ticket == "t-network"
  end

  test "autonomy cycles watch → propose → act → act+resume → watch" do
    assert Keys.next_autonomy(:watch) == :propose
    assert Keys.next_autonomy(:propose) == :act
    assert Keys.next_autonomy(:act) == :act_resume
    assert Keys.next_autonomy(:act_resume) == :watch
  end

  test "/ command line" do
    run = fn text -> press(view(), [{:char, "/"}] ++ type(text) ++ [:enter]) end
    assert {_, [{:brief, :all}]} = run.("brief")
    assert {_, [{:slash, "add", "~/Projects/studio"}]} = run.("add ~/Projects/studio")
    assert {_, [{:slash, "settings", nil}]} = run.("settings")
    assert {v, []} = run.("nope")
    assert v.status =~ "unknown command"
    {v, []} = press(view(), [{:char, "/"}, :backspace])
    assert v.composer == nil
    {v, []} = press(view(), [{:char, "/"}, {:char, "s"}, {:char, "t"}, :tab])
    assert v.composer.composer.text == "/stats "
  end

  test "esc closes the brief overlay first" do
    v = %{view() | overlay: {:brief, "x"}}
    {v, []} = press(v, :esc)
    assert v.overlay == nil
  end

  test "? toggles help" do
    {v, []} = press(view(), {:char, "?"})
    assert v.help?
    {v, []} = press(v, :esc)
    refute v.help?
  end

  test "a ticket that leaves the rail folds" do
    {v, []} = press(view(), :enter)
    snap = Fixture.snapshot(@now)
    v = View.put_snapshot(v, %{snap | tickets: Enum.reject(snap.tickets, &(&1.id == "t-cert"))})
    assert v.opened_ticket == nil
  end

  describe "a session's screen talks to the session" do
    # The fixture session, with a cmux tab to mirror.
    defp in_session(screen_text \\ nil) do
      v = view()

      projects =
        Enum.map(v.snapshot.projects, fn p ->
          %{
            p
            | sessions:
                Enum.map(p.sessions, fn s ->
                  if s.session_id == "cf-4b", do: %{s | surface: "surface:12"}, else: s
                end)
          }
        end)

      v = View.put_snapshot(v, %{v.snapshot | projects: projects})
      v = %{v | screen: {:session, "cf-4b"}}
      if screen_text, do: View.put_session_screen(v, "cf-4b", screen_text), else: v
    end

    test "typing starts a message, q included; ⏎ sends it; esc drops it" do
      {v, []} = press(in_session(), type("quick question"))
      assert v.composer.purpose == :to_session
      assert v.composer.composer.text == "quick question"
      assert {v2, [{:send_to_session, "cf-4b", "quick question"}]} = press(v, :enter)
      assert v2.composer == nil

      {v3, []} = press(v, :esc)
      assert v3.composer == nil

      assert {_, []} = press(in_session(), :enter) |> then(fn {v, c} -> {v.composer, c} end)

      assert {%{composer: %{composer: %{text: "pasted"}}}, []} =
               press(in_session(), {:paste, "pasted"})
    end

    test "? is still help; tab cycles terminal, transcript and recap; ctrl-o goes to its tab" do
      assert {%{help?: true}, []} = press(in_session(), {:char, "?"})
      {v, []} = press(in_session(), :tab)
      assert v.session_mode == :transcript
      {v, []} = press(v, :tab)
      assert v.session_mode == :recap
      {v, []} = press(v, :tab)
      assert v.session_mode == :terminal
      assert {_, [{:open_session_terminal, "cf-4b"}]} = press(in_session(), {:ctrl, "o"})
    end

    test "while its terminal shows a dialog, digits, arrows and ⏎ answer it" do
      dialog = """
      Do you want to proceed?
      ❯ 1. Yes
        2. No, and tell Claude what to do differently (esc)
      """

      v = in_session(dialog)
      assert View.session_dialog?(v, "cf-4b")
      assert {_, [{:session_key, "cf-4b", "2"}]} = press(v, {:char, "2"})
      assert {_, [{:session_key, "cf-4b", "down"}]} = press(v, :down)
      assert {_, [{:session_key, "cf-4b", "enter"}]} = press(v, :enter)
      # Letters still write a message.
      assert {%{composer: %{purpose: :to_session}}, []} = press(v, {:char, "n"})

      # In the transcript view nothing is forwarded.
      refute View.session_dialog?(%{v | session_mode: :transcript}, "cf-4b")
    end
  end
end
