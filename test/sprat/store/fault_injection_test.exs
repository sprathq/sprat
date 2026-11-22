defmodule Sprat.Store.FaultInjectionTest do
  @moduledoc """
  Two write paths the spec calls out as needing crash-safety: blob write
  then referencing row (§15), and state change then its event (§13, "one
  SQLite transaction"). Both are tested by forcing a crash at the seam and
  asserting nothing half-written survives. A third test does the real
  thing the release acceptance criterion (§16) asks for — `kill -9` the
  OS process mid-transaction — against a live subprocess, and checks the
  reopened database passes `PRAGMA integrity_check` and that Recovery
  classifies the interrupted work correctly.
  """

  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Blob, Events, Recovery, SQL, Tasks}

  describe "blob write then row commit" do
    test "a crash after the blob is written but before the row commits leaves an orphan blob, never a dangling reference",
         %{
           store: store,
           tmp_dir: tmp_dir
         } do
      {session, _mission, _task} = fixture_chain(store)
      blob_root = Path.join(tmp_dir, "blobs/sha256")

      # Simulate the crash: write the blob (as Events.append_in_conn would),
      # then blow up before the INSERT ever runs — same as the OS process
      # dying between the two steps.
      assert {:error, %RuntimeError{}} =
               Sprat.Store.transact(store, fn _conn ->
                 {:ok, _hash} = Blob.put(%{"note" => "partial"}, [], blob_root)
                 raise "simulated crash before row commit"
               end)

      # The blob exists on disk (write-before-reference already happened)...
      assert [prefix] = File.ls!(blob_root)
      assert [hash] = File.ls!(Path.join(blob_root, prefix))

      # ...but no row anywhere references it: it is a harmless orphan, not
      # a dangling reference, and gc_orphans/2 would reclaim it.
      referenced = Events.by_session(store, session.id) |> Enum.map(& &1.payload_ref)
      refute (prefix <> hash) in referenced
      assert Blob.gc_orphans([], blob_root) == 1
    end
  end

  describe "state change then event insert" do
    test "a crash between the state change and its event rolls back both, never leaving one without the other",
         %{
           store: store
         } do
      {_session, _mission, task} = fixture_chain(store)

      assert {:error, %RuntimeError{}} =
               Sprat.Store.transact(store, fn conn ->
                 SQL.exec(conn, "UPDATE tasks SET status = 'running' WHERE id = ?1", [task.id])
                 raise "simulated crash before the event insert"
               end)

      # Rolled back: the task is still queued, and no event was written.
      assert Tasks.get(store, task.id).status == "queued"
      assert Events.by_task(store, task.id) == []
    end
  end

  describe "kill -9 mid-transaction (real OS process)" do
    @describetag :fault_injection

    test "the database survives, reopens cleanly, and recovery classifies the interrupted task",
         %{tmp_dir: tmp_dir} do
      db_path = Path.join(tmp_dir, "killed.db")
      project_root = File.cwd!()

      code = """
      {:ok, store} = Sprat.Store.start_link(name: :hammer_store, db_path: #{inspect(db_path)})
      {:ok, session} = Sprat.Store.Sessions.create(store)
      {:ok, mission} = Sprat.Store.Missions.create(store, session.id, %{objective: "hammer"})
      {:ok, task} = Sprat.Store.Tasks.create(store, mission.id, %{role: "researcher", objective: "hammer task"})
      {:ok, _} = Sprat.Store.Tasks.transition(store, task.id, :running, %{session_id: session.id})
      File.write!(#{inspect(Path.join(tmp_dir, "task_id"))}, task.id)
      File.write!(#{inspect(Path.join(tmp_dir, "session_id"))}, session.id)
      File.write!(#{inspect(Path.join(tmp_dir, "ready"))}, "ready")
      Enum.each(1..100_000, fn i ->
        Sprat.Store.Events.append(store, session.id, "hammer_\#{i}", %{payload: %{"i" => i}})
      end)
      """

      port =
        Port.open({:spawn_executable, System.find_executable("mix")}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["run", "--no-start", "-e", code],
          cd: project_root,
          env: [{~c"MIX_ENV", ~c"test"}]
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      ready_path = Path.join(tmp_dir, "ready")
      wait_until(fn -> File.exists?(ready_path) end, 30_000)
      # Let it hammer a little so the kill lands mid-transaction, not before the loop starts.
      Process.sleep(50)
      System.cmd("kill", ["-9", to_string(os_pid)])

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        5_000 -> :ok
      end

      # Reopening the DB must not raise (exqlite would fail to open a
      # corrupted file, and `integrity_check` would report problems).
      {:ok, store} =
        Sprat.Store.start_link(
          name: :"reopened_#{System.unique_integer([:positive])}",
          db_path: db_path
        )

      assert [%{"integrity_check" => "ok"}] =
               Sprat.Store.fetch_all(store, "PRAGMA integrity_check")

      task_id = File.read!(Path.join(tmp_dir, "task_id"))
      session_id = File.read!(Path.join(tmp_dir, "session_id"))

      # Whatever attempt reached `running` before the kill is exactly the
      # thing Recovery must reclassify.
      assert Tasks.get(store, task_id).status == "running"
      assert Recovery.scan(store, session_id) == [task_id]
      assert Tasks.get(store, task_id).status == "interrupted"

      # Events that did commit form a gap-free, strictly increasing seq —
      # no torn writes.
      seqs = Events.by_session(store, session_id, limit: 200_000) |> Enum.map(& &1.seq)
      assert seqs == Enum.to_list(1..length(seqs))
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "timed out waiting for condition"

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline)
    end
  end
end
