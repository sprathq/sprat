defmodule Sprat.Session.CommandsTest do
  # async: false — the /idea, /depth and /research tests below drive
  # `Sprat.Orchestrator` through `:sprat, :mission_defaults` (the same
  # Application-env seam `Sprat.Mission.start/3`'s tests already share
  # globally, see test/test_helper.exs), so each of those tests
  # temporarily overrides it and restores it in `on_exit`. That's a
  # global mutation, so it must never race another test reading it —
  # same reasoning as `Sprat.OrchestratorTest`'s own `async: false`.
  use Sprat.StoreCase, async: false

  alias Sprat.{Session, SessionSupervisor}
  alias Sprat.Session.Commands
  alias Sprat.Store.{Artifacts, Claims, Missions, Sessions, Tasks}

  defp open(store, session_id), do: SessionSupervisor.open(session_id, store: store)

  # Same one-model catalog shape `Sprat.OrchestratorTest` uses — a stub
  # model id has no entry in the real priced catalog, and
  # `Sprat.Agent.Loop` refuses to run against a model with no price.
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

  # Temporarily points `:sprat, :mission_defaults` (the seam
  # `Sprat.Session.Commands`'s staged-command opts resolution and
  # `Sprat.Mission.start/3` both read) at a scripted model for one test,
  # restoring the suite-wide default from test/test_helper.exs after.
  defp with_mission_defaults(overrides, fun) do
    original = Application.get_env(:sprat, :mission_defaults)
    Application.put_env(:sprat, :mission_defaults, overrides)

    try do
      fun.()
    after
      Application.put_env(:sprat, :mission_defaults, original)
    end
  end

  defp new_session(store, project_path \\ "/tmp/proj") do
    {:ok, session} = Sessions.create(store, %{project_path: project_path})
    {:ok, pid} = open(store, session.id)
    {session, pid}
  end

  defp last_system_block(pid) do
    %{blocks: blocks} = Session.snapshot(pid)
    blocks |> Enum.filter(&(&1.kind == :system)) |> List.last()
  end

  defp wait_until(fun, tries \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  describe "/help" do
    test "lists every command", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/help")

      block = last_system_block(pid)
      assert block.text =~ "/clear"
      assert block.text =~ "/doctor"
      assert block.text =~ "/export"
    end
  end

  describe "/clear" do
    test "starts a new session and leaves the old one resumable", %{store: store} do
      {session, _pid} = new_session(store, "/tmp/proj-clear")

      assert {:switch_session, new_id} = Commands.handle(session.id, store, "/clear")
      refute new_id == session.id

      new_session_row = Sessions.get(store, new_id)
      assert new_session_row.project_path == "/tmp/proj-clear"
      assert Sessions.get(store, session.id) != nil
    end
  end

  describe "/resume" do
    test "lists other sessions for the same project", %{store: store} do
      {session, pid} = new_session(store, "/tmp/proj-resume")
      {:ok, other} = Sessions.create(store, %{project_path: "/tmp/proj-resume"})

      :ok = Commands.handle(session.id, store, "/resume")

      block = last_system_block(pid)
      assert block.text =~ other.id
    end

    test "says honestly when there is nothing else to resume", %{store: store} do
      {session, pid} = new_session(store, "/tmp/proj-resume-empty")
      :ok = Commands.handle(session.id, store, "/resume")
      assert last_system_block(pid).text =~ "No other sessions"
    end
  end

  describe "/events" do
    test "shows the session's own event timeline", %{store: store} do
      {session, pid} = new_session(store)
      Session.submit_user_message(pid, "hi")

      :ok = Commands.handle(session.id, store, "/events")
      assert last_system_block(pid).text =~ "message.appended"
    end
  end

  describe "/usage, /sources and /tasks: honest empty states with no orchestration" do
    test "/usage", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/usage")
      assert last_system_block(pid).text =~ "no model backend"
    end

    test "/sources", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/sources")
      assert last_system_block(pid).text =~ "No sources recorded"
    end

    test "/tasks", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/tasks")
      assert last_system_block(pid).text =~ "no orchestration"
    end

    test "/tasks shows real tasks once a mission has them", %{store: store} do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "find a gym idea"})

      {:ok, _task} =
        Tasks.create(store, mission.id, %{role: "researcher", objective: "scan reddit"})

      :ok = Commands.handle(session.id, store, "/tasks")
      block = last_system_block(pid)
      assert block.text =~ "researcher"
      assert block.text =~ "scan reddit"
    end

    test "/artifacts with no mission yet", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/artifacts")
      assert last_system_block(pid).text =~ "No mission yet."
    end

    test "/claims with no mission yet", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/claims")
      assert last_system_block(pid).text =~ "No mission yet."
    end
  end

  describe "/artifacts lists every artifact written in the session's latest mission" do
    test "shows type, version and owning role", %{store: store} do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "find a gym idea"})

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: "research_memo",
          owning_role: "researcher",
          content: %{"body" => "draft"}
        })

      :ok = Commands.handle(session.id, store, "/artifacts")
      block = last_system_block(pid)
      assert block.text =~ "research_memo"
      assert block.text =~ "v1"
      assert block.text =~ "researcher"
    end
  end

  describe "/open" do
    test "renders the artifact's latest version as Markdown, not raw JSON (no $PAGER — stage 2)",
         %{store: store} do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "find a gym idea"})

      {:ok, _} =
        Artifacts.write(store, mission.id, %{
          type: "research_memo",
          owning_role: "researcher",
          content: %{"summary" => "draft content", "claims" => [], "limitations" => "none"}
        })

      :ok = Commands.handle(session.id, store, "/open research_memo")
      text = last_system_block(pid).text
      assert text =~ "draft content"
      refute text =~ "{\"summary\""
    end

    test "with no arg, shows usage", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/open")
      assert last_system_block(pid).text =~ "Usage: /open"
    end

    test "with a type that has no artifact yet, says so instead of crashing", %{store: store} do
      {session, pid} = new_session(store)
      {:ok, _mission} = Missions.create(store, session.id, %{objective: "find a gym idea"})
      :ok = Commands.handle(session.id, store, "/open not_a_real_type")
      assert last_system_block(pid).text =~ "No artifact of type not_a_real_type yet."
    end
  end

  describe "/claims" do
    test "lists unsupported (assumption) claims before sourced ones, regardless of confidence", %{
      store: store
    } do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "find a gym idea"})

      Claims.record(store, mission.id, %{
        text: "market is growing",
        confidence: "high",
        is_assumption: false
      })

      # is_assumption alone is the "unsupported" proxy (Claims.by_mission/2
      # doesn't join claim_sources) — a high-confidence assumption still has
      # no supporting source, so it must still sort ahead of the sourced
      # claim above, not just a low-confidence one.
      Claims.record(store, mission.id, %{
        text: "users will pay $20/mo",
        confidence: "high",
        is_assumption: true
      })

      :ok = Commands.handle(session.id, store, "/claims")
      block = last_system_block(pid)
      assumption_index = :binary.match(block.text, "users will pay") |> elem(0)
      sourced_index = :binary.match(block.text, "market is growing") |> elem(0)
      assert assumption_index < sourced_index
      assert block.text =~ "[assumption]"
    end
  end

  describe "/doctor" do
    test "reports runtime, data dir, database and terminal info", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/doctor")
      block = last_system_block(pid)
      assert block.text =~ "Elixir:"
      assert block.text =~ "OpenAI key:"
    end
  end

  describe "/export" do
    test "writes the full bundle under <dir>/<mission_id>/ for a delivered mission", %{
      store: store,
      tmp_dir: tmp
    } do
      {session, pid} = new_session(store)
      Session.submit_user_message(pid, "export me")
      {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking software"})

      Artifacts.write(store, mission.id, %{
        type: :validation_plan,
        owning_role: "researcher",
        content: %{
          "experiments" => [
            %{
              "assumption" => "users will pay",
              "method" => "survey",
              "participant_criteria" => "5 gyms",
              "budget" => "$100",
              "duration" => "1 week",
              "success_threshold" => "3 of 5",
              "failure_threshold" => "0 of 5",
              "decision" => "scale or pivot"
            }
          ]
        },
        created_by: "researcher"
      })

      dir = Path.join(tmp, "export-out")
      :ok = Commands.handle(session.id, store, "/export #{dir}")
      mission_dir = Path.join(dir, mission.id)

      assert File.exists?(Path.join(mission_dir, "README.md"))
      assert File.read!(Path.join(mission_dir, "README.md")) =~ mission.id
      assert File.read!(Path.join(mission_dir, "brief.md")) =~ "Product brief"
      assert File.read!(Path.join(mission_dir, "validation-plan.md")) =~ "users will pay"
      assert File.exists?(Path.join(mission_dir, "research.md"))
      assert File.exists?(Path.join(mission_dir, "sources.md"))
      assert File.exists?(Path.join(mission_dir, "usage.csv"))
      assert File.exists?(Path.join(mission_dir, "usage.md"))
      assert File.exists?(Path.join(mission_dir, "artifacts.json"))

      assert File.exists?(Path.join(mission_dir, "transcript.md"))
      assert File.read!(Path.join(mission_dir, "transcript.md")) =~ "export me"

      assert File.exists?(Path.join(mission_dir, "events.jsonl"))
      assert File.read!(Path.join(mission_dir, "events.jsonl")) =~ "message.appended"

      assert last_system_block(pid).text =~ "Exported to"
    end

    test "artifacts.json carries each artifact's real content, incomplete/reason included — not just its metadata shell",
         %{store: store, tmp_dir: tmp} do
      {session, _pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking software"})

      Artifacts.write(store, mission.id, %{
        type: :intake_summary,
        owning_role: "researcher",
        content: %{"incomplete" => true, "reason" => "user skipped after a failure"},
        created_by: "researcher"
      })

      dir = Path.join(tmp, "export-artifacts")
      :ok = Commands.handle(session.id, store, "/export #{dir}")

      [artifact] =
        File.read!(Path.join([dir, mission.id, "artifacts.json"])) |> JSON.decode!()

      assert artifact["type"] == "intake_summary"

      assert artifact["content"] == %{
               "incomplete" => true,
               "reason" => "user skipped after a failure"
             }
    end

    test "no mission yet: honest message, no directory written", %{store: store, tmp_dir: tmp} do
      {session, pid} = new_session(store)
      dir = Path.join(tmp, "export-empty")

      :ok = Commands.handle(session.id, store, "/export #{dir}")

      assert last_system_block(pid).text =~ "No mission yet"
      refute File.exists?(dir)
    end

    test "mission still active with nothing delivered yet: honest message, no directory written",
         %{store: store, tmp_dir: tmp} do
      {session, pid} = new_session(store)
      {:ok, _mission} = Missions.create(store, session.id, %{objective: "gym booking software"})
      dir = Path.join(tmp, "export-running")

      :ok = Commands.handle(session.id, store, "/export #{dir}")

      assert last_system_block(pid).text =~ "still running"
      refute File.exists?(dir)
    end

    test "mission failed with nothing written: honest message, no directory written", %{
      store: store,
      tmp_dir: tmp
    } do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking software"})
      {:ok, _} = Missions.transition(store, mission.id, :failed, %{session_id: session.id})
      dir = Path.join(tmp, "export-failed")

      :ok = Commands.handle(session.id, store, "/export #{dir}")

      assert last_system_block(pid).text =~ "failed before writing anything"
      refute File.exists?(dir)
    end

    test "mission failed after partial delivery: still exports, README says so", %{
      store: store,
      tmp_dir: tmp
    } do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking software"})

      Artifacts.write(store, mission.id, %{
        type: :intake_summary,
        owning_role: "researcher",
        content: %{"objective" => "gym booking software", "depth" => "quick"},
        created_by: "researcher"
      })

      {:ok, _} = Missions.transition(store, mission.id, :failed, %{session_id: session.id})
      dir = Path.join(tmp, "export-partial-failed")

      :ok = Commands.handle(session.id, store, "/export #{dir}")
      readme = File.read!(Path.join([dir, mission.id, "README.md"]))

      assert readme =~ "Mission failed"
      assert last_system_block(pid).text =~ "Exported to"
    end

    test "mission delivered with a skipped stage: README names how many", %{
      store: store,
      tmp_dir: tmp
    } do
      {session, _pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking software"})

      Artifacts.write(store, mission.id, %{
        type: :research_memo,
        owning_role: "researcher",
        content: %{"incomplete" => true, "reason" => "user skipped after a failure"},
        created_by: "researcher"
      })

      Artifacts.write(store, mission.id, %{
        type: :validation_plan,
        owning_role: "researcher",
        content: %{
          "experiments" => [
            %{
              "assumption" => "x",
              "method" => "x",
              "participant_criteria" => "x",
              "budget" => "x",
              "duration" => "x",
              "success_threshold" => "x",
              "failure_threshold" => "x",
              "decision" => "x"
            }
          ]
        },
        created_by: "researcher"
      })

      dir = Path.join(tmp, "export-skipped")
      :ok = Commands.handle(session.id, store, "/export #{dir}")
      readme = File.read!(Path.join([dir, mission.id, "README.md"]))

      assert readme =~ "1 stage(s) skipped: research_memo"
    end
  end

  describe "/settings" do
    test "shows effective values and their source, and the key source without the key itself", %{
      store: store
    } do
      project = "/tmp/proj-settings-#{System.unique_integer([:positive])}"
      File.mkdir_p!(project)
      on_exit(fn -> File.rm_rf(project) end)

      {session, pid} = new_session(store, project)
      System.put_env("OPENAI_API_KEY", "sk-test-secretvalue-should-not-leak-0000000000wxyz")

      :ok = Commands.handle(session.id, store, "/settings")
      text = last_system_block(pid).text

      assert text =~ "Model:"
      assert text =~ "unset (default)"
      assert text =~ "…wxyz"
      refute text =~ "sk-test-secretvalue-should-not-leak"
    after
      System.delete_env("OPENAI_API_KEY")
    end

    test "a project cap above the user cap is refused by the editor's write path (Sprat.Config), not silently accepted",
         %{store: _store} do
      project = "/tmp/proj-settings-cap-#{System.unique_integer([:positive])}"
      File.mkdir_p!(project)
      on_exit(fn -> File.rm_rf(project) end)
      Application.put_env(:sprat, :user_config_dir, project <> "-userconf")
      Sprat.Config.put_user("budget_usd", Decimal.new("5"))

      assert {:error, :exceeds_user_cap} = Sprat.Config.put_budget_usd(project, Decimal.new("50"))
      assert Sprat.Config.budget_usd(project) == nil
    after
      Application.delete_env(:sprat, :user_config_dir)
    end
  end

  describe "/debug" do
    test "with no missions yet, says so honestly instead of a fake empty table", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/debug")
      assert last_system_block(pid).text =~ "No missions yet in this session"
    end

    test "with a mission, shows request/tool counts and a cost line from leaf usage records only",
         %{store: store} do
      {session, pid} = new_session(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
      {:ok, task} = Tasks.create(store, mission.id, %{role: "researcher", objective: "t"})

      Sprat.Store.Usage.record(store, %{
        task_id: task.id,
        mission_id: mission.id,
        provider: "openai",
        model: "m",
        raw_payload: %{},
        coverage: "reported",
        cost: Decimal.new("0.05"),
        ended_at: "t"
      })

      :ok = Commands.handle(session.id, store, "/debug")
      text = last_system_block(pid).text
      assert text =~ "requests: 1"
      assert text =~ "$0.0500"
    end
  end

  describe "/idea, /research and /depth: staged Orchestrator missions" do
    test "/idea starts a staged Orchestrator mission, not a plain Mission run", %{store: store} do
      {session, pid} = new_session(store)
      model = Sprat.StubModel.scripted_for_idea_delivery()

      with_mission_defaults(
        [
          model_mod: model,
          model_id: "stub-idea-delivery",
          api_key: "test-key",
          budget_cap: Decimal.new("5.00"),
          catalog: stub_catalog("stub-idea-delivery")
        ],
        fn ->
          :ok = Commands.handle(session.id, store, "/idea gym booking software")

          assert wait_until(fn ->
                   %{blocks: blocks} = Session.snapshot(pid)
                   Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Directions ready"))
                 end)
        end
      )

      # Intake -> Research -> Analysis -> Directions, then stops for the
      # user-choice point (Sprat.Workflow.Idea's stage count for this
      # script — matches Sprat.OrchestratorTest's own assertion for the
      # same scripted model), not the single-task quick path.
      [mission] = Missions.by_session(store, session.id)
      tasks = Tasks.by_mission(store, mission.id)
      assert length(tasks) == 4
      assert Enum.all?(tasks, &(&1.role == "researcher"))
    end

    test "a plain message still runs the single-agent quick path", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "what's the weather like")

      assert wait_until(fn -> Missions.by_session(store, session.id) != [] end)

      [mission] = Missions.by_session(store, session.id)
      assert [task] = Tasks.by_mission(store, mission.id)
      assert task.role == "researcher"
      assert task.objective == "what's the weather like"

      %{blocks: blocks} = Session.snapshot(pid)

      assert Enum.any?(
               blocks,
               &(&1.kind == :user_message and &1.text == "what's the weather like")
             )
    end

    test "/depth deep changes the depth used by the next /idea or /research", %{store: store} do
      {session, _pid} = new_session(store)
      model = Sprat.StubModel.always_writes_invalid_research_memo()

      with_mission_defaults(
        [
          model_mod: model,
          model_id: "stub-invalid-research",
          api_key: "test-key",
          budget_cap: Decimal.new("5.00"),
          catalog: stub_catalog("stub-invalid-research")
        ],
        fn ->
          :ok = Commands.handle(session.id, store, "/depth deep")
          assert Sprat.Config.research_depth(session.project_path) == "deep"

          :ok = Commands.handle(session.id, store, "/idea gym booking software")

          assert wait_until(fn ->
                   case Missions.by_session(store, session.id) do
                     [mission] ->
                       store
                       |> Tasks.by_mission(mission.id)
                       |> Enum.any?(&(&1.status == "failed"))

                     [] ->
                       false
                   end
                 end)
        end
      )

      # Research's stage prompt (Sprat.Workflow.Idea's `research_prompt/1`)
      # embeds `Sprat.Workflow.Depth.source_target/1` as plain text — the
      # request the stub model actually received for that stage is the
      # observable proof that `:deep` (not the default `:standard`) is
      # what reached `Sprat.Orchestrator.start/5`. Deep's target is
      # `{40, nil}` -> "40+"; quick/standard would read "5-10"/"15-30".
      request = Sprat.StubModel.last_request("stub-invalid-research")
      assert inspect(request) =~ "40+"
    end
  end

  describe "unknown commands and plain messages" do
    test "an unknown slash command says so", %{store: store} do
      {session, pid} = new_session(store)
      :ok = Commands.handle(session.id, store, "/nope")
      assert last_system_block(pid).text =~ "Unknown command /nope"
    end

    test "a plain message is persisted and starts a real (stubbed in tests) mission", %{
      store: store
    } do
      {session, pid} = new_session(store)
      Sprat.Session.PubSub.subscribe(session.id)
      :ok = Commands.handle(session.id, store, "what should I build?")

      %{blocks: blocks} = Session.snapshot(pid)
      assert Enum.any?(blocks, &(&1.kind == :user_message and &1.text == "what should I build?"))

      assert wait_until(fn ->
               %{blocks: blocks} = Session.snapshot(pid)

               Enum.any?(
                 blocks,
                 &(&1.kind == :agent_message and &1.markdown == "test stub answer")
               )
             end)

      assert [mission] = Missions.by_session(store, session.id)
      assert [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "completed"

      # Mission's very last action for a finished task — waiting for it
      # avoids tearing down this test's ephemeral store while the
      # background mission Task is still mid-flight (see `Sprat.MissionTest`).
      assert_receive {:sprat_session, _, {:inspector_updated, _}}, 1000
    end
  end
end
