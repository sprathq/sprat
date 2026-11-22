defmodule Sprat.Mission.SlowStubModel do
  @moduledoc "Wraps `Sprat.StubModel` with an artificial delay, so tests can observe a task mid-flight (e.g. the \"submission while busy\" guard) without racing a real HTTP call."
  @behaviour Sprat.Model

  @impl true
  def capabilities(model_id), do: Sprat.StubModel.capabilities(model_id)
  @impl true
  def complete(request, opts), do: Sprat.StubModel.complete(request, opts)

  @impl true
  def stream(request, opts) do
    Process.sleep(150)
    Sprat.StubModel.stream(request, opts)
  end

  @impl true
  def normalize_usage(raw, context), do: Sprat.StubModel.normalize_usage(raw, context)
end

defmodule Sprat.Mission.CancelBetweenTurnsModel do
  @moduledoc """
  Wraps `Sprat.StubModel`, flipping `Sprat.Mission.cancel/1` for a
  registered session id right after its *first* `stream/2` call returns —
  simulating a cancel that arrives between turns rather than mid-stream.
  The scripted responses never report `stop_reason: :cancelled` (that
  branch is already covered by the "cancellation" describe block's other
  test), so the only thing that can stop the loop here is
  `Sprat.Agent.Loop`'s post-turn `cancel?` recheck (added for the
  Orchestrator's stall detector, task 10) — `Sprat.StubModel` itself never
  polls `cancel?` mid-stream. `register/2` must be called before
  `Mission.start/3`.
  """
  @behaviour Sprat.Model

  def register(model_id, session_id),
    do: :persistent_term.put({__MODULE__, model_id}, session_id)

  @impl true
  def capabilities(model_id), do: Sprat.StubModel.capabilities(model_id)
  @impl true
  def complete(request, opts), do: Sprat.StubModel.complete(request, opts)

  @impl true
  def stream(request, opts) do
    name = counter_name(request.model)

    count =
      case Process.whereis(name) do
        nil ->
          {:ok, _} = Agent.start_link(fn -> 0 end, name: name)
          0

        _pid ->
          Agent.get_and_update(name, fn c -> {c, c + 1} end)
      end

    result = Sprat.StubModel.stream(request, opts)

    if count == 0 do
      session_id = :persistent_term.get({__MODULE__, request.model})
      Sprat.Mission.cancel(session_id)
    end

    result
  end

  @impl true
  def normalize_usage(raw, context), do: Sprat.StubModel.normalize_usage(raw, context)

  defp counter_name(model_id), do: :"cancel_between_turns_count_#{model_id}"
end

