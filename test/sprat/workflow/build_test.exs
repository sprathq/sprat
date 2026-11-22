defmodule Sprat.Workflow.BuildTest do
  # async: false — same reasoning as Sprat.OrchestratorTest: shared
  # :persistent_term active/cancel/pending keys per session id.
  use Sprat.StoreCase, async: false

  alias Sprat.Orchestrator
  alias Sprat.Session
  alias Sprat.Store.{Artifacts, Missions, Runs, Sessions, Tasks}
  alias Sprat.Workflow.Build

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

  # A template shaped exactly like `Sprat.Workflow.Build`'s, with the
  # :scaffold stage's `executor` swapped for a controllable fake — lets
  # these tests exercise the real gate/checkpoint/advance wiring without
  # a live scaffold/server. `Sprat.Build.ScaffoldTest` covers the real
  # `Sprat.Build.Scaffold` module, including a real, non-faked scaffold.
  def template_with_fake_scaffold(depth, executor) do
    real = Build.template(depth)

    stages =
      Enum.map(real.stages, fn
        %{id: :scaffold} = s -> %{s | executor: executor}
        s -> s
      end)

    %{real | stages: stages}
  end

  defmodule FakeScaffoldSucceeds do
    def template(depth) do
      Sprat.Workflow.BuildTest.template_with_fake_scaffold(depth, fn mission,
                                                                     task,
                                                                     _design,
                                                                     opts ->
        store = Keyword.fetch!(opts, :store)

        for {purpose, cmd} <- [{"install", "mix"}, {"run", "mix"}, {"health_check", "GET"}] do
          Runs.record(store, %{
            mission_id: mission.id,
            task_id: task.id,
            command: cmd,
            args: [],
            cwd: "/tmp",
            exit_code: 0,
            duration_ms: 1,
            sandbox_strength: "partial",
            purpose: purpose
          })
        end

        :ok
      end)
    end
  end

  defmodule FakeScaffoldFailsHealthCheck do
    def template(depth) do
      Sprat.Workflow.BuildTest.template_with_fake_scaffold(depth, fn mission,
                                                                     task,
                                                                     _design,
                                                                     opts ->
        store = Keyword.fetch!(opts, :store)

        for {purpose, exit_code} <- [{"install", 0}, {"run", 0}, {"health_check", 1}] do
          {:ok, hash} = Sprat.Store.Blob.put("output for #{purpose}", [])

          Runs.record(store, %{
            mission_id: mission.id,
            task_id: task.id,
            command: "GET",
            args: ["/"],
            cwd: "/tmp",
            exit_code: exit_code,
            duration_ms: 1,
            output_blob_hash: hash,
            sandbox_strength: "partial",
            purpose: purpose
          })
        end

        {:error, :health_check_timeout}
      end)
    end
  end

  defp start_design(session, store, model_id, opts \\ []) do
    model = Sprat.StubModel.scripted_for_build_design(model_id, Keyword.get(opts, :attempts, 2))

    :ok =
      Orchestrator.start(
        session.id,
        "gym booking MVP",
        Keyword.get(opts, :template_mod, Build),
        :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: model_id,
        api_key: "test-key",
        catalog: stub_catalog(model_id),
        sync?: Keyword.get(opts, :sync?, true),
        seed_artifacts: [
          {:product_brief,
           %{"problem" => "manual booking", "customer" => "gym owners", "mvp_scope" => "booking"}}
        ]
      )

    if Keyword.get(opts, :sync?, true) do
      :ok
    else
      assert wait_until(fn -> Orchestrator.pending_choice?(session.id) end)
    end
  end

  test "the design stage writes a valid technical_design artifact and the gate passes",
       %{store: store, session: session} do
    start_design(session, store, "stub-build-1")

    [mission] = Missions.by_session(store, session.id)
    design = Artifacts.latest(store, mission.id, :technical_design)

    assert design["profile"] == "elixir-phoenix"
    assert design["data_model"]["entities"] != []
    assert design["excluded_scope"] != []

    task = store |> Tasks.by_mission(mission.id) |> hd()
    assert task.status == "completed"

    # Checkpoint 1 is reached (paused), not skipped past.
    assert Orchestrator.pending_choice?(session.id)
  end

  describe "checkpoint 1's three answers" do
    test "approve advances to Scaffold, which runs and the mission completes",
         %{store: store, session: session} do
      start_design(session, store, "stub-build-approve", template_mod: FakeScaffoldSucceeds)
      assert Orchestrator.pending_choice?(session.id)

      :ok = Orchestrator.user_choice(session.id, "approve")

      refute Orchestrator.pending_choice?(session.id)
      [mission] = Missions.by_session(store, session.id)
      assert mission.status == "completed"

      runs = Runs.by_mission(store, mission.id)
      assert Enum.any?(runs, &(&1.purpose == "health_check" and &1.exit_code == 0))
    end

    test "revise-with-instructions re-runs the design stage with the instructions folded in",
         %{store: store, session: session} do
      start_design(session, store, "stub-build-revise", attempts: 2)
      assert Orchestrator.pending_choice?(session.id)

      :ok = Orchestrator.user_choice(session.id, "revise: use Postgres, not SQLite")

      # Still paused — at checkpoint 1 again, for the revised design.
      assert Orchestrator.pending_choice?(session.id)

      [mission] = Missions.by_session(store, session.id)
      decisions = Sprat.Store.Decisions.by_mission(store, mission.id)
      assert Enum.any?(decisions, &(&1.summary =~ "revise design"))
      assert Enum.any?(decisions, &(&1.summary =~ "Postgres"))
    end

    test "abandon cancels the mission", %{store: store, session: session} do
      start_design(session, store, "stub-build-abandon")
      assert Orchestrator.pending_choice?(session.id)

      :ok = Orchestrator.user_choice(session.id, "abandon")

      refute Orchestrator.pending_choice?(session.id)
      [mission] = Missions.by_session(store, session.id)
      assert mission.status == "cancelled"
    end
  end

  test "the scaffold gate refuses when the health check fails, with the evidence recorded",
       %{store: store, session: session} do
    start_design(session, store, "stub-build-hc-fail",
      template_mod: FakeScaffoldFailsHealthCheck,
      sync?: false
    )

    assert Orchestrator.pending_choice?(session.id)
    :ok = Orchestrator.user_choice(session.id, "approve")

    # Scaffold's gate fails (deterministic — no model turn involved), and
    # `offer_recovery/12` blocks on a retry/skip/abandon prompt exactly as
    # it would for any other stage. Answer "abandon" (index 2) so the
    # background run settles before the test (and its ephemeral store)
    # tears down.
    assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
    :ok = Session.answer_permission(session.id, 2)

    [mission] = Missions.by_session(store, session.id)
    assert wait_until(fn -> Missions.get(store, mission.id).status == "cancelled" end)

    scaffold_task =
      store
      |> Tasks.by_mission(mission.id)
      |> Enum.find(&(&1.objective =~ "Scaffold"))

    assert scaffold_task.status == "failed"

    runs = Runs.by_mission(store, mission.id)
    health_check_run = Enum.find(runs, &(&1.purpose == "health_check"))
    assert health_check_run.exit_code == 1
    assert health_check_run.command != nil
    assert health_check_run.output_blob_hash != nil
  end

  defp wait_until(fun, tries \\ 1000)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end
end
