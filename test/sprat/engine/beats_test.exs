defmodule Sprat.Engine.BeatsTest do
  use ExUnit.Case, async: true

  alias Sprat.Engine.Beats
  alias Sprat.Observer.Model.Event

  @now ~U[2026-11-24 12:00:00Z]

  defp ev(kind, secs_ago, data \\ %{}, side? \\ false),
    do: %Event{
      kind: kind,
      line: 1,
      at: DateTime.add(@now, -secs_ago),
      data: data,
      sidechain?: side?
    }

  test "what a session did, as beats: kind, target, when" do
    events = [
      ev(:user_text, 100),
      ev(:tool_use, 90, %{name: "Read", input: %{"file_path" => "/a/b/board.ex"}}),
      ev(:tool_use, 80, %{name: "Edit", input: %{"file_path" => "/a/b/view.ex"}}),
      ev(:tool_use, 70, %{name: "Bash", input: %{"command" => "cd /x/y && mix test\nmore"}}),
      ev(:tool_result, 60, %{is_error: true}),
      ev(:tool_use, 50, %{name: "Grep", input: %{"pattern" => "def foo"}}),
      ev(:assistant_text, 40),
      ev(:tool_use, 30, %{name: "AskUserQuestion", input: %{}}),
      ev(:tool_use, 20, %{name: "Edit", input: %{}}, true),
      ev(:title, 10)
    ]

    now = DateTime.to_unix(@now, :millisecond)

    assert Beats.from_events(events, now) == [
             {now - 100_000, :you, nil},
             {now - 90_000, :read, "board.ex"},
             {now - 80_000, :edit, "view.ex"},
             {now - 70_000, :run, "mix test"},
             {now - 60_000, :fail, nil},
             {now - 50_000, :read, "def foo"},
             {now - 40_000, :say, nil},
             {now - 30_000, :ask, nil}
           ]
  end

  test "only the last three minutes" do
    now = DateTime.to_unix(@now, :millisecond)

    assert Beats.from_events([ev(:assistant_text, 200), ev(:assistant_text, 100)], now) ==
             [{now - 100_000, :say, nil}]
  end
end
