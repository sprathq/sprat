defmodule Sprat.Store.SteeringMessagesTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.SteeringMessages

  describe "enqueue_in_conn/3 and pending/2" do
    test "a freshly enqueued message is pending", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, message} =
        Sprat.Store.transact(store, fn conn ->
          SteeringMessages.enqueue_in_conn(conn, session.id, mission.id, "UK only")
        end)

      assert message.status == "queued"
      assert [%{text: "UK only", status: "queued"}] = SteeringMessages.pending(store, mission.id)
    end

    test "pending/2 is delivery order — oldest first", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      Sprat.Store.transact(store, fn conn ->
        SteeringMessages.enqueue_in_conn(conn, session.id, mission.id, "first")
      end)

      Sprat.Store.transact(store, fn conn ->
        SteeringMessages.enqueue_in_conn(conn, session.id, mission.id, "second")
      end)

      assert SteeringMessages.pending(store, mission.id) |> Enum.map(& &1.text) ==
               ["first", "second"]
    end
  end

  describe "mark_delivered_in_conn/2" do
    test "removes it from pending/2 but keeps it in by_mission/2", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, message} =
        Sprat.Store.transact(store, fn conn ->
          SteeringMessages.enqueue_in_conn(conn, session.id, mission.id, "UK only")
        end)

      Sprat.Store.transact(store, fn conn ->
        SteeringMessages.mark_delivered_in_conn(conn, message.id)
      end)

      assert SteeringMessages.pending(store, mission.id) == []

      assert [%{text: "UK only", status: "delivered", delivered_at: at}] =
               SteeringMessages.by_mission(store, mission.id)

      refute is_nil(at)
    end
  end
end
