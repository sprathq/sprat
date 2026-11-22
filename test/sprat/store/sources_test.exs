defmodule Sprat.Store.SourcesTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Sources

  describe "record/3 and find_by_canonical_url/3" do
    test "records a source and finds it by canonical URL", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, source} =
        Sources.record(store, mission.id, %{
          url: "https://example.com/post?utm=1",
          canonical_url: "https://example.com/post",
          title: "A post",
          source_type: "independent_reporting"
        })

      found = Sources.find_by_canonical_url(store, mission.id, "https://example.com/post")
      assert found.id == source.id
    end

    test "returns nil when no source matches", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)
      assert Sources.find_by_canonical_url(store, mission.id, "https://nope.example") == nil
    end
  end

  describe "by_mission/2" do
    test "returns sources oldest first", %{store: store} do
      {_session, mission, _task} = fixture_chain(store)

      {:ok, _} =
        Sources.record(store, mission.id, %{
          url: "https://a.example",
          source_type: "documentation"
        })

      {:ok, _} =
        Sources.record(store, mission.id, %{
          url: "https://b.example",
          source_type: "documentation"
        })

      assert Sources.by_mission(store, mission.id) |> Enum.map(& &1.url) == [
               "https://a.example",
               "https://b.example"
             ]
    end
  end
end
