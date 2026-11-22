defmodule Sprat.Store.EventsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Events

  describe "append/5" do
    test "writes the full §11 envelope", %{store: store} do
      {session, mission, task} = fixture_chain(store)

      {:ok, event} =
        Events.append(store, session.id, "task.started", %{
          mission_id: mission.id,
          task_id: task.id,
          attempt: 1,
          agent_id: "researcher_1",
          correlation_id: "call_1",
          payload: %{"note" => "starting"}
        })

      assert event.session_id == session.id
      assert event.mission_id == mission.id
      assert event.task_id == task.id
      assert event.type == "task.started"
      assert event.seq == 1
      assert event.schema_version == 1
      assert event.redaction_applied == false
      assert {:ok, _, _} = DateTime.from_iso8601(event.occurred_at)
      assert {:ok, _, _} = DateTime.from_iso8601(event.recorded_at)
    end

    test "allocates strictly increasing, gap-free seq per session", %{store: store} do
      {session, _mission, _task} = fixture_chain(store)

      events = for _ <- 1..10, do: elem(Events.append(store, session.id, "note", %{}), 1)
      seqs = Enum.map(events, & &1.seq)

      assert seqs == Enum.to_list(1..10)
    end

    test "seq counters are independent per session", %{store: store} do
      {session_a, _, _} = fixture_chain(store)
      {session_b, _, _} = fixture_chain(store)

      {:ok, ea1} = Events.append(store, session_a.id, "note", %{})
      {:ok, eb1} = Events.append(store, session_b.id, "note", %{})
      {:ok, ea2} = Events.append(store, session_a.id, "note", %{})

      assert [ea1.seq, ea2.seq] == [1, 2]
      assert eb1.seq == 1
    end

    test "redacts secrets in the payload before writing", %{store: store} do
      {session, _, _} = fixture_chain(store)

      {:ok, event} =
        Events.append(
          store,
          session.id,
          "model.request",
          %{payload: %{"key" => "sk-ant-abc123"}},
          [
            "sk-ant-abc123"
          ]
        )

      assert event.redaction_applied
      refute String.contains?(event.payload, "sk-ant-abc123")

      [row] =
        Sprat.Store.fetch_all(store, "SELECT payload FROM events WHERE event_id = ?1", [
          event.event_id
        ])

      refute String.contains?(row["payload"], "sk-ant-abc123")
    end

    test "large payloads are written to the blob store and referenced, not inlined", %{
      store: store
    } do
      {session, _, _} = fixture_chain(store)
      big_note = String.duplicate("x", 5_000)

      {:ok, event} =
        Events.append(store, session.id, "tool.completed", %{payload: %{"note" => big_note}})

      assert event.payload == nil
      assert event.payload_ref =~ ~r/^blob:sha256:/
    end

    test "small payloads are inlined, not blobbed", %{store: store} do
      {session, _, _} = fixture_chain(store)

      {:ok, event} =
        Events.append(store, session.id, "tool.completed", %{payload: %{"note" => "small"}})

      assert event.payload_ref == nil
      assert event.payload =~ "small"
    end
  end

  describe "queries" do
    test "by_session/3 returns events oldest first", %{store: store} do
      {session, _, _} = fixture_chain(store)
      {:ok, _} = Events.append(store, session.id, "a", %{})
      {:ok, _} = Events.append(store, session.id, "b", %{})

      assert Events.by_session(store, session.id) |> Enum.map(& &1.type) == ["a", "b"]
    end

    test "by_task/3 filters to one task", %{store: store} do
      {session, mission, task1} = fixture_chain(store)

      {:ok, task2} =
        Sprat.Store.Tasks.create(store, mission.id, %{role: "pm", objective: "other"})

      {:ok, _} = Events.append(store, session.id, "a", %{task_id: task1.id})
      {:ok, _} = Events.append(store, session.id, "b", %{task_id: task2.id})

      assert Events.by_task(store, task1.id) |> Enum.map(& &1.type) == ["a"]
    end

    test "by_type/4 filters within a session", %{store: store} do
      {session, _, _} = fixture_chain(store)
      {:ok, _} = Events.append(store, session.id, "a", %{})
      {:ok, _} = Events.append(store, session.id, "b", %{})
      {:ok, _} = Events.append(store, session.id, "a", %{})

      assert Events.by_type(store, session.id, "a") |> length() == 2
    end

    test "paging via limit/offset", %{store: store} do
      {session, _, _} = fixture_chain(store)
      for _ <- 1..5, do: Events.append(store, session.id, "n", %{})

      page1 = Events.by_session(store, session.id, limit: 2, offset: 0)
      page2 = Events.by_session(store, session.id, limit: 2, offset: 2)

      assert Enum.map(page1, & &1.seq) == [1, 2]
      assert Enum.map(page2, & &1.seq) == [3, 4]
    end
  end

  describe "concurrent appends (property)" do
    test "sequence numbers stay strictly increasing and gap-free under concurrent writers", %{
      store: store
    } do
      {session, _, _} = fixture_chain(store)
      concurrency = 20

      results =
        1..concurrency
        |> Task.async_stream(fn i -> Events.append(store, session.id, "concurrent_#{i}", %{}) end,
          max_concurrency: concurrency,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, {:ok, event}} -> event.seq end)
        |> Enum.sort()

      assert results == Enum.to_list(1..concurrency)
    end
  end
end
