defmodule Sprat.Store.RecoveryTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Recovery, Tasks}

  describe "decide/1 (pure)" do
    test "selects only running tasks" do
      tasks = [
        %{id: "1", status: "queued"},
        %{id: "2", status: "running"},
        %{id: "3", status: "completed"},
        %{id: "4", status: "running"},
        %{id: "5", status: "failed"},
        %{id: "6", status: "cancelled"}
      ]

      assert Recovery.decide(tasks) |> Enum.map(& &1.id) == ["2", "4"]
    end

    test "never touches a completed task" do
      tasks = [%{id: "1", status: "completed"}]
      assert Recovery.decide(tasks) == []
    end

    test "leaves review_pending and changes_requested alone" do
      tasks = [%{id: "1", status: "review_pending"}, %{id: "2", status: "changes_requested"}]
      assert Recovery.decide(tasks) == []
    end
  end

  describe "scan/2" do
    test "marks running tasks interrupted and writes an event for each", %{store: store} do
      {session, _mission, task} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task.id, :running, %{session_id: session.id})

      reclassified = Recovery.scan(store, session.id)

      assert reclassified == [task.id]
      assert Tasks.get(store, task.id).status == "interrupted"
    end

    test "never touches a running task that belongs to a different session", %{store: store} do
      {session_a, _mission_a, task_a} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task_a.id, :running, %{session_id: session_a.id})

      {session_b, _mission_b, _task_b} = fixture_chain(store)

      # session_b booting (e.g. a second `sprat` process) must not touch
      # session_a's genuinely still-running task.
      reclassified = Recovery.scan(store, session_b.id)

      assert reclassified == []
      assert Tasks.get(store, task_a.id).status == "running"
    end

    test "never touches queued or completed tasks", %{store: store} do
      {session, mission, queued_task} = fixture_chain(store)

      {:ok, other} = Tasks.create(store, mission.id, %{role: "pm", objective: "other"})
      {:ok, other} = Tasks.transition(store, other.id, :running, %{session_id: session.id})
      {:ok, other} = Tasks.transition(store, other.id, :review_pending, %{session_id: session.id})
      {:ok, _completed} = Tasks.transition(store, other.id, :completed, %{session_id: session.id})

      reclassified = Recovery.scan(store, session.id)

      assert reclassified == []
      assert Tasks.get(store, queued_task.id).status == "queued"
      assert Tasks.get(store, other.id).status == "completed"
    end

    # Nothing exercised `scan/2` against a *multi-task* mission before —
    # a staged mission (Sprat.Orchestrator) creates one task per stage, so
    # this is the shape a real interrupted staged run leaves behind: an
    # earlier stage's task fully `completed`, and the mid-flight stage
    # stuck `running` from a `kill -9` (no clean shutdown, so it never
    # reaches `interrupted` on its own). Proves the existing scan/decide
    # logic already gives the Orchestrator what §13 resume needs: only the
    # genuinely mid-flight stage is reclassified, the completed one is
    # never touched.
    test "a staged mission interrupted mid-stage resumes from the last completed stage, not from the start",
         %{store: store} do
      {session, mission, intake} = fixture_chain(store, %{objective: "Intake"})
      {:ok, intake} = Tasks.transition(store, intake.id, :running, %{session_id: session.id})

      {:ok, intake} =
        Tasks.transition(store, intake.id, :review_pending, %{session_id: session.id})

      {:ok, _} = Tasks.transition(store, intake.id, :completed, %{session_id: session.id})

      {:ok, research} =
        Tasks.create(store, mission.id, %{role: "researcher", objective: "Research"})

      {:ok, _} = Tasks.transition(store, research.id, :running, %{session_id: session.id})
      # simulate a kill -9: research stays "running" in the DB, no clean shutdown

      reclassified = Recovery.scan(store, session.id)

      assert reclassified == [research.id]

      tasks = Tasks.by_mission(store, mission.id)
      assert Enum.find(tasks, &(&1.id == intake.id)).status == "completed"
      assert Enum.find(tasks, &(&1.id == research.id)).status == "interrupted"
    end
  end
end
