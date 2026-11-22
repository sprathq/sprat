defmodule Sprat.Store.RunsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Runs

  describe "record/2" do
    test "records a run and round-trips every field", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      run =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task.id,
          command: "mix",
          args: ["test"],
          cwd: "/tmp/worktree",
          exit_code: 0,
          duration_ms: 1234,
          output_blob_hash: "abc123",
          truncated: false,
          network: false,
          sandbox_strength: "partial",
          purpose: "test"
        })

      assert run.command == "mix"
      assert run.args == ["test"]
      assert run.sandbox_strength == "partial"
      assert run.purpose == "test"
    end

    test "rejects an invalid sandbox_strength", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      assert_raise ArgumentError, fn ->
        Runs.record(store, %{
          mission_id: mission.id,
          command: "mix",
          args: [],
          cwd: "/tmp",
          duration_ms: 1,
          sandbox_strength: "enforced_and_then_some",
          purpose: "test"
        })
      end
    end

    test "rejects an invalid purpose", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      assert_raise ArgumentError, fn ->
        Runs.record(store, %{
          mission_id: mission.id,
          command: "mix",
          args: [],
          cwd: "/tmp",
          duration_ms: 1,
          sandbox_strength: "partial",
          purpose: "deploy"
        })
      end
    end
  end

  describe "by_mission/2" do
    test "returns runs for a mission, oldest first", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      {:ok, _} = other_mission(store)

      run1 =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task.id,
          command: "mix",
          args: ["compile"],
          cwd: "/tmp",
          duration_ms: 1,
          sandbox_strength: "partial",
          purpose: "run"
        })

      run2 =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task.id,
          command: "mix",
          args: ["test"],
          cwd: "/tmp",
          duration_ms: 1,
          sandbox_strength: "partial",
          purpose: "test"
        })

      assert Runs.by_mission(store, mission.id) |> Enum.map(& &1.id) == [run1.id, run2.id]
    end
  end

  describe "by_task/2" do
    test "returns only runs for that task", %{store: store} do
      {_session, mission, task} = fixture_chain(store)
      {_session2, _mission2, task2} = fixture_chain(store)

      run =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task.id,
          command: "npm",
          args: ["install"],
          cwd: "/tmp",
          duration_ms: 1,
          network: true,
          sandbox_strength: "partial",
          purpose: "install"
        })

      _other =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task2.id,
          command: "npm",
          args: ["install"],
          cwd: "/tmp",
          duration_ms: 1,
          sandbox_strength: "partial",
          purpose: "install"
        })

      results = Runs.by_task(store, task.id)
      assert Enum.map(results, & &1.id) == [run.id]
      assert hd(results).network == true
    end
  end

  describe "by_mission_with_output/2" do
    test "attaches the resolved blob output to each run", %{store: store} do
      {_session, mission, task} = fixture_chain(store)
      {:ok, hash} = Sprat.Store.Blob.put("test output\n[REDACTED]\n")

      run =
        Runs.record(store, %{
          mission_id: mission.id,
          task_id: task.id,
          command: "mix",
          args: ["test"],
          cwd: "/tmp",
          exit_code: 1,
          duration_ms: 10,
          output_blob_hash: hash,
          sandbox_strength: "partial",
          purpose: "test"
        })

      [result] = Runs.by_mission_with_output(store, mission.id)
      assert result.id == run.id
      assert result.output == "test output\n[REDACTED]\n"
    end

    test "a run with no captured output (nil hash) resolves to nil, not a crash", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      Runs.record(store, %{
        mission_id: mission.id,
        task_id: task.id,
        command: "mix",
        args: [],
        cwd: "/tmp",
        duration_ms: 1,
        sandbox_strength: "partial",
        purpose: "other"
      })

      [result] = Runs.by_mission_with_output(store, mission.id)
      assert result.output == nil
    end
  end

  defp other_mission(store) do
    {:ok, session} = Sprat.Store.Sessions.create(store)
    Sprat.Store.Missions.create(store, session.id, %{objective: "other"})
  end
end
