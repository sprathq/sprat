defmodule Sprat.DebugTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Events, Tasks, Usage}

  describe "requests/2" do
    test "one row per leaf usage record, newest first, paired with its model.request/response events",
         %{store: store} do
      {session, mission, task} = fixture_chain(store)

      Events.append(store, session.id, "model.request", %{
        mission_id: mission.id,
        task_id: task.id,
        correlation_id: "call_1",
        payload: %{"messages" => [%{"role" => "user", "content" => "hi"}]}
      })

      Events.append(store, session.id, "model.response", %{
        mission_id: mission.id,
        task_id: task.id,
        correlation_id: "call_1",
        payload: %{"stop_reason" => "stop", "content" => "hello"}
      })

      Usage.record(store, %{
        task_id: task.id,
        mission_id: mission.id,
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "call_1",
        raw_payload: %{},
        coverage: "reported",
        cost: Decimal.new("0.01"),
        ended_at: "2026-09-18T00:00:01Z"
      })

      [row] = Sprat.Debug.requests(store, mission.id)
      assert row.usage.request_id == "call_1"
      assert row.stop_reason == "stop"
      assert row.request_event.type == "model.request"
      assert row.response_event.type == "model.response"
      refute row.failed?
    end

    test "a call with no matching model.request/response events still shows the usage row", %{
      store: store
    } do
      {_session, mission, task} = fixture_chain(store)

      Usage.record(store, %{
        task_id: task.id,
        mission_id: mission.id,
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "orphan",
        raw_payload: %{},
        coverage: "estimated",
        ended_at: "t"
      })

      [row] = Sprat.Debug.requests(store, mission.id)
      assert row.request_event == nil
      assert row.response_event == nil
    end
  end

  describe "tool_calls/2" do
    test "pairs tool.requested with tool.completed by tool_call_id", %{store: store} do
      {session, mission, task} = fixture_chain(store)

      Events.append(store, session.id, "tool.requested", %{
        mission_id: mission.id,
        task_id: task.id,
        payload: %{
          "tool" => "web_fetch",
          "tool_call_id" => "tc_1",
          "arguments" => %{"url" => "https://x"}
        }
      })

      Events.append(store, session.id, "tool.completed", %{
        mission_id: mission.id,
        task_id: task.id,
        payload: %{"tool" => "web_fetch", "tool_call_id" => "tc_1", "ok?" => true}
      })

      [row] = Sprat.Debug.tool_calls(store, [task])
      assert row.name == "web_fetch"
      assert row.ok? == true
    end

    test "a tool call still awaiting completion shows a nil result, not a fake success", %{
      store: store
    } do
      {session, mission, task} = fixture_chain(store)

      Events.append(store, session.id, "tool.requested", %{
        mission_id: mission.id,
        task_id: task.id,
        payload: %{"tool" => "calculate", "tool_call_id" => "tc_2", "arguments" => %{}}
      })

      [row] = Sprat.Debug.tool_calls(store, [task])
      assert row.completed == nil
      assert row.ok? == nil
    end
  end

  describe "costs/3" do
    test "mission and per-task totals never sum an already-summed total (each computed from its own leaf records)",
         %{store: store} do
      {_session, mission, task1} = fixture_chain(store, objective: "task one")
      {:ok, task2} = Tasks.create(store, mission.id, %{role: "researcher", objective: "task two"})

      Usage.record(store, %{
        task_id: task1.id,
        mission_id: mission.id,
        provider: "openai",
        model: "m",
        raw_payload: %{},
        coverage: "reported",
        cost: Decimal.new("1.00"),
        ended_at: "t"
      })

      Usage.record(store, %{
        task_id: task2.id,
        mission_id: mission.id,
        provider: "openai",
        model: "m",
        raw_payload: %{},
        coverage: "reported",
        cost: Decimal.new("2.00"),
        ended_at: "t"
      })

      costs = Sprat.Debug.costs(store, mission.id, [task1, task2])

      assert Decimal.equal?(costs.mission_totals.cost, Decimal.new("3.00"))
      task1_total = Enum.find(costs.per_task, &(&1.task.id == task1.id)).totals
      task2_total = Enum.find(costs.per_task, &(&1.task.id == task2.id)).totals
      assert Decimal.equal?(task1_total.cost, Decimal.new("1.00"))
      assert Decimal.equal?(task2_total.cost, Decimal.new("2.00"))
    end

    test "unknown cost stays unknown — never coerced to 0 and never averaged into the total", %{
      store: store
    } do
      {_session, mission, task} = fixture_chain(store)

      Usage.record(store, %{
        task_id: task.id,
        mission_id: mission.id,
        provider: "openai",
        model: "m",
        raw_payload: %{},
        coverage: "unavailable",
        cost: nil,
        ended_at: "t"
      })

      costs = Sprat.Debug.costs(store, mission.id, [task])
      assert costs.mission_totals.cost == nil
      assert costs.unknown_or_estimated == 1
    end
  end

  describe "events/2" do
    test "filters by a substring of type and by task id", %{store: store} do
      {session, mission, task} = fixture_chain(store)
      {:ok, task2} = Tasks.create(store, mission.id, %{role: "researcher", objective: "other"})

      Events.append(store, session.id, "model.request", %{
        task_id: task.id,
        mission_id: mission.id
      })

      Events.append(store, session.id, "tool.requested", %{
        task_id: task2.id,
        mission_id: mission.id
      })

      assert [%{type: "model.request"}] = Sprat.Debug.events(store, session.id, type: "model.")
      assert [%{task_id: id}] = Sprat.Debug.events(store, session.id, task_id: task.id)
      assert id == task.id
    end
  end
end
