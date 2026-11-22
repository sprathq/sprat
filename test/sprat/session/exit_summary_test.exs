defmodule Sprat.Session.ExitSummaryTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Session.ExitSummary
  alias Sprat.Store.{Missions, Sessions, Usage}

  setup %{store: store} do
    {:ok, session} = Sessions.create(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
    {:ok, session: session, mission: mission}
  end

  test "no mission started prints the honest empty state", %{store: store} do
    {:ok, session} = Sessions.create(store)
    lines = ExitSummary.lines(session.id, store)
    assert Enum.any?(lines, &(&1 =~ "no mission started"))
  end

  test "a mission with no usage recorded shows cost: unknown, never $0.00", %{
    session: session,
    store: store
  } do
    lines = ExitSummary.lines(session.id, store)
    assert Enum.any?(lines, &(&1 =~ "cost: unknown"))
  end

  test "a real sub-cent cost shows as <$0.01, not $0.00 (shares Zones.Mission.dollars/1)", %{
    session: session,
    mission: mission,
    store: store
  } do
    {:ok, _} =
      Usage.record(store, %{
        mission_id: mission.id,
        task_id: "task_1",
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "call_1",
        raw_payload: %{},
        input_tokens: 100,
        output_tokens: 10,
        cache_read_tokens: 0,
        cache_write_tokens: 0,
        cost: Decimal.new("0.000676"),
        coverage: "reported",
        pricing_version: "test-1",
        started_at: nil,
        first_token_at: nil,
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    lines = ExitSummary.lines(session.id, store)
    assert Enum.any?(lines, &(&1 =~ "cost: <$0.01"))
    refute Enum.any?(lines, &(&1 =~ "cost: $0.00"))
  end

  # docs/spec-v1.md §19 "print where the export is or how to make one" —
  # the exit hint must never promise a bundle `/export` would then refuse
  # to write (Sprat.Export.preview/2 is the single source of truth both
  # this hint and /export's own classify/2 read).
  test "a mission with nothing delivered yet: the hint says how to make one, not where it is",
       %{session: session, store: store} do
    lines = ExitSummary.lines(session.id, store)
    assert Enum.any?(lines, &(&1 =~ "still running"))
    refute Enum.any?(lines, &(&1 =~ "sprat-export/"))
  end

  test "a delivered mission: the hint names the real export path", %{
    session: session,
    mission: mission,
    store: store
  } do
    Sprat.Store.Artifacts.write(store, mission.id, %{
      type: :validation_plan,
      owning_role: "researcher",
      content: %{"experiments" => [%{"assumption" => "x"}]},
      created_by: "researcher"
    })

    lines = ExitSummary.lines(session.id, store)
    assert Enum.any?(lines, &(&1 =~ "sprat-export/#{mission.id}/"))
  end
end
