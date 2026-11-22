defmodule Sprat.Store.DecisionsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Decisions

  describe "record/3 and by_mission/2" do
    test "records a decision and returns it via by_mission", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, decision} =
        Decisions.record(store, mission.id, %{
          summary: "chose X over Y",
          evidence_for: "X is faster",
          evidence_against: "Y is simpler"
        })

      assert decision.summary == "chose X over Y"
      assert Decisions.by_mission(store, mission.id) |> Enum.map(& &1.id) == [decision.id]
    end

    test "returns decisions oldest first", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} = Decisions.record(store, mission.id, %{summary: "first"})
      {:ok, _} = Decisions.record(store, mission.id, %{summary: "second"})

      assert Decisions.by_mission(store, mission.id) |> Enum.map(& &1.summary) == [
               "first",
               "second"
             ]
    end
  end

  describe "by_mission/2" do
    test "is empty when nothing was recorded", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      assert Decisions.by_mission(store, mission.id) == []
    end
  end
end
