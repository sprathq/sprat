defmodule Sprat.Store.MissionsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Events, Missions}

  describe "create/3" do
    test "starts a mission in active status", %{store: store} do
      {session, _mission, _task} = fixture_chain(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "ship the thing"})

      assert mission.status == "active"
      assert mission.objective == "ship the thing"
    end
  end

  describe "transition/4" do
    test "writes the new status and a mission.transitioned event in one transaction", %{
      store: store
    } do
      {session, mission, _task} = fixture_chain(store)

      {:ok, updated} =
        Missions.transition(store, mission.id, :paused_budget, %{
          session_id: session.id,
          reason: "budget exhausted"
        })

      assert updated.status == "paused_budget"

      [event] = Events.by_session(store, session.id)
      assert event.type == "mission.transitioned"
      assert event.mission_id == mission.id
      assert event.payload =~ ~s("from":"active")
      assert event.payload =~ ~s("to":"paused_budget")
      assert event.payload =~ ~s("reason":"budget exhausted")
    end

    test "completed -> active is rejected without writing anything", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Missions.transition(store, mission.id, :completed, %{session_id: session.id})

      assert {:error, :invalid_transition} =
               Missions.transition(store, mission.id, :active, %{session_id: session.id})

      assert Missions.get(store, mission.id).status == "completed"
    end

    test "paused_budget can resume to active", %{store: store} do
      {session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Missions.transition(store, mission.id, :paused_budget, %{session_id: session.id})

      {:ok, resumed} =
        Missions.transition(store, mission.id, :active, %{session_id: session.id})

      assert resumed.status == "active"
    end

    test "returns :not_found for an unknown mission id", %{store: store} do
      {session, _mission, _task} = fixture_chain(store)

      assert {:error, :not_found} =
               Missions.transition(store, "mis_missing", :active, %{session_id: session.id})
    end
  end
end
