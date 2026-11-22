defmodule Sprat.ReplayOrchestratorTest do
  @moduledoc """
  Drives the real `Sprat.Orchestrator` (and everything underneath it —
  `Sprat.Agent.Loop`, gates, `Sprat.Store`, `Sprat.Workflow.ArtifactSchema`)
  offline, with zero live network or model calls.

  Two things proven here, honestly scoped apart:

    1. `Sprat.Model.Replay` really does drive a real mission's recorded
       Intake stage through the real Orchestrator with structurally
       guaranteed zero network egress (`network_disabled: true`) — a real
       recorded fixture (`mis_EUlIEBaOwFUh`), not a hand-written script.
    2. A full idea-shaping mission (Intake → Research → Analysis →
       Directions → [user choice] → Recommendation → Delivery) survives
       the EXACT field-name drift shapes real live runs hit (`findings`/
       `practical_findings` for `claims`, `entries` for `sources`,
       `risk_rating` for `risk`, `target_customer`/`pain_point`/
       `value_prop`/`validation` for a direction's fields, `hypothesis`
       for an experiment's `assumption`) and reaches Delivery with every
       artifact accepted.

  (2) is NOT a real recorded mission — no mission in the owner's database
  ever reached Directions with real Research/Analysis content (confirmed
  by querying every mission from 2026-09-18 through 2026-09-22; the one
  mission that did reach a completed Directions stage,
  `mis_1QkZiQVpLrYt`, got there only because its Research and Analysis
  stages were SKIPPED after failing live, not because they produced real
  content — so it proves nothing about the schema fix). This test's
  turns are hand-written, `Sprat.StubModel`-style (see
  `test/support/stub_model.ex`), using the exact field-name shapes pulled
  from the three real fixtures' rejected `write_artifact` calls — see
  `Sprat.ReplayMissionsTest` for where each shape came from. That is
  disclosed here explicitly rather than presented as a real replay: it
  proves the FIX behaves correctly end-to-end against these shapes: it
  does not prove a live model would have produced this exact sequence of
  turns.

  What full real-fixture replay through Research/Analysis independently
  could NOT prove offline, and why it isn't attempted here: `record_source`
  and `record_claim` generate fresh ids on every real call (`Sprat.Store.Sources`/
  `Sprat.Store.Claims`), so a recorded `research_memo` or `record_claim`
  call citing the LIVE run's exact source id has no way to resolve against
  a replayed run's freshly-generated one — a structural id-continuity gap
  in "replay the model, run real side effects" that is unrelated to the
  schema/stall defect class this branch fixes. Fixing it (e.g. having
  tools accept a replay-supplied id) would mean rewriting recorded tool
  call arguments before executing them — closer to "shortcutting the
  tools" than the build brief's "only the HTTP call to the model is
  replaced." `Sprat.ReplayMissionsTest` reproduces the three named live
  failures directly instead, at the validator/tool layer, with zero id
  dependency.
  """

  use Sprat.StoreCase, async: false

  alias Sprat.Model.Replay
  alias Sprat.Orchestrator
  alias Sprat.Session
  alias Sprat.Store.{Artifacts, Missions, Sessions, Sources, Tasks}
  alias Sprat.Workflow.Idea

  defp catalog(model_id) do
    %Sprat.Model.Pricing{
      version: 1,
      provider: "stub",
      effective_date: "2026-01-01",
      source: "test fixture",
      models: [
        %{
          id: model_id,
          supports_tools: true,
          supports_streaming: true,
          context_window: 200_000,
          price: %{
            input: Decimal.new("1.00"),
            cached_input: Decimal.new("0.50"),
            output: Decimal.new("2.00")
          }
        }
      ]
    }
  end

  defp wait_until(fun, tries \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end

  defp auto_answer_recovery(session_id, choice) do
    Task.start(fn ->
      wait_until(fn -> Session.snapshot(session_id).live.permission != nil end)
      Session.answer_permission(session_id, choice)
    end)
  end

  test "mis_EUlIEBaOwFUh's real recorded Intake replays through the real Orchestrator with zero network egress",
       %{store: store} do
    model_id = "replay-eulieb-intake"
    {:ok, meta} = Replay.load("mis_EUlIEBaOwFUh", model_id)
    {:ok, session} = Sessions.create(store)
    {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
    start_supervised!({Sprat.Budget, name: :"budget_#{session.id}", store: store})

    auto_answer_recovery(session.id, 2)

    :ok =
      Orchestrator.start(session.id, meta["objective"], Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: Replay,
        model_id: model_id,
        api_key: "test-key",
        catalog: catalog(model_id),
        # The structural zero-network guarantee (see
        # `Sprat.Agent.Tools.WebFetch`'s `network_disabled` check): even
        # though this mission's recorded Research stage calls web_fetch,
        # no request ever reaches a real socket.
        network_disabled: true,
        replay_fetch_lookup: fn url -> Replay.fetch_result(model_id, url) end,
        replay_search_lookup: fn query -> Replay.search_result(model_id, query) end,
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
    assert intake_task.status == "completed"
    assert Artifacts.latest(store, mission.id, :intake_summary)["objective"] != nil
  end

  # -- synthesized full idea-shaping run: the field-synonym drift shapes,
  # exactly as recorded, all the way to Delivery -----------------------

  defp write_artifact_call(id, type, content),
    do: %{id: id, name: "write_artifact", arguments: %{"type" => type, "content" => content}}

  defp tool_call_turn(tool_calls),
    do: %{
      "request" => nil,
      "response" =>
        encode(%{content: nil, tool_calls: tool_calls, stop_reason: "tool_calls", usage: %{}})
    }

  defp final_turn(text),
    do: %{
      "request" => nil,
      "response" => encode(%{content: text, tool_calls: [], stop_reason: "stop", usage: %{}})
    }

  # `exchanges.json`'s on-disk shape is JSON (string-keyed, string tool
  # names/ids) — round-tripping through `JSON.encode!/decode!` here
  # reuses `Sprat.Model.Replay`'s real decode path instead of hand-building
  # its atom-keyed internal shape, so this test exercises exactly what a
  # real exported fixture would.
  defp encode(response), do: response |> JSON.encode!() |> JSON.decode!()

  test "a mission using every observed field-name drift shape (findings/entries/risk_rating/target_customer/hypothesis) reaches Delivery",
       %{store: store} do
    model_id = "replay-synonym-drift-#{System.unique_integer([:positive])}"

    turns = [
      tool_call_turn([
        write_artifact_call("call_intake", "intake_summary", %{
          "objective" => "gym booking software",
          "depth" => "quick",
          "open_questions" => ["none"]
        })
      ]),
      final_turn("Intake done."),
      # research_memo: `findings` instead of `claims`, no `limitations` —
      # rejected for real at first (mis_EUlIEBaOwFUh's exact shape),
      # accepted on the SAME turn's retry inside this stage once the
      # actionable error names what's missing.
      tool_call_turn([
        write_artifact_call("call_research_bad", "research_memo", %{
          "summary" => "Existing gym booking tools are clunky.",
          "findings" => [%{"text" => "users want fewer taps", "is_assumption" => true}]
        })
      ]),
      tool_call_turn([
        write_artifact_call("call_research_fixed", "research_memo", %{
          "summary" => "Existing gym booking tools are clunky.",
          "findings" => [%{"text" => "users want fewer taps", "is_assumption" => true}],
          "gaps" => "no live web search available"
        }),
        write_artifact_call("call_sources", "source_register", %{
          "entries" => [
            %{"title" => "competitor app store page", "url" => "https://example.com/app"}
          ]
        })
      ]),
      final_turn("Research done."),
      tool_call_turn([
        write_artifact_call("call_assumptions", "assumption_register", %{
          "assumptions" => [%{"text" => "users will pay monthly", "risk_rating" => "high"}]
        })
      ]),
      final_turn("Analysis done."),
      tool_call_turn([
        write_artifact_call("call_directions", "product_directions", %{
          "directions" => [
            %{
              "target_customer" => "small gym owners",
              "pain_point" => "manual booking spreadsheets",
              "value_prop" => "fewer no-shows",
              "mvp_scope" => "single-location booking calendar",
              "validation" => "5 pilot gyms for 2 weeks"
            }
          ]
        })
      ]),
      final_turn("Directions ready."),
      tool_call_turn([
        write_artifact_call("call_recommendation", "recommendation_memo", %{
          "decision" => "go",
          "sources" => ["src_test_1"],
          "risks" => "limited to a single location for the pilot"
        })
      ]),
      final_turn("Recommendation done."),
      tool_call_turn([
        write_artifact_call("call_brief", "product_brief", %{
          "problem_statement" => "manual booking spreadsheets",
          "target_customer" => "small gym owners",
          "scope" => "single-location booking calendar"
        }),
        write_artifact_call("call_validation_plan", "validation_plan", %{
          "experiments" => [
            %{
              "hypothesis" => "users will pay monthly",
              "participants" => "5 pilot gyms",
              "approach" => "in-app trial",
              "budget" => "$500",
              "duration" => "2 weeks",
              "success_criteria" => "3 of 5 gyms convert",
              "failure_criteria" => "0 of 5 gyms convert",
              "next_step" => "scale or pivot"
            }
          ]
        })
      ]),
      final_turn("Delivery done.")
    ]

    :ok = Replay.load_turns(model_id, turns)

    {:ok, session} = Sessions.create(store)
    {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
    start_supervised!({Sprat.Budget, name: :"budget_#{session.id}", store: store})

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: Replay,
        model_id: model_id,
        api_key: "test-key",
        catalog: catalog(model_id),
        network_disabled: true,
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)

    {:ok, _} =
      Sources.record(store, mission.id, %{
        id: "src_test_1",
        url: "https://example.com/gym-app",
        source_type: "independent_reporting"
      })

    :ok = Orchestrator.user_choice(session.id, "combine and proceed")

    tasks = Tasks.by_mission(store, mission.id)
    assert Enum.find(tasks, &(&1.objective =~ "Research")).status == "completed"
    assert Enum.find(tasks, &(&1.objective =~ "Analysis")).status == "completed"
    assert Enum.find(tasks, &(&1.objective =~ "Recommendation")).status == "completed"
    assert Enum.find(tasks, &(&1.objective =~ "Brief")).status == "completed"

    assert Artifacts.latest(store, mission.id, :research_memo)["claims"] != nil
    assert Artifacts.latest(store, mission.id, :source_register)["sources"] != nil
    assert Artifacts.latest(store, mission.id, :assumption_register)["assumptions"] != nil
    assert Artifacts.latest(store, mission.id, :product_directions)["directions"] != nil
    assert Artifacts.latest(store, mission.id, :recommendation_memo)["recommendation"] == "go"
    assert Artifacts.latest(store, mission.id, :product_brief)["problem"] != nil
    assert Artifacts.latest(store, mission.id, :validation_plan)["experiments"] != nil

    %{blocks: blocks} = Session.snapshot(session.id)
    assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Mission delivered"))
  end
end
