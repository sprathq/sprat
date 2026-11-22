defmodule Sprat.StubModel do
  @moduledoc """
  A scripted `Sprat.Model` for `Sprat.Agent.Loop` tests: `start_script/2`
  queues a list of responses (in `Sprat.Model.stream/2`'s response shape)
  under `model_id`; each call to `stream/2` pops the next one. Lets loop
  tests exercise multi-turn tool round trips without any HTTP.
  """

  @behaviour Sprat.Model

  def start_script(model_id, responses) do
    Agent.start_link(fn -> responses end, name: script_name(model_id))
  end

  @doc "The `request` map (model/messages/tools) passed to the most recent `stream/2` call for `model_id`, or `nil`."
  def last_request(model_id) do
    case Process.whereis(requests_name(model_id)) do
      nil -> nil
      _pid -> Agent.get(requests_name(model_id), & &1)
    end
  end

  @impl true
  def capabilities(_model_id), do: {:ok, %{}}

  @impl true
  def complete(_request, _opts), do: {:error, :not_implemented}

  @impl true
  def stream(request, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    record_request(request)

    response =
      Agent.get_and_update(script_name(request.model), fn
        [next | rest] -> {next, rest}
        [] -> raise "stub model script exhausted for #{request.model}"
      end)

    if is_binary(response[:content]), do: on_delta.(%{type: :content, text: response.content})
    {:ok, response}
  end

  @impl true
  def normalize_usage(raw, context) do
    %{
      provider: "stub",
      model: context.model,
      raw_payload: raw || %{},
      normalization_version: 1,
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      cost: Decimal.new("0.0010"),
      pricing_version: "stub-test",
      coverage: if(Map.get(context, :interrupted?, false), do: "estimated", else: "reported")
    }
  end

  defp record_request(request) do
    name = requests_name(request.model)

    case Process.whereis(name) do
      nil -> Agent.start_link(fn -> request end, name: name)
      _pid -> Agent.update(name, fn _ -> request end)
    end
  end

  defp script_name(model_id), do: :"stub_model_#{model_id}"
  defp requests_name(model_id), do: :"stub_model_requests_#{model_id}"

  # -- Sprat.Orchestrator scripts (test/sprat/orchestrator_test.exs) --------

  @doc """
  Scripts model id `"stub-idea-delivery"` through Idea's Intake -> Research
  -> Analysis -> Directions -> [user choice] -> Recommendation -> Delivery
  stages. Each stage gets one `write_artifact` tool-call turn (Research
  and Delivery write more than one deliverable in a single turn) followed
  by a final-text turn. Every artifact's content satisfies
  `Sprat.Workflow.ArtifactSchema.validate/2` for its type, so every
  stage's gate passes on the first attempt.

  Recommendation's `recommendation_memo` cites source id `"src_test_1"` as
  evidence (`Sprat.Workflow.Gate.check/3`'s `:recommendation_to_delivery`
  requires evidence to cite a source id that actually exists) — callers
  resuming past Directions must first record a source with that exact id,
  e.g. via `Sprat.Store.Sources.record(store, mission.id, %{id:
  "src_test_1", url: ..., source_type: ...})`.

  Returns `Sprat.StubModel` (the model module to pass as `model_mod:`) —
  pass `model_id: "stub-idea-delivery"` alongside it.
  """
  def scripted_for_idea_delivery do
    model_id = "stub-idea-delivery"

    {:ok, _} =
      start_script(model_id, [
        tool_call_turn([
          write_artifact_call("call_intake", "intake_summary", %{
            "objective" => "gym booking software",
            "depth" => "quick",
            "open_questions" => ["none"]
          })
        ]),
        final_turn("Intake done."),
        tool_call_turn([
          write_artifact_call("call_research_memo", "research_memo", %{
            "summary" => "Existing gym booking tools are clunky.",
            "claims" => [%{"text" => "users want fewer taps", "is_assumption" => true}],
            "limitations" => "no live web search available"
          }),
          write_artifact_call("call_source_register", "source_register", %{
            "sources" => [
              %{"title" => "competitor app store page", "url" => "https://example.com/app"}
            ]
          })
        ]),
        final_turn("Research done."),
        tool_call_turn([
          write_artifact_call("call_assumptions", "assumption_register", %{
            "assumptions" => [%{"text" => "users will pay monthly", "risk" => "high"}]
          })
        ]),
        final_turn("Analysis done."),
        tool_call_turn([
          write_artifact_call("call_directions", "product_directions", %{
            "directions" => [
              %{
                "customer" => "small gym owners",
                "problem" => "manual booking spreadsheets",
                "value" => "fewer no-shows",
                "scope" => "single-location booking calendar",
                "validation_approach" => "5 pilot gyms for 2 weeks"
              }
            ]
          })
        ]),
        final_turn("Directions ready.")
        | recommendation_and_brief_turns()
      ])

    __MODULE__
  end

  defp recommendation_and_brief_turns do
    [
      tool_call_turn([
        write_artifact_call("call_recommendation", "recommendation_memo", %{
          "recommendation" => "go",
          "evidence" => ["src_test_1"],
          "tradeoffs" => "limited to a single location for the pilot"
        })
      ]),
      final_turn("Recommendation done."),
      tool_call_turn([
        write_artifact_call("call_brief", "product_brief", %{
          "problem" => "manual booking spreadsheets",
          "customer" => "small gym owners",
          "mvp_scope" => "single-location booking calendar"
        }),
        write_artifact_call("call_validation_plan", "validation_plan", %{
          "experiments" => [
            %{
              "assumption" => "users will pay monthly",
              "participant_criteria" => "5 pilot gyms",
              "method" => "in-app trial",
              "budget" => "$500",
              "duration" => "2 weeks",
              "success_threshold" => "3 of 5 gyms convert",
              "failure_threshold" => "0 of 5 gyms convert",
              "decision" => "scale or pivot"
            }
          ]
        })
      ]),
      final_turn("Delivery done.")
    ]
  end

  @doc """
  Scripts model id `"stub-invalid-research"` through Idea's Intake stage
  (valid, so Research is reached) then Research, over and over, always
  writing a `research_memo` with empty content — missing every field the
  schema requires — so every Research attempt fails its gate. Scripted for
  3 Research attempts' worth of turns even though the review-round cap
  (`@review_rounds = 1`) only ever consumes 2, so the script never runs
  dry regardless of exactly how many attempts the orchestrator makes.
  Returns `Sprat.StubModel` — pass `model_id: "stub-invalid-research"`
  alongside it.
  """
  def always_writes_invalid_research_memo do
    model_id = "stub-invalid-research"

    invalid_research_attempt = [
      tool_call_turn([write_artifact_call("call_bad_memo", "research_memo", %{})]),
      final_turn("Here is my research.")
    ]

    responses =
      [
        tool_call_turn([
          write_artifact_call("call_intake", "intake_summary", %{
            "objective" => "gym booking software",
            "depth" => "quick",
            "open_questions" => ["none"]
          })
        ]),
        final_turn("Intake done.")
      ] ++ List.flatten(List.duplicate(invalid_research_attempt, 3))

    {:ok, _} = start_script(model_id, responses)

    __MODULE__
  end

  @doc """
  Scripts `model_id` (caller picks it — the Orchestrator's `:quick` Idea
  template auto-advances past a completed stage, so a run started from
  this script keeps calling the model through Research/Analysis/Directions
  and a shared, reused `model_id` would race a concurrent test's script;
  see the callers in orchestrator_test.exs) to call `web_fetch` on `url`
  (not pre-approved, unless it's literally in the mission's own submitted
  text — see `Sprat.Orchestrator.user_supplied_urls/1`), then — once the
  loop is resumed, whether approved or denied — writes `intake_summary`
  and finishes Intake, then completes Research/Analysis/Directions exactly
  like `scripted_for_idea_delivery/0` (the template stops there for the
  user-choice point — no further model calls happen after that). Exercises
  `Sprat.Orchestrator.settle_stage/13`'s `{:needs_approval, ...}` clause
  end to end (pause, resume, gate pass, and the rest of the walk).
  Returns `Sprat.StubModel`.
  """
  def needs_fetch_approval(url \\ "https://example.com/x", model_id \\ "stub-needs-approval") do
    {:ok, _} =
      start_script(
        model_id,
        [
          tool_call_turn([
            %{id: "call_fetch", name: "web_fetch", arguments: %{"url" => url}}
          ]),
          tool_call_turn([
            write_artifact_call("call_intake", "intake_summary", %{
              "objective" => "gym booking software",
              "depth" => "quick",
              "open_questions" => ["none"]
            })
          ]),
          final_turn("Intake done.")
        ] ++ research_analysis_directions_turns()
      )

    __MODULE__
  end

  # Research → Analysis → Directions, identical to the corresponding
  # section of `scripted_for_idea_delivery/0` — duplicated rather than
  # shared so a change to one script's fixture data can't silently ripple
  # into the other's expectations.
  defp research_analysis_directions_turns do
    [
      tool_call_turn([
        write_artifact_call("call_research_memo", "research_memo", %{
          "summary" => "Existing gym booking tools are clunky.",
          "claims" => [%{"text" => "users want fewer taps", "is_assumption" => true}],
          "limitations" => "no live web search available"
        }),
        write_artifact_call("call_source_register", "source_register", %{
          "sources" => [
            %{"title" => "competitor app store page", "url" => "https://example.com/app"}
          ]
        })
      ]),
      final_turn("Research done."),
      tool_call_turn([
        write_artifact_call("call_assumptions", "assumption_register", %{
          "assumptions" => [%{"text" => "users will pay monthly", "risk" => "high"}]
        })
      ]),
      final_turn("Analysis done."),
      tool_call_turn([
        write_artifact_call("call_directions", "product_directions", %{
          "directions" => [
            %{
              "customer" => "small gym owners",
              "problem" => "manual booking spreadsheets",
              "value" => "fewer no-shows",
              "scope" => "single-location booking calendar",
              "validation_approach" => "5 pilot gyms for 2 weeks"
            }
          ]
        })
      ]),
      final_turn("Directions ready.")
    ]
  end

  @doc """
  Scripts model id `"stub-no-progress"` to call the `calculate` tool
  forever instead of writing an artifact or recording a source — a
  `stop_reason: :tool_calls` response is the only kind that makes
  `Sprat.Agent.Loop` continue to another turn (a plain chat reply ends
  the loop immediately with `{:ok, ...}`), so this is what "chats without
  making progress for several turns" has to look like here. Neither the
  mission's source count nor any artifact's version changes, so
  `Sprat.Orchestrator`'s stall detector (docs/spec-v1.md §8) is the only
  thing that can stop the stage. Scripted well past the 3-turn stall
  threshold (10 turns) so the script never runs dry regardless of exactly
  when the detector trips. Returns `Sprat.StubModel` — pass `model_id:
  "stub-no-progress"` alongside it.
  """
  def always_chats_without_progress do
    model_id = "stub-no-progress"

    calculate_turn =
      tool_call_turn([
        %{id: "call_calc", name: "calculate", arguments: %{"expression" => "1 + 1"}}
      ])

    {:ok, _} = start_script(model_id, List.duplicate(calculate_turn, 10))

    __MODULE__
  end

  @doc """
  Scripts model id `"stub-stall-then-recover"` to stall Intake exactly
  (3 consecutive no-progress turns — see `always_chats_without_progress/0`'s
  comment on why that's the exact shape a stall needs), then — for
  whichever stage runs next, whether that's a retried Intake or, after a
  skip, Research — plays a valid Research → Analysis → Directions script
  identical to `scripted_for_idea_delivery/0`'s. Exercises
  `Sprat.Orchestrator.offer_recovery/12`'s retry/skip paths end to end: the
  mission keeps going with real, gate-passing stages after the recovery
  choice. Returns `Sprat.StubModel` — pass `model_id:
  "stub-stall-then-recover"` alongside it.
  """
  def stalls_intake_then_recovers do
    model_id = "stub-stall-then-recover"

    calculate_turn =
      tool_call_turn([
        %{id: "call_calc", name: "calculate", arguments: %{"expression" => "1 + 1"}}
      ])

    {:ok, _} =
      start_script(
        model_id,
        List.duplicate(calculate_turn, 3) ++ research_analysis_directions_turns()
      )

    __MODULE__
  end

  @doc """
  Same Intake stall as `stalls_intake_then_recovers/0`, but scripted all
  the way through Recommendation and Delivery too (identical turns to
  `scripted_for_idea_delivery/0`'s, past Directions) — for a skip-then-
  deliver end-to-end test: the mission reaches "Mission delivered" with
  Intake's real outcome still `:skipped`, not lost along the way. Like
  `scripted_for_idea_delivery/0`, `recommendation_memo` cites source id
  `"src_test_1"` — the caller must record that source before resuming past
  Directions. Returns `Sprat.StubModel` — pass `model_id:
  "stub-skip-then-deliver"` alongside it.
  """
  def stalls_intake_then_skips_to_delivery do
    model_id = "stub-skip-then-deliver"

    calculate_turn =
      tool_call_turn([
        %{id: "call_calc", name: "calculate", arguments: %{"expression" => "1 + 1"}}
      ])

    {:ok, _} =
      start_script(
        model_id,
        List.duplicate(calculate_turn, 3) ++
          research_analysis_directions_turns() ++ recommendation_and_brief_turns()
      )

    __MODULE__
  end

  @doc """
  Scripts model id `"stub-retry-recovers"` through a valid Intake, then
  Research failing its gate for both bounded attempts (identical to
  `always_writes_invalid_research_memo/0`'s Research portion) so Research
  is left `:failed` and `offer_recovery/12` fires — then, for the retried
  Research (a brand-new task, fresh attempt count), plays a valid Research
  → Analysis → Directions script so the retry can actually succeed.
  Returns `Sprat.StubModel` — pass `model_id: "stub-retry-recovers"`
  alongside it.
  """
  def retry_recovers_research_stage do
    model_id = "stub-retry-recovers"

    invalid_research_attempt = [
      tool_call_turn([write_artifact_call("call_bad_memo", "research_memo", %{})]),
      final_turn("Here is my research.")
    ]

    responses =
      [
        tool_call_turn([
          write_artifact_call("call_intake", "intake_summary", %{
            "objective" => "gym booking software",
            "depth" => "quick",
            "open_questions" => ["none"]
          })
        ]),
        final_turn("Intake done.")
      ] ++
        List.flatten(List.duplicate(invalid_research_attempt, 2)) ++
        research_analysis_directions_turns()

    {:ok, _} = start_script(model_id, responses)

    __MODULE__
  end

  # -- Sprat.Workflow.Build (test/sprat/workflow/build_test.exs) ------------

  @doc """
  Scripts `model_id` through `Sprat.Workflow.Build`'s :technical_design
  stage: one `write_artifact` turn producing a valid, gate-passing
  `technical_design` for the `elixir-phoenix` profile, then a final-text
  turn. The template stops there for checkpoint 1 — no further model
  calls happen unless the caller resumes with a "revise" answer, which
  re-runs this same stage, so this script queues `attempts` copies of the
  same turn pair to survive being consumed more than once. Returns
  `Sprat.StubModel` — pass a unique `model_id` alongside it (tests run
  `async: false` but still shouldn't share a script across cases).
  """
  def scripted_for_build_design(model_id, attempts \\ 1) do
    design_turn = [
      tool_call_turn([
        write_artifact_call("call_design", "technical_design", %{
          "profile" => "elixir-phoenix",
          "data_model" => %{
            "entities" => [
              %{"name" => "Gym", "fields" => ["name", "address"]},
              %{"name" => "Booking", "fields" => ["gym_id", "starts_at"]}
            ],
            "relations" => [%{"from" => "Gym", "to" => "Booking", "kind" => "has_many"}]
          },
          "components" => ["Bookings context", "web (LiveView) layer"],
          "external_services" => [],
          "excluded_scope" => [
            %{"item" => "payments", "reason" => "not in the brief's MVP boundary"}
          ],
          "estimated_cost" => "~$5 in model spend (estimate)"
        })
      ]),
      final_turn("Design ready.")
    ]

    responses = List.flatten(List.duplicate(design_turn, attempts))
    {:ok, _} = start_script(model_id, responses)
    __MODULE__
  end

  defp write_artifact_call(id, type, content),
    do: %{id: id, name: "write_artifact", arguments: %{"type" => type, "content" => content}}

  defp tool_call_turn(tool_calls) do
    %{content: nil, tool_calls: tool_calls, stop_reason: :tool_calls, usage: %{}, raw: %{}}
  end

  defp final_turn(text) do
    %{content: text, tool_calls: [], stop_reason: :stop, usage: %{}, raw: %{}}
  end
end