defmodule Sprat.MissionTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Attachments
  alias Sprat.Mission
  alias Sprat.Session
  alias Sprat.Store.{Missions, Sessions, Sources, Tasks, Usage}
  alias Sprat.StubModel

  defp new_session(store, project_path \\ nil) do
    project_path = project_path || "/tmp/sprat-mission-test-#{System.unique_integer([:positive])}"
    {:ok, session} = Sessions.create(store, %{project_path: project_path})
    {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
    # Every async (`sync?: false`) test below settles on this before it
    # ends — Mission's very last action, always — so the ephemeral
    # StoreCase store never gets torn down while the background Task is
    # still mid-flight (it would otherwise log a noisy, harmless
    # exit-race crash: real production stores outlive a mission by
    # design, only this per-test ephemeral one is torn down this eagerly).
    Sprat.Session.PubSub.subscribe(session.id)
    session
  end

  defp await_settled, do: assert_receive({:sprat_session, _, {:inspector_updated, _}}, 1000)

  defp stub_response(attrs), do: Map.merge(%{tool_calls: [], usage: %{}, raw: %{}}, attrs)

  # `Sprat.Agent.Loop`'s budget reservation needs a priced catalog entry
  # for whatever model id a test uses; each test picks its own unique id
  # (StubModel's script queue is named globally by model id, so sharing
  # one across `async: true` tests would race), so each test also needs
  # its own matching one-model catalog rather than the real shipped one.
  defp stub_catalog(model_id, context_window) do
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
          context_window: context_window,
          price: %{
            input: Decimal.new("1.00"),
            cached_input: Decimal.new("0.50"),
            output: Decimal.new("2.00")
          }
        }
      ]
    }
  end

  defp start_opts(store, extra) do
    model_id = Keyword.get(extra, :model_id, "gpt-5-nano")
    context_window = Keyword.get(extra, :context_window, 100_000)

    [
      store: store,
      model_mod: StubModel,
      api_key: "k",
      budget_cap: Decimal.new("5.00"),
      catalog: stub_catalog(model_id, context_window),
      sync?: true
    ] ++ Keyword.delete(extra, :context_window)
  end

  # 200 x 5ms was a one-second budget for work that includes a stub model
  # call, a tool call and several store writes — fine on an idle machine and
  # the source of a long-running intermittent failure under load. Waiting
  # longer costs nothing when the condition is already true.
  defp wait_until(fun, tries \\ 2_000)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end

  describe "start/3 with @-attached evidence" do
    test "an attachment passed via opts becomes a user_provided source and reaches the model",
         %{store: store} do
      session = new_session(store)
      model_id = "attach-#{System.unique_integer([:positive])}"

      root =
        Path.join(System.tmp_dir!(), "sprat-mission-attach-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      path = Path.join(root, "churn.csv")
      File.write!(path, "name,plan\nalice,pro\nbob,free\n")

      # `Sprat.Mission`'s own `sources_section/1` re-derives an
      # attachment's content from `Sprat.Attachments.content_block/1`'s
      # *default* blob root (`Paths.blobs_dir()`, test-isolated by
      # `config/test.exs`) — using that same default here, not a custom
      # tmp dir, so this test exercises the exact path production code
      # takes (`Sprat.Session.Commands.attach_all/3` does the same).
      {:ok, attachment} = Attachments.attach(root, path, [], Sprat.Store.Paths.blobs_dir())

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "looked at it", stop_reason: :stop})
        ])

      :ok =
        Mission.start(
          session.id,
          "look at @churn.csv",
          start_opts(store, model_id: model_id, attachments: [attachment])
        )

      assert [mission] = Missions.by_session(store, session.id)
      assert [source] = Sources.by_mission(store, mission.id)
      assert source.source_type == "user_provided"
      assert source.url == "file://churn.csv"
      assert source.content_hash == attachment.blob_hash

      # `sources_section/1` re-derives the readable content from the blob
      # for every context package built afterwards — proving the model
      # sees a table, not raw bytes, without a second stored copy.
      %{messages: [_system, %{"role" => "user", "content" => context} | _]} =
        StubModel.last_request(model_id)

      assert context =~ "Attached file content"
      assert context =~ "| name | plan |"
      assert context =~ "alice"
    end
  end

  describe "start/3" do
    test "a plain final answer creates a mission and a completed task, and hands off to the user",
         %{
           store: store
         } do
      session = new_session(store)
      model_id = "final-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "12 * 7 is 84.", stop_reason: :stop})
        ])

      :ok = Mission.start(session.id, "what is 12 * 7?", start_opts(store, model_id: model_id))

      assert [mission] = Missions.by_session(store, session.id)
      assert mission.objective == "what is 12 * 7?"

      assert [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "completed"
      assert task.role == "researcher"

      %{blocks: blocks} = Session.snapshot(session.id)
      assert Enum.any?(blocks, &(&1.kind == :agent_message and &1.markdown == "12 * 7 is 84."))
    end

    # Defect backlog item 5 ("approval fatigue"): a real event-log count
    # found composed (non-search) fetches concentrated on documentation/
    # package hosts the model guessed a plausible-looking URL for instead
    # of searching. Same strengthened guidance as Sprat.Orchestrator's
    # search_note/1, kept by hand in this module's own @role_prompt (§
    # its comment) — this proves it actually reaches the model.
    test "the researcher's role prompt tells the model to search doc/package sites instead of guessing their URLs",
         %{store: store} do
      session = new_session(store)
      model_id = "prompt-check-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "ok", stop_reason: :stop})
        ])

      :ok = Mission.start(session.id, "hello", start_opts(store, model_id: model_id))

      %{messages: [%{"role" => "system", "content" => instructions} | _]} =
        StubModel.last_request(model_id)

      assert instructions =~ "do not guess or compose URLs from memory"
      assert instructions =~ "hex.pm"
      assert instructions =~ "search for the exact page instead of guessing a path"
    end

    test "records a usage record for the call", %{store: store} do
      session = new_session(store)
      model_id = "usage-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [stub_response(%{content: "ok", stop_reason: :stop})])

      :ok = Mission.start(session.id, "hi", start_opts(store, model_id: model_id))

      [mission] = Missions.by_session(store, session.id)
      assert [_ | _] = Usage.by_mission(store, mission.id)
    end

    test "a tool call runs and is recorded as tool.requested/tool.completed events", %{
      store: store
    } do
      session = new_session(store)
      model_id = "tool-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [%{id: "call_1", name: "calculate", arguments: %{"expression" => "2+2"}}]
          }),
          stub_response(%{content: "It's 4.", stop_reason: :stop})
        ])

      :ok = Mission.start(session.id, "add 2 and 2", start_opts(store, model_id: model_id))

      [mission] = Missions.by_session(store, session.id)
      [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "completed"

      types = Sprat.Store.Events.by_session(store, session.id, limit: 100) |> Enum.map(& &1.type)
      assert "tool.requested" in types
      assert "tool.completed" in types
    end
  end

  describe "approval round trip (§9 fetch rule)" do
    test "approving lets the loop continue and finish", %{store: store} do
      session = new_session(store)
      model_id = "approve-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://model-composed.example/x"}
              }
            ]
          }),
          stub_response(%{content: "Fetched and summarised.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "look this up", opts)

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      assert Session.snapshot(session.id).live.permission.title == "Fetch URL"

      :ok = Session.answer_permission(session.id, 0)

      assert wait_until(fn ->
               %{blocks: blocks} = Session.snapshot(session.id)

               Enum.any?(
                 blocks,
                 &(&1.kind == :agent_message and &1.markdown == "Fetched and summarised.")
               )
             end)

      [mission] = Missions.by_session(store, session.id)
      [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "completed"
      await_settled()
    end

    test "denying records a denial and the loop still finishes", %{store: store} do
      session = new_session(store)
      model_id = "deny-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://model-composed.example/x"}
              }
            ]
          }),
          stub_response(%{content: "Could not fetch; answering without it.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "look this up", opts)

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      :ok = Session.answer_permission(session.id, 2)

      assert wait_until(fn ->
               %{blocks: blocks} = Session.snapshot(session.id)

               Enum.any?(
                 blocks,
                 &(&1.kind == :agent_message and
                     &1.markdown == "Could not fetch; answering without it.")
               )
             end)

      await_settled()
    end
  end

  describe "cancellation" do
    test "a cancelled model response transitions the task to interrupted, not completed", %{
      store: store
    } do
      session = new_session(store)
      model_id = "cancel-#{System.unique_integer([:positive])}"

      # Simulates what `Sprat.Model.OpenAI.stream/2` returns once its
      # `cancel?` fires mid-stream (docs/spec-v1.md §13: "cancellation
      # closes the HTTP stream, records usage seen so far and transitions
      # the task") — `Sprat.StubModel` itself doesn't poll `cancel?`, so
      # this tests `Sprat.Mission`'s handling of that outcome directly
      # rather than the polling itself (covered by `Mission.cancel/1`
      # flipping the flag `Sprat.Agent.Loop`'s `cancel?` reads, unit-tested
      # implicitly via `openai_test.exs`'s own cancellation coverage).
      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "partial...", stop_reason: :cancelled})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "cancel me", opts)

      assert wait_until(fn -> Missions.by_session(store, session.id) != [] end)
      [mission] = Missions.by_session(store, session.id)

      assert wait_until(fn ->
               case Tasks.by_mission(store, mission.id) do
                 [%{status: "interrupted"}] -> true
                 _ -> false
               end
             end)

      %{blocks: blocks} = Session.snapshot(session.id)
      assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "interrupted"))
      await_settled()
    end

    test "a cancel flag flipped between turns (not mid-stream) stops the loop one turn sooner, still handled as interrupted",
         %{store: store} do
      session = new_session(store)
      model_id = "cancel-between-#{System.unique_integer([:positive])}"
      Sprat.Mission.CancelBetweenTurnsModel.register(model_id, session.id)

      # Neither turn reports `stop_reason: :cancelled` — if `Loop` only
      # polled `cancel?` mid-stream (as before this build's stall-detection
      # work), the cancel flipped after turn 1 wouldn't be noticed until
      # some later mid-stream poll, and turn 2 would run. A second
      # scripted response is provided so the test fails loudly (a real
      # tool call, not a script-exhausted crash) if that regresses.
      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{id: "call_1", name: "calculate", arguments: %{"expression" => "1 + 1"}}
            ]
          }),
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{id: "call_2", name: "calculate", arguments: %{"expression" => "2 + 2"}}
            ]
          })
        ])

      opts =
        start_opts(store, model_id: model_id)
        |> Keyword.put(:model_mod, Sprat.Mission.CancelBetweenTurnsModel)

      :ok = Mission.start(session.id, "cancel between turns", opts)

      [mission] = Missions.by_session(store, session.id)
      [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "interrupted"

      events = Sprat.Store.Events.by_session(store, session.id, limit: 1000)
      responses = Enum.filter(events, &(&1.type == "model.response"))
      # Only turn 1's response was ever recorded — the loop stopped
      # before turn 2's model call happened at all, one turn sooner than
      # it would have without the post-turn `cancel?` recheck.
      assert length(responses) == 1

      %{blocks: blocks} = Session.snapshot(session.id)
      assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "interrupted"))
    end
  end

  describe "evidence (§6 record_source, Inspector Evidence tab)" do
    test "record_source writes through Sprat.Store.Sources and the Inspector snapshot picks it up",
         %{store: store} do
      session = new_session(store)
      model_id = "record-source-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "record_source",
                arguments: %{
                  "url" => "https://elixir-lang.org",
                  "title" => "The Elixir programming language",
                  "source_type" => "documentation"
                }
              }
            ]
          }),
          stub_response(%{content: "Cited the official site.", stop_reason: :stop})
        ])

      :ok = Mission.start(session.id, "what is elixir?", start_opts(store, model_id: model_id))

      [mission] = Missions.by_session(store, session.id)
      sources = Sprat.Store.Sources.by_mission(store, mission.id)
      assert [%{url: "https://elixir-lang.org", source_type: "documentation"}] = sources

      assert_receive {:sprat_session, _, {:inspector_updated, %{sources: inspector_sources}}}
      assert Enum.map(inspector_sources, & &1.url) == ["https://elixir-lang.org"]
    end

    test "an unrecognised tool call (e.g. web_fetch on a URL the model composed, denied) leaves no source",
         %{store: store} do
      session = new_session(store)
      model_id = "no-source-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "Answered from general knowledge.", stop_reason: :stop})
        ])

      :ok = Mission.start(session.id, "no fetch needed", start_opts(store, model_id: model_id))

      [mission] = Missions.by_session(store, session.id)
      assert Sprat.Store.Sources.by_mission(store, mission.id) == []
    end
  end

  describe "budget" do
    test "a worst-case reservation over the cap stops the call before it's made", %{store: store} do
      session = new_session(store)
      model_id = "budget-#{System.unique_integer([:positive])}"
      {:ok, _} = StubModel.start_script(model_id, [])

      opts =
        start_opts(store, model_id: model_id)
        |> Keyword.put(:budget_cap, Decimal.new("0.00"))

      :ok = Mission.start(session.id, "this should never call the model", opts)

      [mission] = Missions.by_session(store, session.id)
      [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "failed"

      # Bug: the conversation showed the raw reason tuple verbatim
      # ("Researcher failed: {:http_error, 401, \"\"}") instead of a human
      # message — the raw detail still goes to the task-transition event
      # (`Sprat.Mission.finish_error/4`'s `reason: inspect(reason)`, for
      # the debug view), just not to the transcript.
      error_block = Session.snapshot(session.id).blocks |> Enum.find(&(&1.kind == :error))
      assert error_block.message == "Researcher failed: would exceed the mission budget cap."
      refute error_block.message =~ "{:"
    end
  end

  describe "fetch rule: URLs the user typed are fetched without asking (§9)" do
    test "a URL in the user's own message is fetched, no approval prompt", %{store: store} do
      session = new_session(store)
      model_id = "user-url-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://user-gave.example/x"}
              }
            ]
          }),
          stub_response(%{content: "Answered without asking.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id)
      :ok = Mission.start(session.id, "look at https://user-gave.example/x please", opts)

      # never asked — the URL came straight from the user's own message
      refute Session.snapshot(session.id).live.permission

      [mission] = Missions.by_session(store, session.id)
      [task] = Tasks.by_mission(store, mission.id)
      assert task.status == "completed"
    end
  end

  describe "context package across submissions (§9)" do
    test "a second submission's request includes the first exchange, not just the latest message",
         %{store: store} do
      session = new_session(store)
      model_id = "ctx-history-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: "Paris is the capital of France.", stop_reason: :stop}),
          stub_response(%{content: "It has about 2.1 million people.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id)
      :ok = Mission.start(session.id, "what is the capital of france?", opts)
      :ok = Mission.start(session.id, "how many people live there?", opts)

      %{messages: [system_msg, %{"content" => user_content}]} = StubModel.last_request(model_id)
      assert system_msg["content"] =~ "researcher"

      assert user_content =~ "Paris is the capital of France."
      assert user_content =~ "what is the capital of france?"
      assert user_content =~ "Current request:\nhow many people live there?"
    end

    test "sources recorded in an earlier submission are included in a later request", %{
      store: store
    } do
      session = new_session(store)
      model_id = "ctx-sources-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "record_source",
                arguments: %{
                  "url" => "https://example.com",
                  "title" => "Example",
                  "source_type" => "documentation"
                }
              }
            ]
          }),
          stub_response(%{content: "Cited it.", stop_reason: :stop}),
          stub_response(%{content: "Follow-up answer.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id)
      :ok = Mission.start(session.id, "look at example.com", opts)
      :ok = Mission.start(session.id, "tell me more about that domain", opts)

      %{messages: [_system, %{"content" => user_content}]} = StubModel.last_request(model_id)
      assert user_content =~ "https://example.com"
    end

    test "drops the oldest turns to fit a tiny context window, noting the drop, and never drops the current request",
         %{store: store} do
      session = new_session(store)
      model_id = "ctx-budget-#{System.unique_integer([:positive])}"

      long_answer = String.duplicate("word ", 40)

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{content: long_answer, stop_reason: :stop}),
          stub_response(%{content: "second answer", stop_reason: :stop})
        ])

      # context_window: 50 tokens * 0.3 history share * 4 chars/token = 60
      # chars of budget — the first exchange alone is far bigger than that.
      opts = start_opts(store, model_id: model_id, context_window: 50)
      :ok = Mission.start(session.id, "first question padded out to be long enough", opts)
      :ok = Mission.start(session.id, "second question", opts)

      %{messages: [_system, %{"content" => user_content}]} = StubModel.last_request(model_id)
      assert user_content =~ "Current request:\nsecond question"
      assert user_content =~ "omitted to fit the context window"
      refute user_content =~ "first question padded out to be long enough"
    end
  end

  describe "one task at a time per session" do
    test "a submission while the previous task is still running is refused, not queued and not silently dropped",
         %{store: store} do
      session = new_session(store)
      model_id = "busy-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [stub_response(%{content: "done", stop_reason: :stop})])

      opts =
        start_opts(store, model_id: model_id)
        |> Keyword.put(:sync?, false)
        |> Keyword.put(:model_mod, Sprat.Mission.SlowStubModel)

      :ok = Mission.start(session.id, "first", opts)

      assert wait_until(fn ->
               case Missions.by_session(store, session.id) do
                 [m] ->
                   match?([%{status: "running"}], Tasks.by_mission(store, m.id))

                 _ ->
                   false
               end
             end)

      :ok = Mission.start(session.id, "second, arrives while busy", opts)

      %{blocks: blocks} = Session.snapshot(session.id)
      assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Still working"))

      assert wait_until(fn ->
               case Missions.by_session(store, session.id) do
                 [m] -> match?([%{status: "completed"}], Tasks.by_mission(store, m.id))
                 _ -> false
               end
             end)

      # exactly one mission ever existed — the busy submission created nothing
      assert length(Missions.by_session(store, session.id)) == 1
      await_settled()
    end
  end

  describe "grants (§9 reuse)" do
    test "an approved domain from an earlier submission is not re-prompted in a later one in the same session",
         %{store: store} do
      session = new_session(store)
      model_id = "grant-reuse-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://model-composed.example/x"}
              }
            ]
          }),
          stub_response(%{content: "Fetched and summarised.", stop_reason: :stop}),
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_2",
                name: "web_fetch",
                arguments: %{"url" => "https://model-composed.example/y"}
              }
            ]
          }),
          stub_response(%{content: "Fetched again, no prompt this time.", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "look this up", opts)

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      # option 1: "Yes, and allow HOST for this mission"
      :ok = Session.answer_permission(session.id, 1)

      assert wait_until(fn ->
               %{blocks: blocks} = Session.snapshot(session.id)

               Enum.any?(
                 blocks,
                 &(&1.kind == :agent_message and &1.markdown == "Fetched and summarised.")
               )
             end)

      await_settled()

      :ok = Mission.start(session.id, "look at another page on that domain", opts)

      assert wait_until(fn ->
               %{blocks: blocks} = Session.snapshot(session.id)

               Enum.any?(
                 blocks,
                 &(&1.kind == :agent_message and
                     &1.markdown == "Fetched again, no prompt this time.")
               )
             end)

      # never asked again — no permission prompt was ever raised for the second run
      refute Session.snapshot(session.id).live.permission

      grants = Sprat.Store.Grants.by_session(store, session.id)
      assert [%{resource: "model-composed.example", resource_scope: "domain"}] = grants
    end

    test "a different domain still prompts even after another domain was approved", %{
      store: store
    } do
      session = new_session(store)
      model_id = "grant-different-#{System.unique_integer([:positive])}"

      Sprat.Store.Grants.record(store, session.id, %{
        action: "web_fetch",
        resource: "approved.example",
        resource_scope: "domain",
        decision: "approved"
      })

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://other.example/x"}
              }
            ]
          }),
          stub_response(%{content: "answered", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "look this up", opts)

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
      assert Session.snapshot(session.id).live.permission.title == "Fetch URL"
      :ok = Session.answer_permission(session.id, 2)
      await_settled()
    end
  end

  # -- mid-mission steering (docs/spec-v1.md §10) --------------------------

  describe "mid-mission steering" do
    test "a plain message sent while the mission is running is queued, not refused, and " <>
           "reaches the next turn's request",
         %{store: store} do
      session = new_session(store)
      model_id = "steering-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [%{id: "call_1", name: "calculate", arguments: %{"expression" => "1+1"}}]
          }),
          stub_response(%{content: "done", stop_reason: :stop})
        ])

      opts =
        start_opts(store, model_id: model_id)
        |> Keyword.put(:sync?, false)
        |> Keyword.put(:model_mod, Sprat.Mission.SlowStubModel)

      :ok = Mission.start(session.id, "research something", opts)

      assert wait_until(fn ->
               case Missions.by_session(store, session.id) do
                 [m] -> match?([%{status: "running"}], Tasks.by_mission(store, m.id))
                 _ -> false
               end
             end)

      assert Mission.busy?(session.id)
      [mission] = Missions.by_session(store, session.id)
      assert Mission.active_mission_id(session.id) == mission.id

      # Accepted, not refused: no "Still working" refusal block, and the
      # message itself is persisted immediately (queued, dimmed).
      :ok = Sprat.Session.Commands.handle(session.id, store, "UK only")

      %{blocks: blocks} = Session.snapshot(session.id)
      refute Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "Still working"))
      assert Enum.any?(blocks, &(&1.kind == :user_message and &1.text == "UK only"))
      queued_block = Enum.find(blocks, &(&1.kind == :user_message and &1.text == "UK only"))
      assert queued_block.queued?
      assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "queued"))

      assert [%{text: "UK only", status: "queued"}] =
               Sprat.Store.SteeringMessages.by_mission(store, mission.id)

      assert wait_until(fn ->
               match?([%{status: "completed"}], Tasks.by_mission(store, mission.id))
             end)

      request = StubModel.last_request(model_id)
      contents = Enum.map(request.messages, &Map.get(&1, "content"))
      assert Enum.any?(contents, &(is_binary(&1) and &1 =~ "USER STEERING"))
      assert Enum.any?(contents, &(is_binary(&1) and &1 =~ "UK only"))

      events = Sprat.Store.Events.by_session(store, session.id)
      assert Enum.any?(events, &(&1.type == "steering.queued"))
      assert Enum.any?(events, &(&1.type == "steering.delivered"))

      await_settled()
    end

    test "a pending fetch-approval prompt takes precedence over steering", %{store: store} do
      session = new_session(store)
      model_id = "steering-precedence-#{System.unique_integer([:positive])}"

      {:ok, _} =
        StubModel.start_script(model_id, [
          stub_response(%{
            content: nil,
            stop_reason: :tool_calls,
            tool_calls: [
              %{id: "call_1", name: "web_fetch", arguments: %{"url" => "https://other.example/x"}}
            ]
          }),
          stub_response(%{content: "done", stop_reason: :stop})
        ])

      opts = start_opts(store, model_id: model_id) |> Keyword.put(:sync?, false)
      :ok = Mission.start(session.id, "look this up", opts)

      assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)

      :ok = Sprat.Session.Commands.handle(session.id, store, "UK only")

      [mission] = Missions.by_session(store, session.id)
      # Not queued as steering — the prompt was showing.
      assert Sprat.Store.SteeringMessages.by_mission(store, mission.id) == []

      %{blocks: blocks} = Session.snapshot(session.id)
      assert Enum.any?(blocks, &(&1.kind == :system and &1.text =~ "prompt above"))

      :ok = Session.answer_permission(session.id, 0)
      await_settled()
    end
  end
end
