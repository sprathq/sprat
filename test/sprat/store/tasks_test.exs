defmodule Sprat.Store.TasksTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Events, Tasks}

  describe "create/3" do
    test "starts a task in queued with attempt 1", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      {:ok, task} = Tasks.create(store, mission.id, %{role: "pm", objective: "frame the problem"})

      assert task.status == "queued"
      assert task.attempt == 1
      assert task.role == "pm"
    end
  end

  describe "transition/4" do
    test "writes the new status and a task.transitioned event in one transaction", %{store: store} do
      {session, _mission, task} = fixture_chain(store)

      {:ok, updated} =
        Tasks.transition(store, task.id, :running, %{
          session_id: session.id,
          actor: "orchestrator"
        })

      assert updated.status == "running"

      [event] = Events.by_task(store, task.id)
      assert event.type == "task.transitioned"
      assert event.payload =~ ~s("from":"queued")
      assert event.payload =~ ~s("to":"running")
    end

    test "rejects an invalid transition and writes nothing", %{store: store} do
      {session, _mission, task} = fixture_chain(store)

      assert {:error, :invalid_transition} =
               Tasks.transition(store, task.id, :completed, %{session_id: session.id})

      assert Tasks.get(store, task.id).status == "queued"
      assert Events.by_task(store, task.id) == []
    end

    test "changes_requested -> queued bumps attempt", %{store: store} do
      {session, _mission, task} = fixture_chain(store)
      {:ok, task} = Tasks.transition(store, task.id, :running, %{session_id: session.id})
      {:ok, task} = Tasks.transition(store, task.id, :review_pending, %{session_id: session.id})

      {:ok, task} =
        Tasks.transition(store, task.id, :changes_requested, %{session_id: session.id})

      {:ok, task} = Tasks.transition(store, task.id, :queued, %{session_id: session.id})

      assert task.attempt == 2
    end

    test "cancelled is never completed", %{store: store} do
      {session, _mission, task} = fixture_chain(store)
      {:ok, task} = Tasks.transition(store, task.id, :running, %{session_id: session.id})
      {:ok, task} = Tasks.transition(store, task.id, :cancelled, %{session_id: session.id})

      assert {:error, :invalid_transition} =
               Tasks.transition(store, task.id, :completed, %{session_id: session.id})

      assert Tasks.get(store, task.id).status == "cancelled"
    end

    test "returns :not_found for an unknown task id", %{store: store} do
      {session, _, _} = fixture_chain(store)

      assert {:error, :not_found} =
               Tasks.transition(store, "task_missing", :running, %{session_id: session.id})
    end
  end

  describe "by_mission/3 and running/1" do
    test "filters by status", %{store: store} do
      {session, mission, task1} = fixture_chain(store)
      {:ok, task2} = Tasks.create(store, mission.id, %{role: "pm", objective: "other"})
      {:ok, _} = Tasks.transition(store, task1.id, :running, %{session_id: session.id})

      assert Tasks.by_mission(store, mission.id, :running) |> Enum.map(& &1.id) == [task1.id]
      assert Tasks.by_mission(store, mission.id) |> length() == 2
      assert Tasks.running(store) |> Enum.map(& &1.id) == [task1.id]
      refute task2.id in Enum.map(Tasks.running(store), & &1.id)
    end
  end
end
