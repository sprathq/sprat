defmodule Sprat.Store.ArtifactsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Artifacts

  describe "write/3" do
    test "creates the artifact on first write, version 1", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, %{artifact: artifact, version: 1}} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"summary" => "s"},
          created_by: "researcher"
        })

      assert artifact.type == "research_memo"
      assert artifact.latest_version == 1
    end

    test "bumps the version on a second write, keeping both versions", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"summary" => "v1"},
          created_by: "researcher"
        })

      {:ok, %{version: 2}} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"summary" => "v2"},
          created_by: "researcher"
        })

      assert Artifacts.latest(store, mission.id, :research_memo) == %{"summary" => "v2"}

      assert Artifacts.versions(
               store,
               Artifacts.by_mission(store, mission.id) |> hd() |> Map.get(:id)
             )
             |> length() == 2
    end
  end

  describe "latest/3" do
    test "is nil when nothing was ever written", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      assert Artifacts.latest(store, mission.id, :research_memo) == nil
    end
  end

  describe "latest_all/2" do
    test "maps every artifact type this mission has to its latest content", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"objective" => "o"},
          created_by: "researcher"
        })

      assert Artifacts.latest_all(store, mission.id) == %{intake_summary: %{"objective" => "o"}}
    end

    test "is empty when the mission has no artifacts", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      assert Artifacts.latest_all(store, mission.id) == %{}
    end
  end

  describe "by_mission/2" do
    test "returns artifacts oldest first", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"a" => 1},
          created_by: "researcher"
        })

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"b" => 2},
          created_by: "researcher"
        })

      assert Artifacts.by_mission(store, mission.id) |> Enum.map(& &1.type) == [
               "intake_summary",
               "research_memo"
             ]
    end
  end

  # -- staleness (docs/spec-v1.md §10 — mid-mission steering) ---------------

  describe "mark_stale_in_conn/3 and stale_types/2" do
    test "flags every artifact this mission has already written", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"a" => 1},
          created_by: "researcher"
        })

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"b" => 2},
          created_by: "researcher"
        })

      {:ok, types} =
        Sprat.Store.transact(store, fn conn ->
          Artifacts.mark_stale_in_conn(conn, mission.id, "user steering: UK only")
        end)

      assert Enum.sort(types) == ["intake_summary", "research_memo"]

      assert Artifacts.stale_types(store, mission.id) ==
               MapSet.new([:intake_summary, :research_memo])

      [a1, a2] = Artifacts.by_mission(store, mission.id)
      assert a1.stale and a2.stale
      assert a1.stale_reason == "user steering: UK only"
    end

    test "never marks an artifact that didn't exist yet", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"a" => 1},
          created_by: "researcher"
        })

      {:ok, _types} =
        Sprat.Store.transact(store, fn conn ->
          Artifacts.mark_stale_in_conn(conn, mission.id, "UK only")
        end)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"b" => 2},
          created_by: "researcher"
        })

      assert Artifacts.stale_types(store, mission.id) == MapSet.new([:intake_summary])
    end

    test "a fresh write clears staleness for that type only", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"a" => 1},
          created_by: "researcher"
        })

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :research_memo,
          owning_role: "researcher",
          content: %{"b" => 2},
          created_by: "researcher"
        })

      {:ok, _} =
        Sprat.Store.transact(store, fn conn ->
          Artifacts.mark_stale_in_conn(conn, mission.id, "UK only")
        end)

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: :intake_summary,
          owning_role: "researcher",
          content: %{"a" => 2},
          created_by: "researcher"
        })

      assert Artifacts.stale_types(store, mission.id) == MapSet.new([:research_memo])
    end
  end
end
