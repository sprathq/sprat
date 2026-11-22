defmodule Sprat.Agent.Tools.RecordSourceTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.RecordSource
  alias Sprat.Store.Sources

  test "writes through Sprat.Store.Sources, and the mission's Evidence stays fillable from it", %{
    store: store
  } do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    assert {:ok, %{"source_id" => id, "url" => "https://example.com/post"}} =
             RecordSource.call(
               %{
                 "url" => "https://example.com/post",
                 "title" => "A post",
                 "publisher" => "Example",
                 "source_type" => "independent_reporting"
               },
               context
             )

    [source] = Sources.by_mission(store, mission.id)
    assert source.id == id
    assert source.title == "A post"
    assert source.source_type == "independent_reporting"
  end

  # Seam test: Sprat.Store.Sources' own moduledoc ("keyed for
  # de-duplication by canonical_url") and record_source's moduledoc both
  # promised this, and find_by_canonical_url/3 was unit-tested in
  # isolation, but record_in_conn/2 never called it — every re-cite of the
  # same URL just inserted another row. This fails again if that wiring
  # (in Sprat.Store.Sources.record_in_conn/2) is removed, even though
  # find_by_canonical_url/3 itself stays correct on its own.
  test "citing the same URL twice in one mission records it once, not twice", %{store: store} do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    args = %{
      "url" => "https://example.com/post",
      "title" => "A post",
      "source_type" => "independent_reporting"
    }

    assert {:ok, %{"source_id" => id1}} = RecordSource.call(args, context)
    assert {:ok, %{"source_id" => id2}} = RecordSource.call(args, context)

    assert id1 == id2
    assert [_one_source] = Sources.by_mission(store, mission.id)
  end

  test "records the content hash a prior web_fetch's blob_hash returned", %{store: store} do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    {:ok, _} =
      RecordSource.call(
        %{
          "url" => "https://example.com/x",
          "source_type" => "documentation",
          "content_hash" => "deadbeef"
        },
        context
      )

    [source] = Sources.by_mission(store, mission.id)
    assert source.content_hash == "deadbeef"
  end

  test "rejects an invalid source_type without touching the store", %{store: store} do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    assert {:error, message} =
             RecordSource.call(
               %{"url" => "https://x.example", "source_type" => "made_up"},
               context
             )

    assert message =~ "invalid source_type"
    assert Sources.by_mission(store, mission.id) == []
  end

  test "errors clearly when no store/mission_id is wired into the tool context" do
    assert {:error, message} =
             RecordSource.call(
               %{"url" => "https://x.example", "source_type" => "documentation"},
               %{}
             )

    assert message =~ "store"
  end
end
