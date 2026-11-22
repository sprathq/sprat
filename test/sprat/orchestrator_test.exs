defmodule Sprat.OrchestratorTest.SlowStubModel do
  @moduledoc "Wraps `Sprat.StubModel` with a small artificial delay per turn, mirroring `Sprat.Mission.SlowStubModel` — gives a steering test a real window to queue a message mid-run without racing a real HTTP call."
  @behaviour Sprat.Model

  @impl true
  def capabilities(model_id), do: Sprat.StubModel.capabilities(model_id)
  @impl true
  def complete(request, opts), do: Sprat.StubModel.complete(request, opts)

  @impl true
  def stream(request, opts) do
    Process.sleep(60)
    Sprat.StubModel.stream(request, opts)
  end

  @impl true
  def normalize_usage(raw, context), do: Sprat.StubModel.normalize_usage(raw, context)
end

defmodule Sprat.OrchestratorTest do
  # async: false — Orchestrator tests share `:persistent_term` active/cancel
  # keys per session id; each test still uses its own unique session id
  # (via StoreCase's fresh store/session per test), but the module keeps
  # this off async to avoid any doubt about `:persistent_term` interference
  # between tests, matching the plan's corrected guidance for this task.
  use Sprat.StoreCase, async: false

  alias Sprat.Orchestrator
  alias Sprat.Session
  alias Sprat.Store.{Artifacts, Grants, Missions, Sessions, Sources, Tasks}
  alias Sprat.Workflow.Idea

  # Sprat.Agent.Loop refuses to run against a model id with no priced
  # catalog entry (`:price_unknown`) — a real catalog obviously has no
  # entry for a stub model id, so every orchestrator test needs its own
  # one-model catalog, same as loop_test.exs/mission_test.exs.
  defp stub_catalog(model_id) do
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
          context_window: 100_000,
          price: %{
            input: Decimal.new("1.00"),
            cached_input: Decimal.new("0.50"),
            output: Decimal.new("2.00")
          }
        }
      ]
    }
  end

  setup %{store: store} do
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
    {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
    start_supervised!({Sprat.Budget, name: :"budget_#{session.id}", store: store})
    %{store: store, session: session}
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

  # A terminal stage failure now blocks on `Session.await_permission/2`
  # (the retry/skip/abandon recovery prompt — see
  # `Sprat.Orchestrator.offer_recovery/12`). A `sync?: true` run blocks the
  # calling test process itself inside that call, so answering it has to
  # happen from a second process, started before the blocking call.
  defp auto_answer_recovery(session_id, choice) do
    Task.start(fn ->
      wait_until(fn -> Session.snapshot(session_id).live.permission != nil end)
      Session.answer_permission(session_id, choice)
    end)
  end

  test "runs Intake, Research, Analysis and Directions with a scripted model, then stops for the user-choice point",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    tasks = Tasks.by_mission(store, mission.id)

    assert length(tasks) == 4
    assert Enum.map(tasks, & &1.role) |> Enum.all?(&(&1 == "researcher"))
    assert Enum.all?(tasks, &(&1.status == "completed"))
    refute Enum.any?(tasks, &(&1.objective =~ "Recommendation"))
    refute Enum.any?(tasks, &(&1.objective =~ "Brief + validation plan"))

    assert Artifacts.latest(store, mission.id, :intake_summary)
    assert Artifacts.latest(store, mission.id, :research_memo)
    assert Artifacts.latest(store, mission.id, :assumption_register)
    assert Artifacts.latest(store, mission.id, :product_directions)

    %{blocks: blocks} = Session.snapshot(session.id)
    assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Directions ready"))
  end

  # Defect backlog item 5 ("approval fatigue"): a real event-log count
  # found composed (non-search) fetches concentrated on a handful of
  # documentation/package hosts the model guessed a plausible-looking
  # path for instead of searching — `search_note/1`'s existing "do not
  # guess or compose URLs from memory" sentence wasn't stopping it. This
  # proves the strengthened guidance actually reaches the model (the
  # system message every stage's request carries), not just that the
  # source file contains the words.
  test "the research role prompt tells the model to search doc/package sites instead of guessing their URLs",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        # `search_note/1`'s hex.pm/hexdocs.pm guidance only appears in the
        # `true` (search-enabled) branch — `search_enabled?/2` requires a
        # non-empty `search_model` too, not just an api_key.
        search_model: "stub-search-model",
        sync?: true
      )

    %{messages: [%{"role" => "system", "content" => instructions} | _]} =
      Sprat.StubModel.last_request("stub-idea-delivery")

    assert instructions =~ "do not guess or compose URLs from memory"
    assert instructions =~ "hex.pm"
    assert instructions =~ "Search for the exact page instead"
  end

  test "each stage transition broadcasts the full checklist with real per-stage status",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()
    Sprat.Session.PubSub.subscribe(session.id)

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)

    {:ok, _} =
      Sources.record(store, mission.id, %{
        id: "src_test_1",
        url: "https://example.com/gym-app",
        source_type: "independent_reporting"
      })

    :ok = Orchestrator.user_choice(session.id, "combine direction 1 and 2, web only")

    checklists =
      Stream.repeatedly(fn ->
        receive do
          msg -> msg
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(not is_nil(&1)))
      |> Enum.filter(&match?({:sprat_session, _, {:live_updated, %{checklist: _}}}, &1))

    assert length(checklists) >= 6

    {:sprat_session, _, {:live_updated, %{checklist: %{stages: stages}}}} = List.last(checklists)

    assert Enum.map(stages, &elem(&1, 0)) == [
             "Intake",
             "Research",
             "Analysis",
             "Directions",
             "Recommendation",
             "Brief + validation plan"
           ]

    assert Enum.all?(stages, fn {_label, status} -> status in [:done, :active, :queued] end)

    # The Directions stage genuinely pauses mid-walk (§ the "Directions
    # choice point" UI defect) — one of the checklist snapshots taken
    # while it's paused must show it as :waiting_on_user, distinct from
    # :active's spinner, or a user watching only the checklist can't tell
    # a real pause from the stage still thinking.
    assert Enum.any?(checklists, fn {:sprat_session, _,
                                     {:live_updated, %{checklist: %{stages: s}}}} ->
             {"Directions", :waiting_on_user} in s
           end)
  end

  test "the Directions stage stops for user_choice, then resumes into Recommendation with the answer",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    tasks_before = Tasks.by_mission(store, mission.id)
    directions_task = Enum.find(tasks_before, &(&1.objective =~ "Directions"))
    assert directions_task.status == "completed"
    recommendation_task = Enum.find(tasks_before, &(&1.objective =~ "Recommendation"))
    assert is_nil(recommendation_task)

    # Recommendation's gate requires its evidence to cite a source id that
    # actually exists (Sprat.Workflow.Gate.check/3's
    # :recommendation_to_delivery) — the stub script's recommendation_memo
    # cites "src_test_1", so it must exist before resuming.
    {:ok, _} =
      Sources.record(store, mission.id, %{
        id: "src_test_1",
        url: "https://example.com/gym-app",
        source_type: "independent_reporting"
      })

    :ok = Orchestrator.user_choice(session.id, "combine direction 1 and 2, web only")

    tasks_after = Tasks.by_mission(store, mission.id)
    assert Enum.find(tasks_after, &(&1.objective =~ "Recommendation")).status == "completed"

    assert Enum.find(tasks_after, &(&1.objective =~ "Brief + validation plan")).status ==
             "completed"

    decisions = Sprat.Store.Decisions.by_mission(store, mission.id)
    assert Enum.any?(decisions, &(&1.summary =~ "combine direction 1 and 2, web only"))
  end

  test "a gate failure produces changes_requested and a bounded retry, then surfaces to the user",
       %{
         store: store,
         session: session
       } do
    model = Sprat.StubModel.always_writes_invalid_research_memo()
    auto_answer_recovery(session.id, 2)

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-invalid-research",
        api_key: "test-key",
        catalog: stub_catalog("stub-invalid-research"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)

    research_task =
      Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Research"))

    # review_rounds default is 1 (§8 scheduling defaults) -> attempt caps at 2
    assert research_task.attempt <= 2
    assert research_task.status in ["failed", "needs_input"]

    # A retry that still has bounded attempts left must not render the
    # alarming "✗ ... gate failed" block — only a calmer "another pass"
    # notice. The ✗ treatment belongs solely to the final, exhausted-retries
    # failure (folded into the give-up system message).
    %{blocks: blocks} = Session.snapshot(session.id)
    system_texts = blocks |> Enum.filter(&(&1.kind == :system)) |> Enum.map(& &1.text)

    assert Enum.any?(system_texts, &(&1 =~ "↻ Research needs another pass"))
    refute Enum.any?(system_texts, &(&1 =~ "✗ Research gate failed"))
    assert Enum.any?(system_texts, &(&1 =~ "✗ Research could not pass its gate after"))
  end

  test "a stage that makes 3 consecutive turns with no new source, artifact or state progress is stopped as stalled",
       %{store: store, session: session} do
    model = Sprat.StubModel.always_chats_without_progress()
    auto_answer_recovery(session.id, 2)

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-no-progress",
        api_key: "test-key",
        catalog: stub_catalog("stub-no-progress"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    [intake_task] = Tasks.by_mission(store, mission.id)

    assert intake_task.status == "failed"

    events = Sprat.Store.Events.by_session(store, session.id, limit: 1000)
    assert Enum.any?(events, &(&1.type == "task.stalled"))

    %{blocks: blocks} = Session.snapshot(session.id)
    assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "stalled"))
  end

  test "a delivered mission reaches completed, and a skipped stage is named in the reason",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        sync?: true
      )

    [mission_before] = Missions.by_session(store, session.id)

    # The Recommendation gate wants its evidence to resolve to real sources.
    {:ok, _} =
      Sources.record(store, mission_before.id, %{
        id: "src_test_1",
        url: "https://example.com/gym-app",
        source_type: "independent_reporting"
      })

    # The idea workflow pauses at Directions for the user to choose; the
    # mission is only delivered once the last two stages have run.
    :ok = Orchestrator.user_choice(session.id, "direction 2, web only")

    [mission] = Missions.by_session(store, session.id)

    # MissionState had a `completed` state from the day it was written and
    # nothing ever transitioned into it, so every delivered mission stayed
    # `active` and /export had to infer delivery from the artifacts.
    assert Missions.get(store, mission.id).status == "completed"

    transition =
      store
      |> Sprat.Store.Events.by_mission(mission.id)
      |> Enum.filter(&(&1.type == "mission.transitioned"))
      |> List.last()

    assert transition.payload =~ "completed"
    assert transition.payload =~ "all stages delivered"
  end

  test "budget exhaustion mid-workflow fails the task and pauses the mission at paused_budget",
       %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()
    auto_answer_recovery(session.id, 2)

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-idea-delivery",
        api_key: "test-key",
        catalog: stub_catalog("stub-idea-delivery"),
        # Near-zero rather than exactly zero: `Sprat.Budget.status/2`
        # divides `spent / cap` for `percent_used`, and a literal
        # `Decimal.new("0.00")` cap raises `Decimal.Error` (0/0) on the
        # very first `broadcast_budget/4` call, before the reservation
        # this test means to exercise ever runs.
        budget_cap: Decimal.new("0.0001"),
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    [intake_task] = Tasks.by_mission(store, mission.id)

    assert intake_task.status == "failed"

    # The budget pause is recorded as a transition; this test then answers the
    # recovery prompt with "abandon" (auto_answer_recovery(.., 2)), so the
    # mission's final state is cancelled. Before missions had a terminal
    # state at all, it simply stayed paused_budget forever.
    assert Enum.any?(
             Sprat.Store.Events.by_mission(store, mission.id),
             &(&1.type == "mission.transitioned" and &1.payload =~ "paused_budget")
           )

    assert Missions.get(store, mission.id).status == "cancelled"

    %{blocks: blocks} = Session.snapshot(session.id)

    assert Enum.any?(
             blocks,
             &(&1.kind == :system and &1.text =~ "Mission paused (budget)")
           )
  end

  describe "fetch approval (§9)" do
    # Each test uses its own model_id — the Idea `:quick` template
    # auto-advances Intake straight through Research/Analysis/Directions
    # (see `Sprat.StubModel.needs_fetch_approval/2`'s doc), so a shared,
    # globally-named stub model script would race a concurrent test still
    # draining its own.
    defp unique_model_id, do: "stub-needs-approval-#{System.unique_integer([:positive])}"

    defp directions_ready?(session_id) do
      %{blocks: blocks} = Session.snapshot(session_id)
      Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Directions ready"))
    end

    # Every `%{checklist: %{stages: _}}` `:live_updated` broadcast
    # currently sitting in this process's mailbox, oldest first — a
    # non-blocking drain (mirrors the "each stage transition..." test's
    # own `Stream.repeatedly`/`after 0` drain above) so a caller can poll
    # for one it's waiting on without an earlier, still-stale broadcast
    # (e.g. the stage's own `:active` announce) satisfying `assert_receive`
    # first.
    defp drain_checklists do
      Stream.repeatedly(fn ->
        receive do
          msg -> msg
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&(not is_nil(&1)))
      |> Enum.flat_map(fn
        {:sprat_session, _, {:live_updated, %{checklist: %{stages: stages}}}} -> [stages]
        _ -> []
      end)
    end

    test "a fetch that needs approval pauses the stage (task stays running, UI shows waiting-on-user) instead of failing it",
         %{store: store, session: session} do
      model_id = unique_model_id()
      model = Sprat.StubModel.needs_fetch_approval("https://example.com/x", model_id)
      Sprat.Session.PubSub.subscribe(session.id)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: false
        )

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)

      assert_receive {:sprat_session, _,
                      {:agents_updated, %{agents: [%{state: :waiting_on_user}]}}}

      # Same UI defect as the checklist test above: a fetch-approval pause
      # must move the paused stage's checklist entry to :waiting_on_user
      # too, not leave it on :active's spinner. `announce_stage/5`'s own
      # `:active` checklist broadcast is still sitting ahead of it in the
      # mailbox, so drain rather than assert on just the next message.
      assert wait_until(fn ->
               Enum.any?(drain_checklists(), fn stages ->
                 {"Intake", :waiting_on_user} in stages
               end)
             end)

      [mission] = Missions.by_session(store, session.id)
      [intake_task] = Tasks.by_mission(store, mission.id)
      assert intake_task.status == "running"

      # answer so the background run settles before the test (and its
      # ephemeral store) tears down
      :ok = Session.answer_permission(session.id, 0)
      assert wait_until(fn -> directions_ready?(session.id) end)
    end

    test "approving resumes the same stage and lets it complete normally", %{
      store: store,
      session: session
    } do
      model_id = unique_model_id()
      model = Sprat.StubModel.needs_fetch_approval("https://example.com/x", model_id)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: false
        )

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      assert Session.snapshot(session.id).live.permission.title == "Fetch URL"
      :ok = Session.answer_permission(session.id, 0)

      assert wait_until(fn -> directions_ready?(session.id) end)

      [mission] = Missions.by_session(store, session.id)
      intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
      assert intake_task.status == "completed"
      assert Artifacts.latest(store, mission.id, :intake_summary)

      assert [%{resource: "https://example.com/x", resource_scope: "url"}] =
               Grants.by_session(store, session.id)
    end

    test "denying doesn't fail the stage — the model sees a denial error and the stage still completes",
         %{store: store, session: session} do
      model_id = unique_model_id()
      model = Sprat.StubModel.needs_fetch_approval("https://example.com/x", model_id)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: false
        )

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      # option 2: "No"
      :ok = Session.answer_permission(session.id, 2)

      assert wait_until(fn -> directions_ready?(session.id) end)

      [mission] = Missions.by_session(store, session.id)
      intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
      assert intake_task.status == "completed"
      assert Artifacts.latest(store, mission.id, :intake_summary)
      # denied, not approved — no grant recorded
      assert Grants.by_session(store, session.id) == []
    end

    test "a URL literally present in the mission's own submitted text is auto-approved, never prompted",
         %{store: store, session: session} do
      url = "https://user-pasted.example/page"
      model_id = unique_model_id()
      model = Sprat.StubModel.needs_fetch_approval(url, model_id)

      :ok =
        Orchestrator.start(
          session.id,
          "gym booking software — see #{url}",
          Idea,
          :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: true
        )

      [mission] = Missions.by_session(store, session.id)
      intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
      assert intake_task.status == "completed"
      assert Artifacts.latest(store, mission.id, :intake_summary)

      # never prompted, never granted — the URL was already user-supplied
      refute Session.snapshot(session.id).live.permission
      assert Grants.by_session(store, session.id) == []
    end
  end

  describe "recovery prompt after a terminal stage failure" do
    test "the checklist re-broadcasts the failed stage as :failed instead of staying stuck on :active",
         %{store: store, session: session} do
      model = Sprat.StubModel.stalls_intake_then_recovers()
      Sprat.Session.PubSub.subscribe(session.id)
      auto_answer_recovery(session.id, 2)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-stall-then-recover",
          api_key: "test-key",
          catalog: stub_catalog("stub-stall-then-recover"),
          sync?: true
        )

      checklists =
        Stream.repeatedly(fn ->
          receive do
            msg -> msg
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(not is_nil(&1)))
        |> Enum.filter(
          &match?({:sprat_session, _, {:live_updated, %{checklist: %{stages: _}}}}, &1)
        )
        |> Enum.map(fn {:sprat_session, _, {:live_updated, %{checklist: %{stages: stages}}}} ->
          stages
        end)

      assert Enum.any?(checklists, fn stages ->
               Enum.find(stages, &(elem(&1, 0) == "Intake")) == {"Intake", :failed}
             end)
    end

    test "retry creates a fresh task for the same stage and lets it succeed", %{
      store: store,
      session: session
    } do
      model = Sprat.StubModel.retry_recovers_research_stage()
      auto_answer_recovery(session.id, 0)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-retry-recovers",
          api_key: "test-key",
          catalog: stub_catalog("stub-retry-recovers"),
          sync?: true
        )

      [mission] = Missions.by_session(store, session.id)

      research_tasks =
        Tasks.by_mission(store, mission.id) |> Enum.filter(&(&1.objective =~ "Research"))

      assert length(research_tasks) == 2
      assert Enum.any?(research_tasks, &(&1.status == "failed"))
      assert Enum.any?(research_tasks, &(&1.status == "completed"))

      %{blocks: blocks} = Session.snapshot(session.id)
      system_texts = blocks |> Enum.filter(&(&1.kind == :system)) |> Enum.map(& &1.text)
      assert Enum.any?(system_texts, &(&1 =~ "Retrying Research from scratch"))
      assert Enum.any?(system_texts, &(&1 =~ "Directions ready"))
    end

    test "skip writes incomplete deliverables for the failed stage and advances to the next one",
         %{store: store, session: session} do
      model = Sprat.StubModel.stalls_intake_then_recovers()
      auto_answer_recovery(session.id, 1)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-stall-then-recover",
          api_key: "test-key",
          catalog: stub_catalog("stub-stall-then-recover"),
          sync?: true
        )

      [mission] = Missions.by_session(store, session.id)

      assert Artifacts.latest(store, mission.id, :intake_summary) == %{
               "incomplete" => true,
               "reason" => "user skipped after a failure"
             }

      intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
      assert intake_task.status == "failed"

      %{blocks: blocks} = Session.snapshot(session.id)
      system_texts = blocks |> Enum.filter(&(&1.kind == :system)) |> Enum.map(& &1.text)
      assert Enum.any?(system_texts, &(&1 =~ "Skipped Intake"))
      assert Enum.any?(system_texts, &(&1 =~ "Directions ready"))
    end

    test "the checklist renders a skipped stage as :skipped, not :done — a later stage still renders correctly",
         %{store: store, session: session} do
      model = Sprat.StubModel.stalls_intake_then_recovers()
      Sprat.Session.PubSub.subscribe(session.id)
      auto_answer_recovery(session.id, 1)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-stall-then-recover",
          api_key: "test-key",
          catalog: stub_catalog("stub-stall-then-recover"),
          sync?: true
        )

      checklists =
        Stream.repeatedly(fn ->
          receive do
            msg -> msg
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(not is_nil(&1)))
        |> Enum.filter(
          &match?({:sprat_session, _, {:live_updated, %{checklist: %{stages: _}}}}, &1)
        )
        |> Enum.map(fn {:sprat_session, _, {:live_updated, %{checklist: %{stages: stages}}}} ->
          stages
        end)

      # After the skip, every later checklist broadcast (Research's own
      # :active announce, Analysis's, Directions') must keep showing Intake
      # as :skipped — never :done, and never reverting to :queued either.
      post_skip_checklists =
        Enum.drop_while(checklists, fn stages ->
          Enum.find(stages, &(elem(&1, 0) == "Intake")) != {"Intake", :skipped}
        end)

      assert post_skip_checklists != []

      assert Enum.all?(post_skip_checklists, fn stages ->
               Enum.find(stages, &(elem(&1, 0) == "Intake")) == {"Intake", :skipped}
             end)

      # Research — the stage right after the skip — still renders honestly
      # relative to it: :active while running, then :done once its own
      # gate passes, never inheriting Intake's :skipped status.
      last_stages = List.last(post_skip_checklists)
      {_label, research_status} = Enum.find(last_stages, &(elem(&1, 0) == "Research"))
      assert research_status in [:active, :done]
    end

    test "the final message names the skip instead of claiming a clean delivery",
         %{store: store, session: session} do
      model = Sprat.StubModel.stalls_intake_then_skips_to_delivery()
      auto_answer_recovery(session.id, 1)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-skip-then-deliver",
          api_key: "test-key",
          catalog: stub_catalog("stub-skip-then-deliver"),
          sync?: true
        )

      [mission] = Missions.by_session(store, session.id)

      {:ok, _} =
        Sources.record(store, mission.id, %{
          id: "src_test_1",
          url: "https://example.com/gym-app",
          source_type: "independent_reporting"
        })

      :ok = Orchestrator.user_choice(session.id, "combine direction 1 and 2, web only")

      %{blocks: blocks} = Session.snapshot(session.id)
      system_texts = blocks |> Enum.filter(&(&1.kind == :system)) |> Enum.map(& &1.text)

      refute Enum.any?(
               system_texts,
               &(&1 ==
                   "Mission delivered — all stages complete. Run /artifacts to see what was produced.")
             )

      assert Enum.any?(
               system_texts,
               &(&1 =~
                   "Mission delivered, but 1 stage(s) were skipped with incomplete deliverables")
             )
    end

    test "abandon posts a final message and does not advance or retry", %{
      store: store,
      session: session
    } do
      model = Sprat.StubModel.stalls_intake_then_recovers()
      auto_answer_recovery(session.id, 2)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: model,
          model_id: "stub-stall-then-recover",
          api_key: "test-key",
          catalog: stub_catalog("stub-stall-then-recover"),
          sync?: true
        )

      [mission] = Missions.by_session(store, session.id)
      tasks = Tasks.by_mission(store, mission.id)

      assert length(tasks) == 1
      refute Artifacts.latest(store, mission.id, :intake_summary)

      %{blocks: blocks} = Session.snapshot(session.id)
      system_texts = blocks |> Enum.filter(&(&1.kind == :system)) |> Enum.map(& &1.text)
      assert Enum.any?(system_texts, &(&1 =~ "Mission abandoned after Intake failed"))
      refute Enum.any?(system_texts, &(&1 =~ "Directions ready"))
    end
  end

  # -- mid-mission steering (docs/spec-v1.md §10) --------------------------

  describe "mid-mission steering" do
    defp intake_task(store, mission_id),
      do: Tasks.by_mission(store, mission_id) |> Enum.find(&(&1.objective =~ "Intake"))

    # A dedicated, uniquely-id'd Intake -> Research -> Analysis ->
    # Directions script (content identical to
    # `Sprat.StubModel.scripted_for_idea_delivery/0`'s), rather than
    # reusing that helper's own hardcoded `"stub-idea-delivery"` id —
    # this describe block's tests would otherwise share that name with
    # `Sprat.Session.CommandsTest`'s own `/idea` test, and two
    # `Agent.start_link/2` calls under the same name racing that test's
    # linked-Agent teardown is exactly the kind of cross-file flake
    # `unique_model_id/0` above was already written to avoid for the
    # fetch-approval describe block.
    defp script_idea_delivery(model_id) do
      {:ok, _} =
        Sprat.StubModel.start_script(model_id, [
          %{
            content: nil,
            tool_calls: [
              %{
                id: "call_intake",
                name: "write_artifact",
                arguments: %{
                  "type" => "intake_summary",
                  "content" => %{
                    "objective" => "gym booking software",
                    "depth" => "quick",
                    "open_questions" => ["none"]
                  }
                }
              }
            ],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{content: "Intake done.", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}},
          %{
            content: nil,
            tool_calls: [
              %{
                id: "call_research_memo",
                name: "write_artifact",
                arguments: %{
                  "type" => "research_memo",
                  "content" => %{
                    "summary" => "Existing gym booking tools are clunky.",
                    "claims" => [%{"text" => "users want fewer taps", "is_assumption" => true}],
                    "limitations" => "no live web search available"
                  }
                }
              },
              %{
                id: "call_source_register",
                name: "write_artifact",
                arguments: %{
                  "type" => "source_register",
                  "content" => %{
                    "sources" => [
                      %{
                        "title" => "competitor app store page",
                        "url" => "https://example.com/app"
                      }
                    ]
                  }
                }
              }
            ],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{content: "Research done.", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}},
          %{
            content: nil,
            tool_calls: [
              %{
                id: "call_assumptions",
                name: "write_artifact",
                arguments: %{
                  "type" => "assumption_register",
                  "content" => %{
                    "assumptions" => [%{"text" => "users will pay monthly", "risk" => "high"}]
                  }
                }
              }
            ],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{content: "Analysis done.", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}},
          %{
            content: nil,
            tool_calls: [
              %{
                id: "call_directions",
                name: "write_artifact",
                arguments: %{
                  "type" => "product_directions",
                  "content" => %{
                    "directions" => [
                      %{
                        "customer" => "small gym owners",
                        "problem" => "manual booking spreadsheets",
                        "value" => "fewer no-shows",
                        "scope" => "single-location booking calendar",
                        "validation_approach" => "5 pilot gyms for 2 weeks"
                      }
                    ]
                  }
                }
              }
            ],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{
            content: "Directions ready.",
            tool_calls: [],
            stop_reason: :stop,
            usage: %{},
            raw: %{}
          }
        ])

      :ok
    end

    test "a plain message sent while a staged mission runs is queued, not refused, marks " <>
           "existing artifacts stale, and carries into a later stage's context",
         %{store: store, session: session} do
      model_id = "stub-steering-#{System.unique_integer([:positive])}"
      :ok = script_idea_delivery(model_id)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: Sprat.OrchestratorTest.SlowStubModel,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: false
        )

      assert wait_until(fn ->
               case Missions.by_session(store, session.id) do
                 [m] -> match?(%{status: "completed"}, intake_task(store, m.id) || %{})
                 _ -> false
               end
             end)

      [mission] = Missions.by_session(store, session.id)
      assert Orchestrator.busy?(session.id)
      assert Orchestrator.active_mission_id(session.id) == mission.id
      assert Artifacts.latest(store, mission.id, :intake_summary)

      :ok = Sprat.Session.Commands.handle(session.id, store, "UK only")

      # accepted, not refused
      %{blocks: blocks} = Session.snapshot(session.id)
      refute Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Still running"))
      queued = Enum.find(blocks, &(&1.kind == :user_message and &1.text == "UK only"))
      assert queued
      assert queued.queued?

      # already-written artifacts are flagged stale
      assert Artifacts.stale_types(store, mission.id) == MapSet.new([:intake_summary])
      [intake_artifact] = Artifacts.by_mission(store, mission.id)
      assert intake_artifact.stale

      assert wait_until(fn -> directions_ready?(session.id) end)

      # Directions' own context package (built well after Intake, and
      # after the steering was delivered) still carries "UK only" forward.
      request = Sprat.StubModel.last_request(model_id)
      first_user_message = Enum.at(request.messages, 1)
      assert first_user_message["content"] =~ "UK only"

      events = Sprat.Store.Events.by_session(store, session.id)
      assert Enum.any?(events, &(&1.type == "steering.queued"))
      assert Enum.any?(events, &(&1.type == "steering.delivered"))
    end

    test "a plain message sent while the Directions choice is pending answers the choice, " <>
           "not the steering queue",
         %{store: store, session: session} do
      model_id = "stub-steering-#{System.unique_integer([:positive])}"
      :ok = script_idea_delivery(model_id)

      :ok =
        Orchestrator.start(session.id, "gym booking software", Idea, :quick,
          store: store,
          budget: :"budget_#{session.id}",
          model_mod: Sprat.StubModel,
          model_id: model_id,
          api_key: "test-key",
          catalog: stub_catalog(model_id),
          sync?: false
        )

      assert wait_until(fn -> Orchestrator.pending_choice?(session.id) end)
      [mission] = Missions.by_session(store, session.id)

      # The recommendation stage past Directions needs a pre-recorded
      # source (`Sprat.StubModel.scripted_for_idea_delivery/0`'s own doc)
      # — irrelevant to what this test checks (precedence, not delivery),
      # but recorded anyway so the resumed continuation doesn't hang the
      # test suite waiting forever on a recovery prompt nobody answers.
      {:ok, _} =
        Sprat.Store.Sources.record(store, mission.id, %{
          id: "src_test_1",
          url: "https://example.com/src",
          source_type: "web"
        })

      :ok = Sprat.Session.Commands.handle(session.id, store, "go with direction 1")

      assert Sprat.Store.SteeringMessages.by_mission(store, mission.id) == []
      assert wait_until(fn -> not Orchestrator.pending_choice?(session.id) end)
    end
  end
end
