defmodule Sprat.Agent.Tools.RecordClaimTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.{RecordClaim, RecordSource}
  alias Sprat.Store.Claims

  test "writes through Sprat.Store.Claims, linking supporting and contradicting source ids", %{
    store: store
  } do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    {:ok, %{"source_id" => supports_id}} =
      RecordSource.call(
        %{"url" => "https://a.example", "source_type" => "independent_reporting"},
        context
      )

    {:ok, %{"source_id" => contradicts_id}} =
      RecordSource.call(
        %{"url" => "https://b.example", "source_type" => "forum_or_review"},
        context
      )

    assert {:ok, %{"claim_id" => claim_id}} =
             RecordClaim.call(
               %{
                 "text" => "Most independent gyms manage bookings by phone and spreadsheet.",
                 "confidence" => "medium",
                 "justification" => "One direct report, no corroborating survey.",
                 "supporting_source_ids" => [supports_id],
                 "contradicting_source_ids" => [contradicts_id]
               },
               context
             )

    [claim] = Claims.by_mission(store, mission.id)
    assert claim.id == claim_id
    assert claim.confidence == "medium"
    assert claim.is_assumption == false
  end

  test "is_assumption: true is honoured for a claim with no supporting source", %{store: store} do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    {:ok, _} =
      RecordClaim.call(
        %{
          "text" => "The team assumes founders will pay $50/mo.",
          "confidence" => "low",
          "is_assumption" => true
        },
        context
      )

    [claim] = Claims.by_mission(store, mission.id)
    assert claim.is_assumption == true
  end

  test "a source id from another mission (or a bad/hallucinated one) fails cleanly instead of crashing",
       %{store: store} do
    {_session, mission, _task} = fixture_chain(store)
    context = %{store: store, mission_id: mission.id}

    # this id was never recorded for THIS mission — the real bug: a
    # model, given a source id in its context from an earlier mission's
    # conversation, cited it here and the resulting `claim_sources`
    # foreign-key violation raised a `MatchError` that crashed the whole
    # agent loop (`{:ok, claim} = Claims.record(...)`, see
    # `Sprat.Agent.Tools.RecordClaim`'s moduledoc history / the crash fix
    # in `Sprat.Agent.Loop.safe_tool_call/3`).
    assert {:error, message} =
             RecordClaim.call(
               %{
                 "text" => "Some claim.",
                 "confidence" => "low",
                 "supporting_source_ids" => ["src_does_not_exist"]
               },
               context
             )

    assert message =~ "source id"
    assert Claims.by_mission(store, mission.id) == []
  end

  test "rejects an invalid confidence" do
    assert {:error, message} =
             RecordClaim.call(%{"text" => "x", "confidence" => "certain"}, %{})

    assert message =~ "invalid confidence"
  end
end
