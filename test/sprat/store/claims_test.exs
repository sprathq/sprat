defmodule Sprat.Store.ClaimsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Claims, Sources}

  describe "record/4" do
    test "records a claim and links it to sources", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, source} =
        Sources.record(store, mission.id, %{
          url: "https://a.example",
          source_type: "documentation"
        })

      {:ok, claim} =
        Claims.record(
          store,
          mission.id,
          %{text: "gyms lose members over booking friction", confidence: :medium},
          [{source.id, :supports}]
        )

      [row] =
        Sprat.Store.fetch_all(store, "SELECT * FROM claim_sources WHERE claim_id = ?1", [claim.id])

      assert row["source_id"] == source.id
      assert row["stance"] == "supports"
    end

    test "an assumption claim can have no sources", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, claim} =
        Claims.record(store, mission.id, %{
          text: "assumed most gyms use spreadsheets",
          confidence: :low,
          is_assumption: true
        })

      assert claim.is_assumption
    end

    test "raises for an invalid confidence value" do
      assert_raise ArgumentError, ~r/invalid confidence/, fn ->
        Claims.record_in_conn(nil, "mission_1", %{text: "x", confidence: :extreme})
      end
    end
  end

  describe "by_mission/2" do
    test "returns claims for a mission", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      {:ok, _} = Claims.record(store, mission.id, %{text: "claim 1", confidence: :high})

      assert Claims.by_mission(store, mission.id) |> Enum.map(& &1.text) == ["claim 1"]
    end
  end
end
