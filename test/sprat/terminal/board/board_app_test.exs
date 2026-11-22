defmodule Sprat.Terminal.BoardAppTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.BoardApp
  alias Sprat.Terminal.Board.{Fixture, View}

  @now ~U[2026-11-23 14:02:00Z]

  defp view, do: View.new(Fixture.snapshot(@now))

  test "engine replies change the view" do
    v = view()

    assert BoardApp.apply_view_reply(v, {:copy, "x"}, {:ok, {:message, "copied"}}).status ==
             "copied"

    assert BoardApp.apply_view_reply(v, {:fire, "t", "x"}, {:error, "no session"}).status ==
             "no session"

    assert BoardApp.apply_view_reply(v, {:brief, :all}, {:ok, {:brief, "b"}}).overlay ==
             {:brief, "b"}

    assert BoardApp.apply_view_reply(v, {:mute, "f"}, :ok) == v
  end

  test "session lines from the engine are kept for that session and followed" do
    v = %{view() | screen: {:session, "cf-4b"}, session_index: 7}
    lines = for i <- 1..12, do: %{at: @now, kind: :tool, text: "line #{i}", error?: false}
    v = BoardApp.apply_view_reply(v, {:session_lines, "cf-4b"}, {:ok, {:session_lines, lines}})
    assert View.session_lines(v, "cf-4b") == lines
    assert v.session_index == 11
    assert View.session_lines(v, "other") == []
  end

  test "the editor command honours VISUAL, then EDITOR, then vi" do
    assert BoardApp.editor_command() =~ "${VISUAL:-${EDITOR:-vi}}"
  end
end
