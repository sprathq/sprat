defmodule Sprat.Store.ProjectionTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Projection, Sources, Tasks, Usage}

  describe "task_tree/2" do
    test "arranges tasks into parent/child nodes", %{store: store} do
      {_session, mission, root_task} = fixture_chain(store)

      {:ok, child} =
        Tasks.create(store, mission.id, %{
          role: "researcher",
          parent_task_id: root_task.id,
          objective: "sub-task"
        })

      [node] = Projection.task_tree(store, mission.id)

      assert node.task.id == root_task.id
      assert Enum.map(node.children, & &1.task.id) == [child.id]
    end
  end

  describe "usage_totals/2" do
    test "aggregates every usage record for the mission", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      {:ok, _} =
        Usage.record(store, %{
          task_id: task.id,
          mission_id: mission.id,
          provider: "anthropic",
          model: "claude-x",
          raw_payload: %{},
          input_tokens: 100,
          cost: Decimal.new("0.05"),
          coverage: :reported
        })

      totals = Projection.usage_totals(store, mission.id)
      assert totals.calls == 1
      assert Decimal.equal?(totals.cost, Decimal.new("0.05"))
    end
  end

  describe "source_register/2" do
    test "returns sources most recently recorded first", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Sources.record(store, mission.id, %{
          url: "https://a.example",
          source_type: "documentation"
        })

      {:ok, _} =
        Sources.record(store, mission.id, %{
          url: "https://b.example",
          source_type: "documentation"
        })

      assert Projection.source_register(store, mission.id) |> Enum.map(& &1.url) == [
               "https://b.example",
               "https://a.example"
             ]
    end
  end

  describe "session_events/2" do
    test "returns the full event log for the session", %{store: store} do
      {session, _mission, task} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task.id, :running, %{session_id: session.id})

      events = Projection.session_events(store, session.id)
      assert length(events) == 1
      assert hd(events).type == "task.transitioned"
    end
  end
end
