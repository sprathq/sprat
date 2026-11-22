defmodule Sprat.Model.ReplayTest do
  use ExUnit.Case, async: true

  alias Sprat.Model.Replay

  setup do
    root = Path.join(System.tmp_dir!(), "sprat_replay_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{fixtures_root: root}
  end

  defp write_fixture!(root, mission_id, exchanges, meta \\ %{"id" => "test"}) do
    dir = Path.join(root, mission_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "exchanges.json"), JSON.encode!(exchanges))
    File.write!(Path.join(dir, "meta.json"), JSON.encode!(meta))
  end

  defp final_turn(text, request \\ nil) do
    %{
      "request" => request,
      "response" => %{
        "content" => text,
        "tool_calls" => [],
        "stop_reason" => "stop",
        "usage" => %{}
      }
    }
  end

  defp tool_call_turn(request \\ nil) do
    %{
      "request" => request,
      "response" => %{
        "content" => nil,
        "tool_calls" => [
          %{"id" => "call_1", "name" => "calculate", "arguments" => %{"expression" => "1+1"}}
        ],
        "stop_reason" => "tool_calls",
        "usage" => %{}
      }
    }
  end

  test "serves recorded responses in order", %{fixtures_root: root} do
    write_fixture!(root, "mission_a", [tool_call_turn(), final_turn("done")])
    assert {:ok, %{"id" => "test"}} = Replay.load("mission_a", "replay-a", root)

    assert {:ok, response1} = Replay.stream(%{model: "replay-a", messages: []}, [])
    assert response1.stop_reason == :tool_calls

    assert [%{id: "call_1", name: "calculate", arguments: %{"expression" => "1+1"}}] =
             response1.tool_calls

    assert {:ok, response2} = Replay.stream(%{model: "replay-a", messages: []}, [])
    assert response2.stop_reason == :stop
    assert response2.content == "done"
  end

  test "returns a clear, specific error once more turns are requested than were recorded", %{
    fixtures_root: root
  } do
    write_fixture!(root, "mission_b", [final_turn("only turn")])
    assert {:ok, _meta} = Replay.load("mission_b", "replay-b", root)
    assert {:ok, _} = Replay.stream(%{model: "replay-b", messages: []}, [])

    assert {:error, {:replay_exhausted, detail}} =
             Replay.stream(%{model: "replay-b", messages: []}, [])

    assert detail.model_id == "replay-b"
    assert detail.recorded_turns == 1
  end

  test "returns a clear, specific error when the live message count diverges from the recording",
       %{fixtures_root: root} do
    recorded_request = %{"messages" => [%{"role" => "system"}, %{"role" => "user"}]}
    write_fixture!(root, "mission_c", [final_turn("done", recorded_request)])
    assert {:ok, _meta} = Replay.load("mission_c", "replay-c", root)

    # The real caller is asking this turn to answer THREE messages' worth
    # of history — the recording only ever saw two at this point.
    request = %{
      model: "replay-c",
      messages: [%{"role" => "system"}, %{"role" => "user"}, %{"role" => "tool"}]
    }

    assert {:error, {:replay_diverged, detail}} = Replay.stream(request, [])
    assert detail.expected_message_count == 2
    assert detail.actual_message_count == 3
  end

  test "a nil recorded request (e.g. the first fixture turn) skips the divergence check", %{
    fixtures_root: root
  } do
    write_fixture!(root, "mission_d", [final_turn("done", nil)])
    assert {:ok, _meta} = Replay.load("mission_d", "replay-d", root)
    assert {:ok, _} = Replay.stream(%{model: "replay-d", messages: [%{"role" => "user"}]}, [])
  end

  test "extend/2 appends more turns onto an already-loaded script", %{fixtures_root: root} do
    write_fixture!(root, "mission_e", [final_turn("first")])
    assert {:ok, _meta} = Replay.load("mission_e", "replay-e", root)
    Replay.extend("replay-e", [final_turn("second")])

    assert {:ok, %{content: "first"}} = Replay.stream(%{model: "replay-e", messages: []}, [])
    assert {:ok, %{content: "second"}} = Replay.stream(%{model: "replay-e", messages: []}, [])
  end

  test "load/3 returns an error for a missing fixture", %{fixtures_root: root} do
    assert {:error, _} = Replay.load("does_not_exist", "replay-f", root)
  end
end
