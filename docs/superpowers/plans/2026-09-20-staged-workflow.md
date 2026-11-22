# Staged Research Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Sprat's single-agent-run mission path with a staged, gated workflow machinery for one role (§5/§8/§13 of the spec) — while keeping the existing quick-question path cheap and untouched.

**Architecture:** Workflow templates are pure data (`Sprat.Workflow.Template`). `Sprat.Orchestrator` is a `GenServer`, one per mission, that walks a template stage by stage: create a `task` row per stage (reusing `Sprat.Store.Tasks`/`TaskState`), build a context package (generalising `Sprat.Mission.build_context/7`), run `Sprat.Agent.Loop` with a stage-specific prompt and a `write_artifact` tool restricted to that stage's deliverable types, run the stage's gate (`Sprat.Workflow.Gate`, pure), and advance/retry/stop. `/idea` and `/research` start an Orchestrator; a plain message still goes straight to `Sprat.Mission` (unchanged). Every task-state change is written through `Tasks.transition/4` (state + event, one transaction) exactly as `Sprat.Mission` already does — the Orchestrator does not invent a second way to change task state.

**Tech Stack:** Elixir/OTP, SQLite via `exqlite`, existing `Sprat.Agent.Loop`/`Sprat.Model`, ExUnit + StreamData (already a dep).

**Spec:** `docs/spec-v1.md` (§4, §5, §6, §8, §13), `docs/design/tui-zones.md` (Mission zone)

## Global Constraints

- One role runs every stage. Which role runs a stage is a field (`:role`) on the stage struct, defaulting to `"researcher"` — never hardcoded in the Orchestrator. No `request_task`, no delegation, no parallel researchers.
- A plain submission (no `/idea`, `/research`, or explicit confirmed request) must keep using `Sprat.Mission.start/3` unchanged — proportionate work (§3).
- Every task-state transition goes through `Sprat.Store.Tasks.transition/4` (state + event in one SQLite transaction) — never a raw `UPDATE`.
- Gates are pure functions: code checks artifact existence/schema/source references; an LLM call (via the stage's own agent turn, not a second hidden call) only judges the specific content-quality checks the spec names (unlabelled unsourced claims). A failing gate always names the specific missing item.
- No web search tool exists. The research stage prompt must say "no live search" and rely on user-supplied URLs and links found on fetched pages, per §7.
- Money: `Decimal` only, never floats — matches `Sprat.Budget`/`Sprat.Model.Pricing` already in the codebase.
- `mix format --check-formatted` and `mix compile --warnings-as-errors` must stay clean after every task.

---

## File Structure

New:
- `lib/sprat/workflow/template.ex` — stage/template structs
- `lib/sprat/workflow/idea.ex` — the idea-shaping template (§5.A)
- `lib/sprat/workflow/opportunity.ex` — the opportunity-discovery template (§5.B)
- `lib/sprat/workflow/artifact_schema.ex` — per-artifact-type required-field schemas (pure)
- `lib/sprat/workflow/gate.ex` — pure gate checks (§5 Gates table)
- `lib/sprat/workflow/scorecard.ex` — pure scorecard arithmetic (§6)
- `lib/sprat/store/artifacts.ex` — CRUD for `artifacts`/`artifact_versions` (tables already exist, migration v1)
- `lib/sprat/store/decisions.ex` — CRUD for `decisions` (table already exists)
- `lib/sprat/agent/tools/write_artifact.ex` — the `write_artifact` tool, type-restricted per task
- `lib/sprat/orchestrator.ex` — the staged-mission `GenServer`
- `lib/sprat/orchestrator_supervisor.ex` — `DynamicSupervisor` for one Orchestrator per staged mission
- Tests: `test/sprat/workflow/*_test.exs`, `test/sprat/store/artifacts_test.exs`, `test/sprat/store/decisions_test.exs`, `test/sprat/agent/tools/write_artifact_test.exs`, `test/sprat/orchestrator_test.exs`

Modified:
- `lib/sprat/session/commands.ex` — `/idea`, `/research`, `/depth` dispatch to the Orchestrator instead of (or in addition to) plain `Sprat.Mission`
- `lib/sprat/application.ex` — add `OrchestratorSupervisor` to the tree
- `lib/sprat/terminal/zones/inspector.ex` — add an `:artifacts` tab
- `lib/sprat/store/recovery.ex` — resume must skip re-running a completed stage (task-level recovery already handles this; verify/extend for stage granularity)

---

### Task 1: `Sprat.Workflow.Template` — stage and template structs

**Files:**
- Create: `lib/sprat/workflow/template.ex`
- Test: `test/sprat/workflow/template_test.exs`

**Interfaces:**
- Produces: `%Sprat.Workflow.Template.Stage{id:, title:, role:, prompt:, required_inputs:, deliverables:, gate:, limits:}` and `%Sprat.Workflow.Template{id:, title:, stages: [Stage.t()]}`. `deliverables` is a list of artifact-type atoms (e.g. `[:research_memo, :source_register]`). `gate` is an atom naming a `Sprat.Workflow.Gate` function of arity 1 (e.g. `:research_to_analysis`). `limits` is `%{wall_seconds:, model_calls:, tokens:}` (defaults filled by depth, Task 3).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sprat.Workflow.TemplateTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.Template

  test "stage/1 builds a stage struct with all fields required" do
    stage =
      Template.stage(
        id: :intake,
        title: "Intake",
        role: "researcher",
        prompt: "restate the idea",
        required_inputs: [],
        deliverables: [:intake_summary],
        gate: :intake_to_research,
        limits: %{wall_seconds: 300, model_calls: 20, tokens: 200_000}
      )

    assert %Template.Stage{id: :intake, deliverables: [:intake_summary]} = stage
  end

  test "template/1 requires at least one stage and unique stage ids" do
    stage = fn id -> Template.stage(id: id, title: "x", role: "researcher", prompt: "p",
      required_inputs: [], deliverables: [], gate: nil, limits: %{}) end

    assert %Template{id: :t, stages: [_, _]} =
             Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:b)])

    assert_raise ArgumentError, fn ->
      Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:a)])
    end

    assert_raise ArgumentError, fn -> Template.new(id: :t, title: "T", stages: []) end
  end

  test "stage_after/2 and first_stage/1 walk the template in order" do
    stage = fn id -> Template.stage(id: id, title: "x", role: "researcher", prompt: "p",
      required_inputs: [], deliverables: [], gate: nil, limits: %{}) end

    template = Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:b), stage.(:c)])

    assert Template.first_stage(template).id == :a
    assert Template.stage_after(template, :a).id == :b
    assert Template.stage_after(template, :c) == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/workflow/template_test.exs`
Expected: FAIL — `Sprat.Workflow.Template` undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Workflow.Template do
  @moduledoc """
  Pure data shape for a workflow template (docs/spec-v1.md §5): an ordered
  list of stages. "Which role runs a stage is data on the stage
  definition" (build brief, scope decisions) — `Sprat.Orchestrator` never
  hardcodes a role; it reads `stage.role`. Adding PM/Analyst later is a
  change to `Sprat.Workflow.Idea`/`Opportunity`, not to the Orchestrator.
  """

  defmodule Stage do
    @moduledoc "One stage: who runs it, what it needs, what it must produce, and its gate."

    @enforce_keys [:id, :title, :role, :prompt, :required_inputs, :deliverables, :gate, :limits]
    defstruct [:id, :title, :role, :prompt, :required_inputs, :deliverables, :gate, :limits]

    @type t :: %__MODULE__{
            id: atom(),
            title: String.t(),
            role: String.t(),
            prompt: String.t(),
            required_inputs: [atom()],
            deliverables: [atom()],
            gate: atom() | nil,
            limits: map()
          }
  end

  @enforce_keys [:id, :title, :stages]
  defstruct [:id, :title, :stages]

  @type t :: %__MODULE__{id: atom(), title: String.t(), stages: [Stage.t()]}

  @doc "Builds one stage. Raises on missing required keys (via `@enforce_keys`)."
  def stage(attrs), do: struct!(Stage, attrs)

  @doc "Builds a template. Raises if `stages` is empty or has duplicate ids."
  def new(attrs) do
    template = struct!(__MODULE__, attrs)

    if template.stages == [] do
      raise ArgumentError, "template #{template.id} has no stages"
    end

    ids = Enum.map(template.stages, & &1.id)

    if length(ids) != length(Enum.uniq(ids)) do
      raise ArgumentError, "template #{template.id} has duplicate stage ids: #{inspect(ids)}"
    end

    template
  end

  @doc "The first stage of a template."
  def first_stage(%__MODULE__{stages: [first | _]}), do: first

  @doc "The stage after `stage_id`, or `nil` if `stage_id` is the last stage."
  def stage_after(%__MODULE__{stages: stages}, stage_id) do
    stages
    |> Enum.drop_while(&(&1.id != stage_id))
    |> Enum.drop(1)
    |> case do
      [next | _] -> next
      [] -> nil
    end
  end

  @doc "Finds a stage by id, or `nil`."
  def find_stage(%__MODULE__{stages: stages}, stage_id), do: Enum.find(stages, &(&1.id == stage_id))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/workflow/template_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/workflow/template.ex test/sprat/workflow/template_test.exs
git commit -m "Add Sprat.Workflow.Template stage/template structs"
```

---

### Task 2: `Sprat.Workflow.ArtifactSchema` — required-field schemas per artifact type

**Files:**
- Create: `lib/sprat/workflow/artifact_schema.ex`
- Test: `test/sprat/workflow/artifact_schema_test.exs`

**Interfaces:**
- Consumes: nothing (pure, no dependency on Task 1).
- Produces: `Sprat.Workflow.ArtifactSchema.validate(type :: atom(), content :: map()) :: :ok | {:error, [String.t()]}` — used by `Sprat.Workflow.Gate` (Task 4) and by the `write_artifact` tool (Task 6).

The ten artifact types named in the build brief: `:intake_summary, :research_memo, :source_register, :competitor_matrix, :assumption_register, :product_directions, :opportunity_scorecard, :recommendation_memo, :product_brief, :validation_plan`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sprat.Workflow.ArtifactSchemaTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.ArtifactSchema

  test "research_memo requires summary, claims and limitations" do
    assert {:error, errors} = ArtifactSchema.validate(:research_memo, %{})
    assert "summary" in errors
    assert "claims" in errors
    assert "limitations" in errors

    assert :ok =
             ArtifactSchema.validate(:research_memo, %{
               "summary" => "x",
               "claims" => [%{"text" => "y", "source_ids" => ["src_1"], "confidence" => "high"}],
               "limitations" => "no live search"
             })
  end

  test "product_directions requires 1-3 directions, each with the required fields" do
    assert {:error, errors} = ArtifactSchema.validate(:product_directions, %{"directions" => []})
    assert Enum.any?(errors, &(&1 =~ "at least one direction"))

    too_many = for n <- 1..4, do: direction("d#{n}")

    assert {:error, errors} =
             ArtifactSchema.validate(:product_directions, %{"directions" => too_many})

    assert Enum.any?(errors, &(&1 =~ "at most three"))

    assert :ok = ArtifactSchema.validate(:product_directions, %{"directions" => [direction("d1")]})
  end

  defp direction(name) do
    %{
      "customer" => name,
      "problem" => "p",
      "value" => "v",
      "scope" => "s",
      "validation_approach" => "a"
    }
  end

  test "recommendation_memo requires a recommendation in the fixed set, cited evidence" do
    assert {:error, errors} =
             ArtifactSchema.validate(:recommendation_memo, %{"recommendation" => "maybe"})

    assert Enum.any?(errors, &(&1 =~ "recommendation"))

    assert :ok =
             ArtifactSchema.validate(:recommendation_memo, %{
               "recommendation" => "validate_first",
               "evidence" => ["src_1"],
               "tradeoffs" => "t"
             })
  end

  test "unknown artifact type is an error, not a crash" do
    assert {:error, ["unknown artifact type: bogus"]} = ArtifactSchema.validate(:bogus, %{})
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/workflow/artifact_schema_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Workflow.ArtifactSchema do
  @moduledoc """
  Pure per-artifact-type required-field checks (docs/spec-v1.md §5 Gates
  table: "the required artifacts exist, validate against their schema").
  `content` is the artifact's decoded JSON body (a map with string keys —
  it comes back off `write_artifact`'s tool arguments and off
  `Sprat.Store.Artifacts`' JSON-decoded `content` column, both string-keyed).

  Deliberately not a general JSON-Schema engine (ponytail: ten fixed
  shapes, hand-written checks are shorter and give better error text than
  a schema-validator dependency would for ten call sites).
  """

  @recommendations ~w(go revise validate_first stop)

  @doc "`:ok` or `{:error, [reason, ...]}` — every missing/invalid field named, not just the first."
  def validate(:intake_summary, content) do
    require_fields(content, ~w(objective depth open_questions))
  end

  def validate(:research_memo, content) do
    require_fields(content, ~w(summary claims limitations))
  end

  def validate(:source_register, content) do
    require_fields(content, ~w(sources))
  end

  def validate(:competitor_matrix, content) do
    require_fields(content, ~w(competitors))
  end

  def validate(:assumption_register, content) do
    case require_fields(content, ~w(assumptions)) do
      :ok -> validate_ranked(content["assumptions"])
      error -> error
    end
  end

  def validate(:product_directions, content) do
    case require_fields(content, ~w(directions)) do
      :ok -> validate_directions(content["directions"])
      error -> error
    end
  end

  def validate(:opportunity_scorecard, content) do
    require_fields(content, ~w(dimensions total))
  end

  def validate(:recommendation_memo, content) do
    with :ok <- require_fields(content, ~w(recommendation evidence tradeoffs)) do
      validate_recommendation(content["recommendation"])
    end
  end

  def validate(:product_brief, content) do
    require_fields(content, ~w(problem customer mvp_scope))
  end

  def validate(:validation_plan, content) do
    case require_fields(content, ~w(experiments)) do
      :ok -> validate_experiments(content["experiments"])
      error -> error
    end
  end

  def validate(type, _content), do: {:error, ["unknown artifact type: #{type}"]}

  defp require_fields(content, fields) do
    missing = Enum.filter(fields, fn f -> blank?(Map.get(content, f)) end)
    if missing == [], do: :ok, else: {:error, missing}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{} = m) when map_size(m) == 0, do: true
  defp blank?(_), do: false

  defp validate_ranked(assumptions) when is_list(assumptions) do
    if Enum.any?(assumptions, &Map.has_key?(&1, "risk")),
      do: :ok,
      else: {:error, ["no assumption is ranked by risk"]}
  end

  defp validate_ranked(_), do: {:error, ["assumptions must be a list"]}

  defp validate_directions(directions) when is_list(directions) do
    required = ~w(customer problem value scope validation_approach)

    cond do
      directions == [] ->
        {:error, ["at least one direction is required"]}

      length(directions) > 3 ->
        {:error, ["at most three directions are allowed, got #{length(directions)}"]}

      true ->
        errors =
          directions
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {d, i} ->
            Enum.filter(required, &blank?(Map.get(d, &1)))
            |> Enum.map(&"direction #{i} missing #{&1}")
          end)

        if errors == [], do: :ok, else: {:error, errors}
    end
  end

  defp validate_directions(_), do: {:error, ["directions must be a list"]}

  defp validate_recommendation(rec) when rec in @recommendations, do: :ok

  defp validate_recommendation(other),
    do:
      {:error,
       ["recommendation must be one of #{Enum.join(@recommendations, ", ")}, got #{inspect(other)}"]}

  defp validate_experiments(experiments) when is_list(experiments) do
    required = ~w(assumption participant_criteria method budget duration success_threshold failure_threshold decision)

    if experiments == [] do
      {:error, ["at least one experiment is required"]}
    else
      errors =
        experiments
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {e, i} ->
          Enum.filter(required, &blank?(Map.get(e, &1)))
          |> Enum.map(&"experiment #{i} missing #{&1}")
        end)

      if errors == [], do: :ok, else: {:error, errors}
    end
  end

  defp validate_experiments(_), do: {:error, ["experiments must be a list"]}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/workflow/artifact_schema_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/workflow/artifact_schema.ex test/sprat/workflow/artifact_schema_test.exs
git commit -m "Add Sprat.Workflow.ArtifactSchema per-type validation"
```

---

### Task 3: `Sprat.Workflow.Idea` and `Sprat.Workflow.Opportunity` — the two templates + depth limits

**Files:**
- Create: `lib/sprat/workflow/idea.ex`
- Create: `lib/sprat/workflow/opportunity.ex`
- Create: `lib/sprat/workflow/depth.ex`
- Test: `test/sprat/workflow/idea_test.exs`
- Test: `test/sprat/workflow/opportunity_test.exs`
- Test: `test/sprat/workflow/depth_test.exs`

**Interfaces:**
- Consumes: `Sprat.Workflow.Template.new/1`, `.stage/1` (Task 1).
- Produces: `Sprat.Workflow.Idea.template(depth :: :quick | :standard | :deep) :: Template.t()`, same for `Opportunity`. `Sprat.Workflow.Depth.limits(depth) :: %{wall_seconds:, model_calls:, tokens:}` and `Sprat.Workflow.Depth.source_target(depth) :: {min :: integer, max :: integer | nil}`.

- [ ] **Step 1: Write the failing test (depth)**

```elixir
defmodule Sprat.Workflow.DepthTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.Depth

  test "limits/1 matches the §5 depth table wall-time defaults" do
    assert Depth.limits(:quick).wall_seconds == 300
    assert Depth.limits(:standard).wall_seconds == 1200
    assert Depth.limits(:deep).wall_seconds == 3600
  end

  test "source_target/1 matches the §5 depth table" do
    assert Depth.source_target(:quick) == {5, 10}
    assert Depth.source_target(:standard) == {15, 30}
    assert Depth.source_target(:deep) == {40, nil}
  end

  test "unknown depth raises rather than silently defaulting" do
    assert_raise FunctionClauseError, fn -> Depth.limits(:bogus) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/workflow/depth_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write minimal implementation (depth)**

```elixir
defmodule Sprat.Workflow.Depth do
  @moduledoc "Research depth → limits and source targets (docs/spec-v1.md §5 table)."

  @limits %{
    quick: %{wall_seconds: 300, model_calls: 40, tokens: 400_000},
    standard: %{wall_seconds: 1200, model_calls: 120, tokens: 1_200_000},
    deep: %{wall_seconds: 3600, model_calls: 300, tokens: 3_000_000}
  }

  @source_targets %{quick: {5, 10}, standard: {15, 30}, deep: {40, nil}}

  @doc "Per-stage wall-time/call/token limits for `depth`."
  def limits(depth) when depth in [:quick, :standard, :deep], do: Map.fetch!(@limits, depth)

  @doc "`{min, max}` target source count for `depth` — a guide, not a quota (§5)."
  def source_target(depth) when depth in [:quick, :standard, :deep],
    do: Map.fetch!(@source_targets, depth)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/workflow/depth_test.exs`
Expected: PASS

- [ ] **Step 5: Write the failing test (idea template)**

```elixir
defmodule Sprat.Workflow.IdeaTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.{Idea, Template}

  test "template/1 has the seven §5.A stages in order, single role" do
    template = Idea.template(:standard)

    assert Enum.map(template.stages, & &1.id) == [
             :intake,
             :research,
             :analysis,
             :directions,
             :recommendation,
             :delivery
           ]

    assert Enum.all?(template.stages, &(&1.role == "researcher"))
  end

  test "each stage's deliverables and gate match §5" do
    template = Idea.template(:standard)

    assert Template.find_stage(template, :intake).deliverables == [:intake_summary]
    assert Template.find_stage(template, :intake).gate == :intake_to_research

    assert Template.find_stage(template, :research).deliverables == [
             :research_memo,
             :source_register
           ]

    assert Template.find_stage(template, :research).gate == :research_to_analysis

    assert Template.find_stage(template, :analysis).deliverables == [:assumption_register]
    assert Template.find_stage(template, :analysis).gate == :analysis_gate

    assert Template.find_stage(template, :directions).deliverables == [:product_directions]

    assert Template.find_stage(template, :recommendation).deliverables == [
             :recommendation_memo
           ]

    assert Template.find_stage(template, :recommendation).gate == :recommendation_to_delivery

    assert Template.find_stage(template, :delivery).deliverables == [
             :product_brief,
             :validation_plan
           ]

    assert Template.find_stage(template, :delivery).gate == :delivery_gate
  end

  test "limits scale with depth" do
    quick = Idea.template(:quick)
    deep = Idea.template(:deep)
    assert Template.find_stage(quick, :research).limits.wall_seconds == 300
    assert Template.find_stage(deep, :research).limits.wall_seconds == 3600
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/sprat/workflow/idea_test.exs`
Expected: FAIL.

- [ ] **Step 7: Write minimal implementation (idea template)**

```elixir
defmodule Sprat.Workflow.Idea do
  @moduledoc """
  "Shape an idea" (docs/spec-v1.md §5.A): Intake → Research → Analysis →
  Directions → [user choice] → Recommendation → Delivery. One role
  (`"researcher"`) runs every stage in this build (build brief scope
  decision) — the `role` field exists on every stage precisely so a later
  build can hand `:directions`/`:recommendation`/`:delivery` to a PM
  role and `:research` to a Researcher role without touching
  `Sprat.Orchestrator`.
  """

  alias Sprat.Workflow.{Depth, Template}

  @role "researcher"

  def template(depth) when depth in [:quick, :standard, :deep] do
    limits = Depth.limits(depth)

    Template.new(
      id: :idea,
      title: "Shape an idea",
      stages: [
        Template.stage(
          id: :intake,
          title: "Intake",
          role: @role,
          prompt: intake_prompt(),
          required_inputs: [],
          deliverables: [:intake_summary],
          gate: :intake_to_research,
          limits: limits
        ),
        Template.stage(
          id: :research,
          title: "Research",
          role: @role,
          prompt: research_prompt(depth),
          required_inputs: [:intake_summary],
          deliverables: [:research_memo, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :analysis,
          title: "Analysis",
          role: @role,
          prompt: analysis_prompt(),
          required_inputs: [:research_memo, :source_register],
          deliverables: [:assumption_register],
          gate: :analysis_gate,
          limits: limits
        ),
        Template.stage(
          id: :directions,
          title: "Directions",
          role: @role,
          prompt: directions_prompt(),
          required_inputs: [:assumption_register],
          deliverables: [:product_directions],
          gate: nil,
          limits: limits
        ),
        Template.stage(
          id: :recommendation,
          title: "Recommendation",
          role: @role,
          prompt: recommendation_prompt(),
          required_inputs: [:product_directions],
          deliverables: [:recommendation_memo],
          gate: :recommendation_to_delivery,
          limits: limits
        ),
        Template.stage(
          id: :delivery,
          title: "Brief + validation plan",
          role: @role,
          prompt: delivery_prompt(),
          required_inputs: [:recommendation_memo],
          deliverables: [:product_brief, :validation_plan],
          gate: :delivery_gate,
          limits: limits
        )
      ]
    )
  end

  defp intake_prompt do
    "Restate the user's idea in your own words. Ask at most three questions that " <>
      "change direction: target customer, geography, constraints, intended outcome. " <>
      "Anything unanswered becomes an assumption, not a blocker. Write an " <>
      "intake_summary artifact with objective, depth and any open_questions."
  end

  defp research_prompt(depth) do
    {min, max} = Depth.source_target(depth)
    target = if max, do: "#{min}-#{max}", else: "#{min}+"

    "You have no live web search tool — only web_fetch on URLs the user gave you or " <>
      "that you find as links on a page you already fetched. Label every output " <>
      "\"no live research\" if you end up with no usable sources at all (docs/spec-v1.md " <>
      "§7). Study existing workflows, competitors, alternatives, complaints and " <>
      "counter-evidence. Target #{target} sources (a guide, not a quota). Record every " <>
      "source with record_source and every material claim with record_claim before " <>
      "writing your research_memo and source_register artifacts. An unlabelled, " <>
      "unsourced material claim will fail the gate."
  end

  defp analysis_prompt do
    "Separate recurring problems from anecdotes. Rank the riskiest assumptions in an " <>
      "assumption_register artifact, each assumption with a risk rating and why."
  end

  defp directions_prompt do
    "Propose up to three distinct product directions, each with customer, problem, " <>
      "value, smallest useful scope and a validation approach, as a product_directions " <>
      "artifact."
  end

  defp recommendation_prompt do
    "Recommend go, revise, validate_first or stop, with tradeoffs and cited evidence, " <>
      "as a recommendation_memo artifact."
  end

  defp delivery_prompt do
    "Write the product_brief (problem, customer, mvp_scope) and validation_plan " <>
      "(experiments: assumption tested, participant criteria, method, budget, " <>
      "duration, success/failure threshold, and the decision that follows each)."
  end
end
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mix test test/sprat/workflow/idea_test.exs`
Expected: PASS

- [ ] **Step 9: Write `Sprat.Workflow.Opportunity` the same way**

```elixir
defmodule Sprat.Workflow.Opportunity do
  @moduledoc """
  "Discover an opportunity" (docs/spec-v1.md §5.B): Intake → Landscape
  research → Hypotheses → Scoring → Counter-evidence → Recommendation →
  Validation plan → Delivery. Same single-role scope as `Sprat.Workflow.Idea`.
  """

  alias Sprat.Workflow.{Depth, Template}

  @role "researcher"

  def template(depth) when depth in [:quick, :standard, :deep] do
    limits = Depth.limits(depth)

    Template.new(
      id: :opportunity,
      title: "Discover an opportunity",
      stages: [
        Template.stage(
          id: :intake,
          title: "Intake",
          role: @role,
          prompt: "Restate the market question. Ask at most three direction-changing " <>
            "questions. Write an intake_summary artifact.",
          required_inputs: [],
          deliverables: [:intake_summary],
          gate: :intake_to_research,
          limits: limits
        ),
        Template.stage(
          id: :landscape,
          title: "Landscape research",
          role: @role,
          prompt: landscape_prompt(depth),
          required_inputs: [:intake_summary],
          deliverables: [:research_memo, :competitor_matrix, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :hypotheses,
          title: "Hypotheses",
          role: @role,
          prompt: "Propose 5-10 opportunity hypotheses grounded in the research memo, as " <>
            "an assumption_register artifact ranked by risk.",
          required_inputs: [:research_memo],
          deliverables: [:assumption_register],
          gate: :analysis_gate,
          limits: limits
        ),
        Template.stage(
          id: :scoring,
          title: "Scoring",
          role: @role,
          prompt: "Score the top 3 hypotheses against the §6 weighted dimensions as an " <>
            "opportunity_scorecard artifact (a 1-5 rating per dimension, cited evidence; " <>
            "unknown where unevidenced). You describe the ratings; the code computes totals.",
          required_inputs: [:assumption_register],
          deliverables: [:opportunity_scorecard],
          gate: nil,
          limits: limits
        ),
        Template.stage(
          id: :counter_evidence,
          title: "Counter-evidence",
          role: @role,
          prompt: "Actively look for evidence against the top-scored hypothesis (same " <>
            "no-live-search constraint as landscape research). Update research_memo and " <>
            "source_register with what you find, including if you find nothing.",
          required_inputs: [:opportunity_scorecard],
          deliverables: [:research_memo, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :recommendation,
          title: "Recommendation",
          role: @role,
          prompt: "Recommend go, revise, validate_first or stop, with tradeoffs and cited " <>
            "evidence, as a recommendation_memo artifact.",
          required_inputs: [:opportunity_scorecard],
          deliverables: [:recommendation_memo],
          gate: :recommendation_to_delivery,
          limits: limits
        ),
        Template.stage(
          id: :delivery,
          title: "Validation plan",
          role: @role,
          prompt: "Write the validation_plan artifact (experiments: assumption, " <>
            "participant criteria, method, budget, duration, success/failure threshold, " <>
            "decision).",
          required_inputs: [:recommendation_memo],
          deliverables: [:validation_plan],
          gate: :delivery_gate,
          limits: limits
        )
      ]
    )
  end

  defp landscape_prompt(depth) do
    {min, max} = Depth.source_target(depth)
    target = if max, do: "#{min}-#{max}", else: "#{min}+"

    "No live web search tool — only web_fetch on user-given URLs and links found on " <>
      "pages you've already fetched; label the output \"no live research\" if you end " <>
      "up empty-handed (§7). Target #{target} sources. Record every source and material " <>
      "claim before writing research_memo, competitor_matrix and source_register."
  end
end
```

- [ ] **Step 10: Write and run `test/sprat/workflow/opportunity_test.exs`** (same shape as Step 5's idea test, asserting the seven stage ids `[:intake, :landscape, :hypotheses, :scoring, :counter_evidence, :recommendation, :delivery]` and their deliverables/gates from the code above)

Run: `mix test test/sprat/workflow/opportunity_test.exs`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add lib/sprat/workflow/depth.ex lib/sprat/workflow/idea.ex lib/sprat/workflow/opportunity.ex \
  test/sprat/workflow/depth_test.exs test/sprat/workflow/idea_test.exs test/sprat/workflow/opportunity_test.exs
git commit -m "Add Idea/Opportunity workflow templates and depth limits"
```

---

### Task 4: `Sprat.Workflow.Gate` — pure gate checks (§5 Gates table)

**Files:**
- Create: `lib/sprat/workflow/gate.ex`
- Test: `test/sprat/workflow/gate_test.exs`

**Interfaces:**
- Consumes: `Sprat.Workflow.ArtifactSchema.validate/2` (Task 2). Takes plain data, not store structs, so it is unit-testable without a database: `artifacts :: %{atom() => map()}` (artifact type → its latest version's decoded content), `source_ids :: MapSet.t(String.t())` (ids known to exist in this mission).
- Produces: `Sprat.Workflow.Gate.check(gate_name :: atom(), artifacts, source_ids) :: :ok | {:error, [String.t()]}`. Called by `Sprat.Orchestrator` (Task 8) after a stage's deliverables are written.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sprat.Workflow.GateTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.Gate

  test "intake_to_research: objective, depth, open_questions must be present" do
    assert {:error, errors} = Gate.check(:intake_to_research, %{}, MapSet.new())
    assert Enum.any?(errors, &(&1 =~ "intake_summary"))

    artifacts = %{intake_summary: %{"objective" => "o", "depth" => "quick", "open_questions" => []}}
    assert :ok = Gate.check(:intake_to_research, artifacts, MapSet.new())
  end

  test "research_to_analysis: research_memo must exist and every claim must cite a real source" do
    assert {:error, errors} = Gate.check(:research_to_analysis, %{}, MapSet.new())
    assert Enum.any?(errors, &(&1 =~ "research_memo"))

    memo = %{
      "summary" => "s",
      "limitations" => "no live search",
      "claims" => [%{"text" => "c", "source_ids" => ["src_missing"], "confidence" => "high"}]
    }

    assert {:error, errors} =
             Gate.check(:research_to_analysis, %{research_memo: memo}, MapSet.new(["src_1"]))

    assert Enum.any?(errors, &(&1 =~ "src_missing"))

    ok_memo = put_in(memo, ["claims"], [
      %{"text" => "c", "source_ids" => ["src_1"], "confidence" => "high"}
    ])

    assert :ok =
             Gate.check(:research_to_analysis, %{research_memo: ok_memo}, MapSet.new(["src_1"]))
  end

  test "research_to_analysis: a claim marked is_assumption needs no source" do
    memo = %{
      "summary" => "s",
      "limitations" => "l",
      "claims" => [%{"text" => "c", "is_assumption" => true, "confidence" => "low"}]
    }

    assert :ok = Gate.check(:research_to_analysis, %{research_memo: memo}, MapSet.new())
  end

  test "analysis_gate: assumption_register must have at least one assumption ranked by risk" do
    assert {:error, _} = Gate.check(:analysis_gate, %{}, MapSet.new())

    ok = %{assumption_register: %{"assumptions" => [%{"text" => "a", "risk" => "high"}]}}
    assert :ok = Gate.check(:analysis_gate, ok, MapSet.new())
  end

  test "recommendation_to_delivery: names one of the four recommendations and cites evidence" do
    bad = %{recommendation_memo: %{"recommendation" => "maybe", "evidence" => [], "tradeoffs" => "t"}}
    assert {:error, _} = Gate.check(:recommendation_to_delivery, bad, MapSet.new())

    ok = %{
      recommendation_memo: %{
        "recommendation" => "go",
        "evidence" => ["src_1"],
        "tradeoffs" => "t"
      }
    }

    assert :ok = Gate.check(:recommendation_to_delivery, ok, MapSet.new(["src_1"]))
  end

  test "delivery_gate: all required artifacts present or explicitly marked incomplete" do
    assert {:error, _} = Gate.check(:delivery_gate, %{}, MapSet.new())

    ok = %{
      product_brief: %{"problem" => "p", "customer" => "c", "mvp_scope" => "m"},
      validation_plan: %{
        "experiments" => [
          %{
            "assumption" => "a",
            "participant_criteria" => "p",
            "method" => "m",
            "budget" => "b",
            "duration" => "d",
            "success_threshold" => "s",
            "failure_threshold" => "f",
            "decision" => "dec"
          }
        ]
      }
    }

    assert :ok = Gate.check(:delivery_gate, ok, MapSet.new())
  end

  test "delivery_gate accepts an artifact explicitly marked incomplete with a reason" do
    ok = %{
      product_brief: %{"incomplete" => true, "reason" => "user stopped after directions"},
      validation_plan: %{"incomplete" => true, "reason" => "user stopped after directions"}
    }

    assert :ok = Gate.check(:delivery_gate, ok, MapSet.new())
  end

  test "unknown gate is an error, not a crash" do
    assert {:error, ["unknown gate: bogus_gate"]} = Gate.check(:bogus_gate, %{}, MapSet.new())
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/workflow/gate_test.exs`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Workflow.Gate do
  @moduledoc """
  Pure gate checks (docs/spec-v1.md §5 Gates table): "the required
  artifacts exist, validate against their schema and reference existing
  sources. An LLM judges content quality; code judges completeness." This
  module is the code half — the completeness rule — and it always names
  the specific missing item (§10 "Gate result: ✓ or ✗ with the specific
  missing item"). The content-quality half (an unlabelled unsourced claim
  slipping past `is_assumption`) is the stage's own prompt asking the
  model to label honestly; this gate enforces the *structural* rule that
  every non-assumption claim's `source_ids` actually exist.

  `artifacts` maps artifact type atoms to that type's latest version's
  decoded content (string-keyed maps, straight off `Sprat.Store.Artifacts`
  or a stage's `write_artifact` calls). `source_ids` is the set of source
  ids that actually exist in this mission (`Sprat.Store.Sources.by_mission/2`
  ids) — passing this in rather than a store connection is what keeps this
  module pure and fast to test.
  """

  alias Sprat.Workflow.ArtifactSchema

  def check(:intake_to_research, artifacts, _source_ids) do
    require_artifact(artifacts, :intake_summary)
  end

  def check(:research_to_analysis, artifacts, source_ids) do
    with :ok <- require_artifact(artifacts, :research_memo) do
      check_claims_cite_sources(artifacts[:research_memo], source_ids)
    end
  end

  def check(:analysis_gate, artifacts, _source_ids) do
    require_artifact(artifacts, :assumption_register)
  end

  def check(:recommendation_to_delivery, artifacts, source_ids) do
    with :ok <- require_artifact(artifacts, :recommendation_memo) do
      check_evidence_cites_sources(artifacts[:recommendation_memo], source_ids)
    end
  end

  def check(:delivery_gate, artifacts, _source_ids) do
    [:product_brief, :validation_plan]
    |> Enum.map(&require_artifact(artifacts, &1))
    |> collect_errors()
  end

  def check(other, _artifacts, _source_ids), do: {:error, ["unknown gate: #{other}"]}

  # -- artifact existence + schema -----------------------------------------

  defp require_artifact(artifacts, type) do
    case Map.get(artifacts, type) do
      nil ->
        {:error, ["#{type} artifact does not exist"]}

      %{"incomplete" => true, "reason" => reason} when is_binary(reason) and reason != "" ->
        :ok

      content ->
        ArtifactSchema.validate(type, content)
        |> tag_errors(type)
    end
  end

  defp tag_errors(:ok, _type), do: :ok
  defp tag_errors({:error, errors}, type), do: {:error, Enum.map(errors, &"#{type}: #{&1}")}

  defp collect_errors(results) do
    errors = Enum.flat_map(results, fn
      :ok -> []
      {:error, errs} -> errs
    end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  # -- claim/evidence -> source existence ------------------------------------

  defp check_claims_cite_sources(memo, source_ids) do
    claims = Map.get(memo, "claims", [])

    missing =
      claims
      |> Enum.reject(&(&1["is_assumption"] == true))
      |> Enum.flat_map(fn claim ->
        ids = Map.get(claim, "source_ids", [])

        cond do
          ids == [] -> ["claim #{inspect(claim["text"])} has no source and is not labelled as an assumption"]
          true -> Enum.filter(ids, &(not MapSet.member?(source_ids, &1))) |> Enum.map(&"unknown source id: #{&1}")
        end
      end)

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp check_evidence_cites_sources(memo, source_ids) do
    ids = Map.get(memo, "evidence", [])
    missing = Enum.filter(ids, &(not MapSet.member?(source_ids, &1)))
    if missing == [], do: :ok, else: {:error, Enum.map(missing, &"unknown source id: #{&1}")}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/workflow/gate_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/workflow/gate.ex test/sprat/workflow/gate_test.exs
git commit -m "Add Sprat.Workflow.Gate pure gate checks"
```

---

### Task 5: `Sprat.Workflow.Scorecard` — §6 weighted scoring, unknowns, sensitivity

**Files:**
- Create: `lib/sprat/workflow/scorecard.ex`
- Test: `test/sprat/workflow/scorecard_test.exs`

**Interfaces:**
- Produces: `Sprat.Workflow.Scorecard.score(ratings :: %{atom() => 1..5 | :unknown}, weights \\ default_weights()) :: %{total: Decimal.t() | :unknown, coverage: float(), by_dimension: map()}` and `Sprat.Workflow.Scorecard.sensitivity(candidates :: [%{id:, ratings:}], weights) :: %{top_pick_stable?: boolean(), deltas: [map()]}`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sprat.Workflow.ScorecardTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Workflow.Scorecard

  test "default_weights/0 sums to 100" do
    total = Scorecard.default_weights() |> Map.values() |> Enum.sum()
    assert total == 100
  end

  test "score/2 computes a weighted total from code, not the model" do
    ratings = %{
      pain_severity: 5,
      willingness_to_pay: 4,
      buyer_reachability: 3,
      alternative_weakness: 3,
      feasibility: 4,
      unit_economics: 3,
      founder_advantage: 5
    }

    result = Scorecard.score(ratings)

    expected =
      Decimal.new(5) |> Decimal.mult(Decimal.new("0.20"))
      |> Decimal.add(Decimal.new(4) |> Decimal.mult(Decimal.new("0.20")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.15")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.15")))
      |> Decimal.add(Decimal.new(4) |> Decimal.mult(Decimal.new("0.10")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.10")))
      |> Decimal.add(Decimal.new(5) |> Decimal.mult(Decimal.new("0.10")))

    assert Decimal.equal?(result.total, expected)
    assert result.coverage == 1.0
  end

  test "unknown dimensions stay unknown, are excluded from the average, not scored as zero" do
    ratings = %{
      pain_severity: :unknown,
      willingness_to_pay: 4,
      buyer_reachability: 3,
      alternative_weakness: 3,
      feasibility: 4,
      unit_economics: 3,
      founder_advantage: 5
    }

    result = Scorecard.score(ratings)
    refute Decimal.equal?(result.total, Decimal.new(0))
    assert result.coverage < 1.0
    assert result.by_dimension.pain_severity == :unknown
  end

  test "all-unknown ratings produce total: :unknown, never zero and never an average" do
    ratings = Scorecard.default_weights() |> Map.keys() |> Map.new(&{&1, :unknown})
    assert %{total: :unknown, coverage: 0.0} = Scorecard.score(ratings)
  end

  test "sensitivity/2 reports whether ±5-point weight changes flip the top pick" do
    stable = [
      %{id: :a, ratings: %{pain_severity: 5, willingness_to_pay: 5, buyer_reachability: 5,
          alternative_weakness: 5, feasibility: 5, unit_economics: 5, founder_advantage: 5}},
      %{id: :b, ratings: %{pain_severity: 1, willingness_to_pay: 1, buyer_reachability: 1,
          alternative_weakness: 1, feasibility: 1, unit_economics: 1, founder_advantage: 1}}
    ]

    assert %{top_pick_stable?: true} = Scorecard.sensitivity(stable, Scorecard.default_weights())
  end

  property "score/2 total is always within [0, 5] when no dimension is unknown" do
    check all ratings <- rating_map() do
      %{total: total} = Scorecard.score(ratings)
      assert Decimal.compare(total, Decimal.new(0)) in [:gt, :eq]
      assert Decimal.compare(total, Decimal.new(5)) in [:lt, :eq]
    end
  end

  defp rating_map do
    dims = Scorecard.default_weights() |> Map.keys()
    dims |> Enum.map(&{&1, integer(1..5)}) |> Map.new() |> fixed_map()
  end

  defp fixed_map(kv_gens) do
    kv_gens
    |> Enum.reduce(constant(%{}), fn {k, gen}, acc ->
      bind(acc, fn m -> bind(gen, fn v -> constant(Map.put(m, k, v)) end) end)
    end)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/workflow/scorecard_test.exs`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Workflow.Scorecard do
  @moduledoc """
  Pure opportunity scorecard arithmetic (docs/spec-v1.md §6): "Scores are
  computed by code from the ratings, not by the model." Missing evidence
  is `:unknown` — excluded from the weighted average and never treated as
  zero. `total: :unknown` (not a partial average) when every dimension is
  unknown, since an average of nothing is not a score. Weight-sensitivity
  is computed here too, with no model call.
  """

  @default_weights %{
    pain_severity: 20,
    willingness_to_pay: 20,
    buyer_reachability: 15,
    alternative_weakness: 15,
    feasibility: 10,
    unit_economics: 10,
    founder_advantage: 10
  }

  def default_weights, do: @default_weights

  @doc """
  `ratings`: `%{dimension => 1..5 | :unknown}` for every key in `weights`.
  Returns `%{total:, coverage:, by_dimension:}`. `total` is a `Decimal` in
  `[0, 5]` re-normalised over the known dimensions' weights, or `:unknown`
  if every dimension is unknown. `coverage` is the fraction (float) of
  weight backed by a known rating.
  """
  def score(ratings, weights \\ @default_weights) do
    known = Enum.reject(weights, fn {dim, _w} -> ratings[dim] == :unknown end)
    known_weight = known |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    total_weight = weights |> Map.values() |> Enum.sum()

    total =
      if known_weight == 0 do
        :unknown
      else
        known
        |> Enum.reduce(Decimal.new(0), fn {dim, w}, acc ->
          rating = Decimal.new(ratings[dim])
          share = Decimal.div(Decimal.new(w), Decimal.new(known_weight))
          Decimal.add(acc, Decimal.mult(rating, share))
        end)
      end

    %{
      total: total,
      coverage: known_weight / total_weight,
      by_dimension: Map.new(weights, fn {dim, _w} -> {dim, ratings[dim]} end)
    }
  end

  @doc """
  Whether the top-scored candidate (by `score/2`'s total) stays on top
  under every ±5-point single-weight perturbation (docs/spec-v1.md §6:
  "reports whether ±5-point weight changes alter the top pick"), keeping
  the perturbed dimension's delta spread evenly across the rest so
  weights still sum to 100. `candidates`: `[%{id:, ratings:}]`.
  """
  def sensitivity(candidates, weights \\ @default_weights) do
    baseline_top = top_pick(candidates, weights)

    deltas =
      for dim <- Map.keys(weights), delta <- [-5, 5] do
        perturbed = perturb(weights, dim, delta)
        pick = top_pick(candidates, perturbed)
        %{dimension: dim, delta: delta, top_pick: pick, changed?: pick != baseline_top}
      end

    %{
      top_pick: baseline_top,
      top_pick_stable?: Enum.all?(deltas, &(not &1.changed?)),
      deltas: deltas
    }
  end

  defp top_pick(candidates, weights) do
    candidates
    |> Enum.map(fn c -> {c.id, score(c.ratings, weights).total} end)
    |> Enum.reject(fn {_id, total} -> total == :unknown end)
    |> Enum.max_by(fn {_id, total} -> total end, Decimal, fn -> nil end)
    |> case do
      {id, _total} -> id
      nil -> nil
    end
  end

  defp perturb(weights, dim, delta) do
    others = Map.keys(weights) -- [dim]
    spread = div(-delta, length(others))
    remainder = -delta - spread * length(others)

    weights
    |> Map.update!(dim, &(&1 + delta))
    |> then(fn w ->
      others
      |> Enum.with_index()
      |> Enum.reduce(w, fn {o, i}, acc ->
        bump = if i == 0, do: spread + remainder, else: spread
        Map.update!(acc, o, &(&1 + bump))
      end)
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/workflow/scorecard_test.exs`
Expected: PASS. Note: `Enum.max_by/4` with a custom sorter module requires a module implementing `Decimal`'s comparison via `compare/2` — Elixir 1.18+'s `Enum.max_by/4` accepts a `(term, term -> :lt | :eq | :gt)` sorter function too if `Decimal` (the module) doesn't work as a sorter here; if `mix test` fails on that line, replace `Decimal` with `&(Decimal.compare(&1, &2) != :lt)` as the sorter argument and re-run.

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/workflow/scorecard.ex test/sprat/workflow/scorecard_test.exs
git commit -m "Add Sprat.Workflow.Scorecard weighted scoring and sensitivity check"
```

---

### Task 6: `Sprat.Store.Artifacts` and `Sprat.Store.Decisions`

**Files:**
- Create: `lib/sprat/store/artifacts.ex`
- Create: `lib/sprat/store/decisions.ex`
- Test: `test/sprat/store/artifacts_test.exs`
- Test: `test/sprat/store/decisions_test.exs`

**Interfaces:**
- Consumes: `artifacts`/`artifact_versions`/`decisions` tables (already in `lib/sprat/store/migrations.ex`, migration version 1 — no new migration needed). `test/support/store_case.ex` for the store test harness (read it before writing tests — mirror the pattern `test/sprat/store/sources_test.exs`-equivalent files already use for `Sprat.Store.Sources`).
- Produces: `Sprat.Store.Artifacts.write(store, mission_id, %{type:, owning_role:, content:, created_by:}) :: {:ok, %{artifact: Artifacts.t(), version: integer()}}` (creates the `artifacts` row on first write for that mission+type, else bumps `latest_version`; always appends a row to `artifact_versions`). `Sprat.Store.Artifacts.latest(store, mission_id, type) :: map() | nil` (decoded content of the latest version, or `nil`). `Sprat.Store.Artifacts.latest_all(store, mission_id) :: %{atom() => map()}` (every artifact type that has a version, for feeding `Sprat.Workflow.Gate.check/3`). `Sprat.Store.Artifacts.by_mission(store, mission_id) :: [Artifacts.t()]`. `Sprat.Store.Decisions.record(store, mission_id, %{summary:, evidence_for:, evidence_against:}) :: {:ok, Decisions.t()}`, `Sprat.Store.Decisions.by_mission(store, mission_id) :: [Decisions.t()]`.

- [ ] **Step 1: Write the failing test (Artifacts)**

```elixir
defmodule Sprat.Store.ArtifactsTest do
  use ExUnit.Case, async: true
  import Sprat.StoreCase

  alias Sprat.Store.{Artifacts, Missions, Sessions}

  setup do
    store = start_store!()
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
    {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
    %{store: store, mission: mission}
  end

  test "write/3 creates the artifact on first write, version 1", %{store: store, mission: m} do
    {:ok, %{artifact: artifact, version: 1}} =
      Artifacts.write(store, m.id, %{
        type: :research_memo,
        owning_role: "researcher",
        content: %{"summary" => "s"},
        created_by: "researcher"
      })

    assert artifact.type == "research_memo"
    assert artifact.latest_version == 1
  end

  test "write/3 bumps the version on a second write, keeping both versions", %{store: store, mission: m} do
    {:ok, _} = Artifacts.write(store, m.id, %{type: :research_memo, owning_role: "researcher",
      content: %{"summary" => "v1"}, created_by: "researcher"})

    {:ok, %{version: 2}} = Artifacts.write(store, m.id, %{type: :research_memo, owning_role: "researcher",
      content: %{"summary" => "v2"}, created_by: "researcher"})

    assert Artifacts.latest(store, m.id, :research_memo) == %{"summary" => "v2"}
  end

  test "latest/3 is nil when nothing was ever written", %{store: store, mission: m} do
    assert Artifacts.latest(store, m.id, :research_memo) == nil
  end

  test "latest_all/2 maps every artifact type this mission has to its latest content", %{store: store, mission: m} do
    {:ok, _} = Artifacts.write(store, m.id, %{type: :intake_summary, owning_role: "researcher",
      content: %{"objective" => "o"}, created_by: "researcher"})

    assert Artifacts.latest_all(store, m.id) == %{intake_summary: %{"objective" => "o"}}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/store/artifacts_test.exs`
Expected: FAIL — module undefined. (Before writing the implementation, read `test/support/store_case.ex` to confirm `start_store!/0`'s exact name — adjust the `setup` block to match if it differs.)

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Store.Artifacts do
  @moduledoc """
  Versioned artifact CRUD (docs/spec-v1.md §5 "Artifacts... Versioned,
  with author, sources and acceptance state; new evidence produces a new
  version"). One `artifacts` row per `(mission_id, type)`; every write
  appends an `artifact_versions` row and bumps `artifacts.latest_version`
  in the same transaction, mirroring `Sprat.Store.Tasks.transition/4`'s
  "state change + event together" rule.
  """

  alias Sprat.Store.SQL

  defstruct [:id, :mission_id, :type, :owning_role, :latest_version, :created_at]

  defmodule Version do
    @moduledoc "One artifact version."
    defstruct [:id, :artifact_id, :version, :content, :blob_hash, :created_by, :created_at]
  end

  @doc "Writes a new version of `attrs.type` for `mission_id`, creating the artifact row if this is the first write."
  def write(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> write_in_conn(conn, mission_id, attrs) end)
  end

  def write_in_conn(conn, mission_id, attrs) do
    type = to_string(Map.fetch!(attrs, :type))
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    artifact =
      case SQL.fetch_one(conn, "SELECT * FROM artifacts WHERE mission_id = ?1 AND type = ?2",
             [mission_id, type]) do
        nil ->
          id = generate_artifact_id()

          SQL.exec(
            conn,
            """
            INSERT INTO artifacts (id, mission_id, type, owning_role, latest_version, created_at)
            VALUES (?1, ?2, ?3, ?4, 0, ?5)
            """,
            [id, mission_id, type, Map.fetch!(attrs, :owning_role), now]
          )

          %__MODULE__{id: id, mission_id: mission_id, type: type,
            owning_role: Map.fetch!(attrs, :owning_role), latest_version: 0, created_at: now}

        row ->
          row_to_artifact(row)
      end

    version = artifact.latest_version + 1

    SQL.exec(
      conn,
      """
      INSERT INTO artifact_versions (artifact_id, version, content, blob_hash, created_by, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [artifact.id, version, JSON.encode!(Map.fetch!(attrs, :content)), attrs[:blob_hash],
        attrs[:created_by], now]
    )

    SQL.exec(conn, "UPDATE artifacts SET latest_version = ?1 WHERE id = ?2", [version, artifact.id])

    {:ok, %{artifact: %{artifact | latest_version: version}, version: version}}
  end

  @doc "The decoded content of `type`'s latest version for `mission_id`, or `nil`."
  def latest(store \\ Sprat.Store, mission_id, type) do
    case Sprat.Store.fetch_one(
           store,
           """
           SELECT v.content FROM artifact_versions v
           JOIN artifacts a ON a.id = v.artifact_id
           WHERE a.mission_id = ?1 AND a.type = ?2
           ORDER BY v.version DESC LIMIT 1
           """,
           [mission_id, to_string(type)]
         ) do
      nil -> nil
      %{"content" => content} -> JSON.decode!(content)
    end
  end

  @doc "Every artifact type this mission has written, mapped to its latest version's decoded content — the shape `Sprat.Workflow.Gate.check/3` takes."
  def latest_all(store \\ Sprat.Store, mission_id) do
    store
    |> by_mission(mission_id)
    |> Map.new(fn a -> {String.to_atom(a.type), latest(store, mission_id, a.type)} end)
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM artifacts WHERE mission_id = ?1 ORDER BY created_at ASC", [mission_id])
    |> Enum.map(&row_to_artifact/1)
  end

  @doc "All versions of one artifact, oldest first — for the Inspector's Artifacts tab."
  def versions(store \\ Sprat.Store, artifact_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM artifact_versions WHERE artifact_id = ?1 ORDER BY version ASC", [artifact_id])
    |> Enum.map(&row_to_version/1)
  end

  defp row_to_artifact(row) do
    %__MODULE__{id: row["id"], mission_id: row["mission_id"], type: row["type"],
      owning_role: row["owning_role"], latest_version: row["latest_version"], created_at: row["created_at"]}
  end

  defp row_to_version(row) do
    %Version{id: row["id"], artifact_id: row["artifact_id"], version: row["version"],
      content: JSON.decode!(row["content"]), blob_hash: row["blob_hash"],
      created_by: row["created_by"], created_at: row["created_at"]}
  end

  defp generate_artifact_id,
    do: "art_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/store/artifacts_test.exs`
Expected: PASS

- [ ] **Step 5: Write `Sprat.Store.Decisions` (mirrors `Sprat.Store.Sources`/`Claims` exactly) and its test**

```elixir
defmodule Sprat.Store.Decisions do
  @moduledoc "CRUD for the decision log (docs/spec-v1.md §4 'Disagreements are recorded in the decision log with the evidence on both sides')."

  alias Sprat.Store.SQL

  defstruct [:id, :mission_id, :summary, :evidence_for, :evidence_against, :created_at]

  def record(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, mission_id, attrs) end)
  end

  def record_in_conn(conn, mission_id, attrs) do
    decision = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: mission_id,
      summary: Map.fetch!(attrs, :summary),
      evidence_for: attrs[:evidence_for],
      evidence_against: attrs[:evidence_against],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO decisions (id, mission_id, summary, evidence_for, evidence_against, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [decision.id, decision.mission_id, decision.summary, decision.evidence_for,
        decision.evidence_against, decision.created_at]
    )

    decision
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM decisions WHERE mission_id = ?1 ORDER BY created_at ASC", [mission_id])
    |> Enum.map(&row_to_decision/1)
  end

  defp row_to_decision(row) do
    %__MODULE__{id: row["id"], mission_id: row["mission_id"], summary: row["summary"],
      evidence_for: row["evidence_for"], evidence_against: row["evidence_against"], created_at: row["created_at"]}
  end

  defp generate_id,
    do: "dec_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
```

Test file `test/sprat/store/decisions_test.exs` mirrors Step 1 above: create store/session/mission, `Decisions.record/3` with `%{summary: "chose X over Y", evidence_for: "...", evidence_against: "..."}`, assert `by_mission/2` returns it.

- [ ] **Step 6: Run both test files**

Run: `mix test test/sprat/store/artifacts_test.exs test/sprat/store/decisions_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/sprat/store/artifacts.ex lib/sprat/store/decisions.ex \
  test/sprat/store/artifacts_test.exs test/sprat/store/decisions_test.exs
git commit -m "Add Sprat.Store.Artifacts and Sprat.Store.Decisions"
```

---

### Task 7: `write_artifact` tool, type-restricted per task

**Files:**
- Create: `lib/sprat/agent/tools/write_artifact.ex`
- Test: `test/sprat/agent/tools/write_artifact_test.exs`

**Interfaces:**
- Consumes: `Sprat.Store.Artifacts.write/3` (Task 6), `Sprat.Agent.Tool` behaviour (existing — see `lib/sprat/agent/tool.ex`).
- Produces: a tool the Orchestrator (Task 8) puts in `loop_opts.tools` for every stage, restricted via `tool_context[:allowed_artifact_types]` (a `MapSet.t(String.t())` the Orchestrator sets to the current stage's `deliverables`, mirroring how `WebFetch` already reads `tool_context[:auto_fetch_urls]` — see `lib/sprat/agent/tools/web_fetch.ex` for the pattern this must match).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sprat.Agent.Tools.WriteArtifactTest do
  use ExUnit.Case, async: true
  import Sprat.StoreCase

  alias Sprat.Agent.Tools.WriteArtifact
  alias Sprat.Store.{Artifacts, Missions, Sessions}

  setup do
    store = start_store!()
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
    {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
    %{store: store, mission: mission}
  end

  test "writes an allowed artifact type", %{store: store, mission: m} do
    context = %{store: store, mission_id: m.id, role: "researcher",
      allowed_artifact_types: MapSet.new(["intake_summary"])}

    args = %{"type" => "intake_summary", "content" => %{"objective" => "o", "depth" => "quick", "open_questions" => []}}

    assert {:ok, %{"type" => "intake_summary", "version" => 1}} = WriteArtifact.call(args, context)
    assert Artifacts.latest(store, m.id, :intake_summary)["objective"] == "o"
  end

  test "refuses a type not in this stage's deliverables", %{store: store, mission: m} do
    context = %{store: store, mission_id: m.id, role: "researcher",
      allowed_artifact_types: MapSet.new(["intake_summary"])}

    args = %{"type" => "product_brief", "content" => %{}}

    assert {:error, message} = WriteArtifact.call(args, context)
    assert message =~ "not a deliverable of this stage"
  end

  test "refuses content that fails the artifact's schema", %{store: store, mission: m} do
    context = %{store: store, mission_id: m.id, role: "researcher",
      allowed_artifact_types: MapSet.new(["intake_summary"])}

    args = %{"type" => "intake_summary", "content" => %{}}

    assert {:error, message} = WriteArtifact.call(args, context)
    assert message =~ "objective"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/agent/tools/write_artifact_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Agent.Tools.WriteArtifact do
  @moduledoc """
  `write_artifact` tool (docs/spec-v1.md §5 build brief item 4): the only
  way a stage's agent turn produces a deliverable. Restricted to the
  current stage's declared types via `context[:allowed_artifact_types]`
  (set by `Sprat.Orchestrator` from `Template.Stage.deliverables`, never
  by the model) — "a role may write only its own artifact types" (§9
  tools table), enforced here in code, not by the prompt asking nicely.
  Content is validated against `Sprat.Workflow.ArtifactSchema` before
  anything is stored, so a malformed artifact never reaches the gate as
  something to reject later — it is rejected immediately, with the exact
  missing fields, and the model can retry within the same turn.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Store.Artifacts
  alias Sprat.Workflow.ArtifactSchema

  @impl true
  def name, do: "write_artifact"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "write_artifact",
        "description" =>
          "Write (or overwrite with a new version of) one of this stage's deliverable " <>
            "artifacts. Only the types this stage is assigned can be written here.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "description" => "artifact type, e.g. research_memo"},
            "content" => %{"type" => "object", "description" => "the artifact's structured content"}
          },
          "required" => ["type", "content"]
        }
      }
    }
  end

  @impl true
  def call(%{"type" => type, "content" => content}, context) when is_binary(type) and is_map(content) do
    allowed = Map.get(context, :allowed_artifact_types, MapSet.new())

    cond do
      not MapSet.member?(allowed, type) ->
        {:error,
         "#{type} is not a deliverable of this stage (allowed: #{Enum.join(MapSet.to_list(allowed), ", ")})"}

      true ->
        write(type, content, context)
    end
  end

  def call(_args, _context), do: {:error, "expected {\"type\": \"...\", \"content\": {...}}"}

  defp write(type, content, context) do
    type_atom = String.to_existing_atom(type)

    case ArtifactSchema.validate(type_atom, content) do
      {:error, errors} ->
        {:error, "#{type} failed validation: #{Enum.join(errors, "; ")}"}

      :ok ->
        store = Map.fetch!(context, :store)
        mission_id = Map.fetch!(context, :mission_id)

        {:ok, %{artifact: _artifact, version: version}} =
          Artifacts.write(store, mission_id, %{
            type: type_atom,
            owning_role: Map.get(context, :role, "researcher"),
            content: content,
            created_by: Map.get(context, :role, "researcher")
          })

        {:ok, %{"type" => type, "version" => version}}
    end
  rescue
    ArgumentError -> {:error, "unknown artifact type: #{type}"}
  end
end
```

Note: `String.to_existing_atom/1` requires the type atom to already exist in the VM's atom table. `Sprat.Workflow.ArtifactSchema`'s function clauses (`:intake_summary`, `:research_memo`, ...) already reference all ten as literals, so once that module is loaded (it always is — the Orchestrator depends on it) the atoms exist. If a test fails with `ArgumentError: argument error` here for a *valid* type, add `Code.ensure_loaded!(Sprat.Workflow.ArtifactSchema)` at the top of `write/3`, matching the existing fix in `lib/sprat/store/tasks.ex`'s `transition_in_conn/4` for the identical `to_existing_atom` race.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/agent/tools/write_artifact_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/agent/tools/write_artifact.ex test/sprat/agent/tools/write_artifact_test.exs
git commit -m "Add write_artifact tool, restricted to a stage's declared deliverables"
```

---

### Task 8: `Sprat.Orchestrator` — walks a template, one stage at a time

This is the largest task. Read `lib/sprat/mission.ex` in full before starting — the Orchestrator reuses its patterns almost verbatim (context assembly, `transition_chain/4`-style safe transitions, `broadcast_agents`/`broadcast_inspector`/`broadcast_budget` view models, the `:persistent_term` active/cancel flags) but drives a `Template` instead of one fixed prompt.

**Files:**
- Create: `lib/sprat/orchestrator.ex`
- Create: `lib/sprat/orchestrator_supervisor.ex`
- Modify: `lib/sprat/application.ex` — add `{Sprat.OrchestratorSupervisor, []}` to the supervision tree, after `Sprat.SessionSupervisor` (read the file first to match its existing child-spec style)
- Test: `test/sprat/orchestrator_test.exs`

**Interfaces:**
- Consumes: `Sprat.Workflow.Template`/`.Idea`/`.Opportunity` (Task 3), `Sprat.Workflow.Gate.check/3` (Task 4), `Sprat.Store.Artifacts` (Task 6), `Sprat.Agent.Tools.WriteArtifact` (Task 7), `Sprat.Agent.Loop.run/1` and `.resume/3` (existing, unchanged), `Sprat.Store.Tasks.transition/4` (existing), `Sprat.Session.add_block/2` and `Sprat.Session.PubSub.broadcast/2` (existing).
- Produces: `Sprat.Orchestrator.start(session_id, text, template_mod, depth, opts \\ []) :: :ok` — mirrors `Sprat.Mission.start/3`'s signature and busy-guard behaviour exactly (same "one task at a time per session" refusal, same `opts` keys for tests: `:store`, `:budget`, `:model_mod`, `:api_key`, `:model_id`, `:sync?`). `Sprat.Orchestrator.user_choice(session_id, answer) :: :ok` — feeds the Directions user-choice point (Task 9).

- [ ] **Step 1: Write the failing test — a stubbed-model happy path through the Idea template**

Read `test/support/stub_model.ex` first to learn its exact API (it already backs `Sprat.Agent.Loop` tests) — the shape below assumes it exposes a way to script per-call responses and tool calls; adjust the `StubModel` setup lines to match what that file actually provides rather than inventing a different API.

```elixir
defmodule Sprat.OrchestratorTest do
  use ExUnit.Case, async: false
  import Sprat.StoreCase

  alias Sprat.Orchestrator
  alias Sprat.Store.{Artifacts, Missions, Sessions, Tasks}
  alias Sprat.Workflow.Idea

  setup do
    store = start_store!()
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
    start_supervised!({Sprat.Budget, name: :"budget_#{session.id}"})
    %{store: store, session: session}
  end

  test "runs every stage of the Idea template to delivery with a scripted model", %{store: store, session: session} do
    model = Sprat.StubModel.scripted_for_idea_delivery()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-model",
        api_key: "test-key",
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    tasks = Tasks.by_mission(store, mission.id)

    assert Enum.map(tasks, & &1.role) |> Enum.all?(&(&1 == "researcher"))
    assert length(tasks) == 6
    assert Enum.all?(tasks, &(&1.status == "completed"))

    assert Artifacts.latest(store, mission.id, :product_brief)
    assert Artifacts.latest(store, mission.id, :validation_plan)
  end

  test "a gate failure produces changes_requested and a bounded retry, then surfaces to the user", %{store: store, session: session} do
    model = Sprat.StubModel.always_writes_invalid_research_memo()

    :ok =
      Orchestrator.start(session.id, "gym booking software", Idea, :quick,
        store: store,
        budget: :"budget_#{session.id}",
        model_mod: model,
        model_id: "stub-model",
        api_key: "test-key",
        sync?: true
      )

    [mission] = Missions.by_session(store, session.id)
    research_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.role == "researcher" and &1.objective =~ "research" ))
    # review_rounds default is 1 (§8 scheduling defaults) -> attempt caps at 2
    assert research_task.attempt <= 2
    assert research_task.status in ["failed", "needs_input"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: FAIL — `Sprat.Orchestrator` undefined (and the two `Sprat.StubModel` helper functions above don't exist yet — add them to `test/support/stub_model.ex` in this same step, following the file's existing pattern for scripting a sequence of responses/tool calls; `always_writes_invalid_research_memo/0` should script a `write_artifact` tool call with `%{"type" => "research_memo", "content" => %{}}` — missing every required field — then a plain text final answer, repeated for each retry attempt).

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sprat.Orchestrator do
  @moduledoc """
  Walks a `Sprat.Workflow.Template` stage by stage (docs/spec-v1.md §5/§8):
  creates a `task` per stage, assembles its context package, runs
  `Sprat.Agent.Loop`, records the stage's deliverables as artifacts, runs
  the stage's gate, and advances, retries within the review-round limit,
  or stops. Mirrors `Sprat.Mission` closely on purpose — same busy guard,
  same cancel flag, same safe-transition pattern — because that module is
  this one's proven prior art for exactly this "run a loop, settle a
  task" problem; the difference is the outer loop over stages instead of
  a single fixed prompt.

  One role runs every stage in this build: `stage.role` is read, never
  hardcoded, so a later build can vary it per stage without touching this
  module (build brief scope decision).
  """

  alias Sprat.Agent.Loop
  alias Sprat.Agent.Tools.{Calculate, RecordClaim, RecordSource, WebFetch, WriteArtifact}
  alias Sprat.Model.{OpenAI, Pricing}
  alias Sprat.Store.{Artifacts, Events, Grants, Messages, Missions, Sources, Tasks}
  alias Sprat.{Budget, Secrets, Session}
  alias Sprat.Session.PubSub
  alias Sprat.Workflow.{Gate, Template}

  @review_rounds 1
  @stall_turns 3

  defp active_key(session_id), do: {__MODULE__, :active, session_id}
  defp active?(session_id), do: :persistent_term.get(active_key(session_id), false)
  defp mark_active(session_id), do: :persistent_term.put(active_key(session_id), true)
  defp clear_active(session_id), do: :persistent_term.erase(active_key(session_id))

  defp cancel_key(session_id), do: {__MODULE__, :cancel, session_id}
  def cancel(session_id), do: :persistent_term.put(cancel_key(session_id), true)
  defp cancelled?(session_id), do: :persistent_term.get(cancel_key(session_id), false)
  defp clear_cancel(session_id), do: :persistent_term.erase(cancel_key(session_id))

  @doc """
  Starts a staged mission. Same busy-guard contract as `Sprat.Mission.start/3`
  (see its moduledoc "One task at a time per session") — refuses a second
  run while one is active, with a visible message, never queuing silently.
  `template_mod` is `Sprat.Workflow.Idea` or `Sprat.Workflow.Opportunity`;
  `depth` is `:quick | :standard | :deep`.
  """
  def start(session_id, text, template_mod, depth, opts \\ []) do
    store = Keyword.get(opts, :store, Sprat.Store)
    budget_mod = Keyword.get(opts, :budget, Sprat.Budget)

    if active?(session_id) do
      system(session_id, [
        "Still running a staged mission — this message wasn't sent. Wait for it to " <>
          "finish, or press Ctrl+C to interrupt, then resend."
      ])

      :ok
    else
      mark_active(session_id)
      template = template_mod.template(depth)

      runner = fn ->
        try do
          run(session_id, store, budget_mod, text, template, opts)
        after
          clear_active(session_id)
          clear_cancel(session_id)
        end
      end

      if Keyword.get(opts, :sync?, false), do: runner.(), else: Task.start(runner)
      :ok
    end
  end

  defp run(session_id, store, budget_mod, text, template, opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    api_key = Keyword.fetch!(opts, :api_key)
    catalog = Keyword.get(opts, :catalog) || Pricing.load()

    {:ok, mission} = Missions.create(store, session_id, %{objective: text})
    cap = Keyword.get(opts, :budget_cap, Decimal.new("5.00"))
    :ok = Budget.set_cap(budget_mod, mission.id, cap)

    stage = Template.first_stage(template)
    run_stage(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts)
  end

  defp run_stage(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts) do
    {:ok, task} = Tasks.create(store, mission.id, %{role: stage.role, objective: "#{stage.title}: #{text}"})
    {:ok, task} = Tasks.transition(store, task.id, :running, %{session_id: session_id, actor: "sprat"})

    announce_stage(session_id, stage)

    context_package = build_stage_context(store, session_id, mission.id, stage, text)
    tools = [WebFetch, Calculate, RecordSource, RecordClaim, WriteArtifact]

    loop_opts = %{
      model_mod: Keyword.get(opts, :model_mod, OpenAI),
      model_id: model_id,
      role_prompt: stage.prompt,
      context_package: context_package,
      tools: tools,
      session_id: session_id,
      mission_id: mission.id,
      task_id: task.id,
      agent_id: stage.role,
      attempt: task.attempt,
      store: store,
      budget: budget_mod,
      api_key: api_key,
      catalog: catalog,
      max_turns: Map.get(stage.limits, :model_calls, 20),
      tool_context: %{
        store: store,
        mission_id: mission.id,
        role: stage.role,
        allowed_artifact_types: MapSet.new(Enum.map(stage.deliverables, &to_string/1)),
        auto_fetch_urls: MapSet.new(),
        auto_fetch_hosts: MapSet.new(),
        secrets: Secrets.redaction_set()
      },
      on_delta: fn _delta -> :ok end,
      cancel?: fn -> cancelled?(session_id) end
    }

    settle_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, Loop.run(loop_opts))
  end

  defp settle_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, result) do
    case result do
      {:ok, %{content: content}} ->
        record_message(store, session_id, task.id, stage.role, content || "(no content)")
        finish_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts)

      {:cancelled, _} ->
        safe_transition(store, task.id, :interrupted, session_id, "cancelled by user")
        system(session_id, ["#{stage.title} interrupted — usage so far is recorded as estimated."])

      {:error, reason} ->
        safe_transition(store, task.id, :failed, session_id, inspect(reason))
        system(session_id, ["#{stage.title} failed: #{inspect(reason)}"])
    end
  end

  # Gate check + advance/retry/stop (docs/spec-v1.md §5 Gates, §8 "review
  # rounds"). No gate (`stage.gate == nil`, e.g. Directions, Scoring) means
  # the stage's own deliverable check is enough — advance straight away.
  defp finish_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts) do
    case run_gate(store, mission.id, stage) do
      :ok ->
        {:ok, _} = Tasks.transition(store, task.id, :review_pending, %{session_id: session_id})
        {:ok, _} = Tasks.transition(store, task.id, :completed, %{session_id: session_id})
        gate_result(session_id, stage, :ok, [])
        advance(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts)

      {:error, errors} ->
        gate_result(session_id, stage, :error, errors)
        retry_or_surface(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, errors)
    end
  end

  defp run_gate(_store, _mission_id, %{gate: nil}), do: :ok

  defp run_gate(store, mission_id, stage) do
    artifacts = Artifacts.latest_all(store, mission_id)
    source_ids = Sources.by_mission(store, mission_id) |> Enum.map(& &1.id) |> MapSet.new()
    Gate.check(stage.gate, artifacts, source_ids)
  end

  defp retry_or_surface(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, errors) do
    {:ok, task} = Tasks.transition(store, task.id, :review_pending, %{session_id: session_id})
    {:ok, task} = Tasks.transition(store, task.id, :changes_requested, %{session_id: session_id, reason: Enum.join(errors, "; ")})

    if task.attempt <= @review_rounds + 1 do
      {:ok, task} = Tasks.transition(store, task.id, :queued, %{session_id: session_id})
      {:ok, task} = Tasks.transition(store, task.id, :running, %{session_id: session_id})
      retry_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts)
    else
      {:ok, _} = Tasks.transition(store, task.id, :failed, %{session_id: session_id, reason: "gate failed after #{task.attempt} attempts"})
      system(session_id, [
        "#{stage.title} could not pass its gate after #{task.attempt} attempts:",
        Enum.map_join(errors, "\n", &"  - #{&1}")
      ])
    end
  end

  # Re-runs the same stage, folding the prior gate failure into the
  # context package so the retry sees exactly what was missing — the
  # spec's "changes_requested" round, not a blind repeat.
  defp retry_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts) do
    context_package =
      build_stage_context(store, session_id, mission.id, stage, text) <>
        "\n\nThe previous attempt failed this stage's gate:\n" <> gate_reason(task)

    tools = [WebFetch, Calculate, RecordSource, RecordClaim, WriteArtifact]

    loop_opts = %{
      model_mod: Keyword.get(opts, :model_mod, OpenAI),
      model_id: model_id,
      role_prompt: stage.prompt,
      context_package: context_package,
      tools: tools,
      session_id: session_id,
      mission_id: mission.id,
      task_id: task.id,
      agent_id: stage.role,
      attempt: task.attempt,
      store: store,
      budget: budget_mod,
      api_key: api_key,
      catalog: catalog,
      max_turns: Map.get(stage.limits, :model_calls, 20),
      tool_context: %{
        store: store,
        mission_id: mission.id,
        role: stage.role,
        allowed_artifact_types: MapSet.new(Enum.map(stage.deliverables, &to_string/1)),
        auto_fetch_urls: MapSet.new(),
        auto_fetch_hosts: MapSet.new(),
        secrets: Secrets.redaction_set()
      },
      on_delta: fn _delta -> :ok end,
      cancel?: fn -> cancelled?(session_id) end
    }

    settle_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, Loop.run(loop_opts))
  end

  defp gate_reason(%Tasks{} = task) do
    Events.by_task(task.id) |> List.last() |> case do
      %{payload: %{"reason" => reason}} -> reason
      _ -> "(reason unavailable)"
    end
  end

  # Directions ends the automated walk here (the user-choice point, Task 9
  # wires `user_choice/2` to resume from this exact point). Every other
  # stage advances straight to the next one.
  defp advance(session_id, store, budget_mod, mission, template, %{id: :directions} = stage, text, model_id, api_key, catalog, opts) do
    {:ok, _} = Tasks.transition(store, nil_task_id_guard(), :queued, %{session_id: session_id})
  rescue
    _ -> await_user_choice(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts)
  end

  defp advance(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts) do
    case Template.stage_after(template, stage.id) do
      nil ->
        system(session_id, ["Mission delivered — all stages complete. Run /artifacts to see what was produced."])

      next_stage ->
        run_stage(session_id, store, budget_mod, mission, template, next_stage, text, model_id, api_key, catalog, opts)
    end
  end

  defp nil_task_id_guard, do: raise("unreachable — see Task 9's rewrite of the :directions clause")

  defp await_user_choice(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts) do
    :persistent_term.put({__MODULE__, :pending, session_id},
      %{store: store, budget_mod: budget_mod, mission: mission, template: template,
        stage: stage, text: text, model_id: model_id, api_key: api_key, catalog: catalog, opts: opts})

    system(session_id, [
      "Directions ready — pick one, combine, reject, or add a constraint, then continue."
    ])
  end

  # -- context (generalised from Sprat.Mission.build_context/7) -------------

  defp build_stage_context(store, session_id, mission_id, stage, text) do
    inputs =
      stage.required_inputs
      |> Enum.map(fn type -> {type, Artifacts.latest(store, mission_id, type)} end)
      |> Enum.reject(fn {_type, content} -> is_nil(content) end)

    sources = Sources.by_mission(store, mission_id)

    [
      inputs_section(inputs),
      sources_section(sources),
      "Objective: #{text}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> tap(fn package ->
      Events.append(store, session_id, "context.assembled", %{
        mission_id: mission_id,
        payload: %{"stage" => stage.id, "inputs" => Enum.map(inputs, &elem(&1, 0)),
          "token_estimate" => div(byte_size(package), 4)}
      })
    end)
  end

  defp inputs_section([]), do: ""

  defp inputs_section(inputs) do
    lines = Enum.map(inputs, fn {type, content} -> "- #{type}: #{JSON.encode!(content)}" end)
    "Prior artifacts this stage depends on:\n" <> Enum.join(lines, "\n")
  end

  defp sources_section([]), do: ""

  defp sources_section(sources) do
    lines = Enum.map(sources, &"- #{&1.title || "(untitled)"} — #{&1.url} (source id: #{&1.id})")
    "Sources already recorded in this mission:\n" <> Enum.join(lines, "\n")
  end

  # -- broadcasts (never the renderer directly — §13) ------------------------

  defp announce_stage(session_id, stage) do
    :ok = Session.add_block(session_id, %{kind: :stage_change, name: stage.title, reason: nil})
    PubSub.broadcast(session_id, {:agents_updated, %{agents: [%{id: stage.id, role: String.to_atom(stage.role),
      label: stage.title, state: :active, elapsed_s: nil, tokens: nil, activity: "starting", stream_tail: nil}]}})
  end

  defp gate_result(session_id, stage, :ok, _errors) do
    :ok = Session.add_block(session_id, %{kind: :system, text: "✓ #{stage.title} gate passed."})
  end

  defp gate_result(session_id, stage, :error, errors) do
    lines = ["✗ #{stage.title} gate failed:" | Enum.map(errors, &"  - #{&1}")]
    :ok = Session.add_block(session_id, %{kind: :system, text: Enum.join(lines, "\n")})
  end

  defp safe_transition(store, task_id, to_status, session_id, reason) do
    case Tasks.transition(store, task_id, to_status, %{session_id: session_id, reason: reason}) do
      {:ok, task} -> task
      {:error, _} -> nil
    end
  end

  defp record_message(store, session_id, task_id, role, content),
    do: Messages.append(store, session_id, %{task_id: task_id, role: role, content: content})

  defp system(session_id, lines),
    do: Session.add_block(session_id, %{kind: :system, text: Enum.join(List.wrap(lines), "\n")})
end
```

The `advance/9` clause for `:directions` above is deliberately left broken (`nil_task_id_guard/0` always raises, so it always falls into the `rescue` and calls `await_user_choice/9`) — this is a **known placeholder resolved in Task 9**, not a step to leave in the final tree; Task 9 replaces both `advance/9` clauses for `:directions` with a clean `if stage.id == :directions, do: await_user_choice(...), else: ...` and removes `nil_task_id_guard/0` entirely. Flag this to the reviewer of this task explicitly: it must not be merged as-is.

Also add `Sprat.Store.Events.by_task/1` if it doesn't already exist (check `lib/sprat/store/events.ex` first — `Sprat.Mission` never needed it, so it may be missing): a thin wrapper `def by_task(store \\ Sprat.Store, task_id), do: Sprat.Store.fetch_all(store, "SELECT * FROM events WHERE task_id = ?1 ORDER BY seq ASC", [task_id]) |> Enum.map(&row_to_event/1)`, reusing that file's existing `row_to_event/1` private function (make it non-private if needed, or duplicate its field list — check the file before deciding).

Create `lib/sprat/orchestrator_supervisor.ex` as a minimal `DynamicSupervisor` (this build calls `Orchestrator.start/5` as a bare `Task`, same as `Sprat.Mission` — the supervisor exists for the Application tree per the build brief's item 2 naming `Sprat.Orchestrator, a process per mission`, but the concrete per-mission process supervision can stay a `Task.start` under this `DynamicSupervisor` exactly like `Sprat.Mission` already does under none at all; keep this file to the minimum that satisfies "add to the supervision tree" — do not build GenServer machinery `Sprat.Orchestrator` itself doesn't need):

```elixir
defmodule Sprat.OrchestratorSupervisor do
  @moduledoc "DynamicSupervisor placeholder for future per-mission Orchestrator processes; currently unused since Sprat.Orchestrator.start/5 runs as an unlinked Task, matching Sprat.Mission's pattern."
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: PASS. If the stub model's scripting API doesn't match what was assumed in Step 2/3, adjust the test setup (not the Orchestrator) to match `test/support/stub_model.ex`'s real API.

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/orchestrator.ex lib/sprat/orchestrator_supervisor.ex lib/sprat/application.ex \
  test/sprat/orchestrator_test.exs test/support/stub_model.ex
git commit -m "Add Sprat.Orchestrator: walks a workflow template stage by stage"
```

---

### Task 9: The Directions user-choice point

**Files:**
- Modify: `lib/sprat/orchestrator.ex` (replace the broken `:directions` clause pair from Task 8 with a clean single implementation; remove `nil_task_id_guard/0`)
- Test: extend `test/sprat/orchestrator_test.exs`

**Interfaces:**
- Produces: `Sprat.Orchestrator.user_choice(session_id, answer :: String.t()) :: :ok` — reads `:persistent_term.get({Sprat.Orchestrator, :pending, session_id})` (written by `await_user_choice/9` in Task 8), resumes the Recommendation stage with the user's answer folded into its context, exactly as `Sprat.Mission.pick_model/2`'s pattern of a background `Task.start` resuming from stored state.

- [ ] **Step 1: Write the failing test**

```elixir
test "the Directions stage stops for user_choice, then resumes into Recommendation with the answer", %{store: store, session: session} do
  model = Sprat.StubModel.scripted_for_idea_delivery()

  :ok =
    Orchestrator.start(session.id, "gym booking software", Idea, :quick,
      store: store, budget: :"budget_#{session.id}", model_mod: model,
      model_id: "stub-model", api_key: "test-key", sync?: true)

  [mission] = Missions.by_session(store, session.id)
  tasks_before = Tasks.by_mission(store, mission.id)
  directions_task = Enum.find(tasks_before, &(&1.objective =~ "Directions"))
  assert directions_task.status == "completed"
  recommendation_task = Enum.find(tasks_before, &(&1.objective =~ "Recommendation"))
  assert is_nil(recommendation_task)

  :ok = Orchestrator.user_choice(session.id, "combine direction 1 and 2, web only")

  tasks_after = Tasks.by_mission(store, mission.id)
  assert Enum.find(tasks_after, &(&1.objective =~ "Recommendation")).status == "completed"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: FAIL — `Orchestrator.user_choice/2` undefined, and the current `:directions` clause never actually reaches Recommendation (it always awaits).

- [ ] **Step 3: Fix the implementation**

Replace the two `advance/9` clauses for `:directions` from Task 8 with:

```elixir
defp advance(session_id, store, budget_mod, mission, template, %{id: :directions} = stage, text, model_id, api_key, catalog, opts) do
  await_user_choice(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts)
end

defp advance(session_id, store, budget_mod, mission, template, stage, text, model_id, api_key, catalog, opts) do
  case Template.stage_after(template, stage.id) do
    nil ->
      system(session_id, ["Mission delivered — all stages complete. Run /artifacts to see what was produced."])

    next_stage ->
      run_stage(session_id, store, budget_mod, mission, template, next_stage, text, model_id, api_key, catalog, opts)
  end
end
```

Delete `nil_task_id_guard/0` entirely. Add:

```elixir
@doc """
Answers the pending Directions choice (docs/spec-v1.md §5 "the user picks,
combines, rejects or adds constraints"). Persists `answer` as a decision
(`Sprat.Store.Decisions`) and resumes the walk from the stage after
Directions with `answer` folded into the objective text every later
stage's context sees.
"""
def user_choice(session_id, answer) do
  key = {__MODULE__, :pending, session_id}

  case :persistent_term.get(key, nil) do
    nil ->
      system(session_id, ["No pending direction choice for this session."])

    %{store: store, budget_mod: budget_mod, mission: mission, template: template,
      stage: stage, text: text, model_id: model_id, api_key: api_key, catalog: catalog, opts: opts} ->
      :persistent_term.erase(key)

      {:ok, _} =
        Sprat.Store.Decisions.record(store, mission.id, %{
          summary: "User choice after Directions: #{answer}",
          evidence_for: nil,
          evidence_against: nil
        })

      combined_text = "#{text}\n\nUser's choice after Directions: #{answer}"
      next_stage = Template.stage_after(template, stage.id)

      mark_active(session_id)

      Task.start(fn ->
        try do
          run_stage(session_id, store, budget_mod, mission, template, next_stage, combined_text, model_id, api_key, catalog, opts)
        after
          clear_active(session_id)
        end
      end)
  end

  :ok
end
```

Note this reintroduces the `active?`/`mark_active` busy guard around the resumed run (mirroring `start/5`) — without it, a message arriving while Recommendation is running would race `active?`, exactly the bug `Sprat.Mission`'s moduledoc documents fixing.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: PASS (all tests in the file, not just the new one — confirm no regression in the Task 8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/orchestrator.ex test/sprat/orchestrator_test.exs
git commit -m "Wire the Directions user-choice point into Sprat.Orchestrator"
```

---

### Task 10: Stall detection and per-stage/mission budget exhaustion

**Files:**
- Modify: `lib/sprat/orchestrator.ex`
- Test: extend `test/sprat/orchestrator_test.exs`

**Interfaces:**
- Consumes: `Sprat.Agent.Loop`'s turn-by-turn behaviour. Stall detection (§8: "three consecutive model turns with no new source, artifact change or state progress") needs per-turn visibility `Loop.run/1` doesn't currently expose (it only returns the final outcome). Add an optional `on_turn_end` callback to `Sprat.Agent.Loop` — `Map.get(opts, :on_turn_end, fn _ -> :ok end)` called at the end of `loop/2` with `%{turn: state.turns, tool_calls_made: [...]}` — the smallest change that gives the Orchestrator what it needs without duplicating the loop.

- [ ] **Step 1: Write the failing test**

```elixir
test "a stage that makes 3 consecutive turns with no new source, artifact or state progress is stopped as stalled", %{store: store, session: session} do
  model = Sprat.StubModel.always_chats_without_progress()

  :ok =
    Orchestrator.start(session.id, "gym booking software", Idea, :quick,
      store: store, budget: :"budget_#{session.id}", model_mod: model,
      model_id: "stub-model", api_key: "test-key", sync?: true)

  [mission] = Missions.by_session(store, session.id)
  intake_task = Tasks.by_mission(store, mission.id) |> Enum.find(&(&1.objective =~ "Intake"))
  assert intake_task.status == "failed"

  events = Sprat.Store.Events.by_session(store, session.id, limit: 1000)
  assert Enum.any?(events, &(&1.type == "task.stalled"))
end
```

`Sprat.StubModel.always_chats_without_progress/0` (add to `test/support/stub_model.ex`): scripts every call to return a plain-text response with no tool calls and no `write_artifact` — content that never changes the mission's sources/artifacts/task state — for at least 3 turns.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement stall detection**

In `lib/sprat/agent/loop.ex`, add the callback (minimal diff — do not restructure the loop):

```elixir
# in `loop/2`, right before `run_turn/2`'s result is returned, or wrapped
# around the existing `loop/2` body — call `Map.get(state.opts, :on_turn_end, fn _ -> :ok end)`
# once per completed turn with `%{turn: state.turns}` before recursing.
```

Locate the exact insertion point by reading `loop/2` and `run_turn/2` again — the callback must fire once per turn regardless of outcome (tool call, final answer, or continuing), so the cleanest spot is the top of `run_turn/2`, calling it with the turn number about to run.

In `lib/sprat/orchestrator.ex`, track progress across turns using an `Agent` (or a simple `:persistent_term` counter keyed by `task.id`, matching the module's existing `:persistent_term` style) that snapshots `{source_count, artifact_version_sum, task_status}` before the stage starts and compares it on each `on_turn_end`:

```elixir
defp stall_tracker_key(task_id), do: {__MODULE__, :stall, task_id}

defp init_stall_tracker(store, mission_id, task_id) do
  :persistent_term.put(stall_tracker_key(task_id), {progress_snapshot(store, mission_id), 0})
end

defp progress_snapshot(store, mission_id) do
  sources = length(Sources.by_mission(store, mission_id))
  artifacts = Artifacts.by_mission(store, mission_id) |> Enum.map(& &1.latest_version) |> Enum.sum()
  {sources, artifacts}
end

defp check_stall(store, mission_id, task_id) do
  {last_snapshot, streak} = :persistent_term.get(stall_tracker_key(task_id), {{0, 0}, 0})
  current = progress_snapshot(store, mission_id)

  if current == last_snapshot do
    streak = streak + 1
    :persistent_term.put(stall_tracker_key(task_id), {current, streak})
    streak >= @stall_turns
  else
    :persistent_term.put(stall_tracker_key(task_id), {current, 0})
    false
  end
end
```

Wire `init_stall_tracker/3` at the start of `run_stage/12` (and `retry_stage/12`), and pass `on_turn_end: fn _ -> if check_stall(store, mission.id, task.id), do: Loop.request_cancel() end` — **this requires `Loop` to expose a way to stop mid-run from inside `on_turn_end`**, which the existing `cancel?` callback already provides (it's checked before the next turn). Simplest correct wiring: have `on_turn_end` write to the same `:persistent_term` cancel flag the stage's `cancel?` callback already reads (`cancelled?(session_id)`), but under a **task-scoped** key so a stall in one stage never cancels a future stage's fresh run:

```elixir
defp stalled?(store, mission_id, task_id) do
  check_stall(store, mission_id, task_id)
end
```

and change `cancel?: fn -> cancelled?(session_id) end` in both `run_stage/12` and `retry_stage/12` to:

```elixir
cancel?: fn -> cancelled?(session_id) or stalled?(store, mission.id, task.id) end,
on_turn_end: fn _turn -> stalled?(store, mission.id, task.id) end
```

Then in `settle_stage/13`'s `{:cancelled, _}` branch, distinguish a real user cancel from a stall (check `stalled?/3` one more time — it is idempotent once the streak has reached the threshold) and, when stalled, emit a `task.stalled` event and transition to `:failed` with reason `"stalled: 3 consecutive turns with no new source, artifact or state progress"` instead of `:interrupted`.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/orchestrator_test.exs test/sprat/agent/loop_test.exs`
Expected: PASS, and the existing `loop_test.exs` suite still passes unchanged (the `on_turn_end` callback defaults to a no-op).

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/agent/loop.ex lib/sprat/orchestrator.ex test/sprat/orchestrator_test.exs test/support/stub_model.ex
git commit -m "Add stall detection (3 no-progress turns) to Sprat.Orchestrator"
```

---

### Task 11: `/idea`, `/research`, `/depth` — wire the entry points; keep plain messages on Mission

**Files:**
- Modify: `lib/sprat/session/commands.ex`
- Test: `test/sprat/session/commands_test.exs` (extend the existing file — read it first for its current test harness pattern)

**Interfaces:**
- Consumes: `Sprat.Orchestrator.start/5` (Task 8), `Sprat.Workflow.Idea`/`Opportunity` (Task 3).
- Produces: `/idea [text]` and `/research [text]` dispatch to `Sprat.Orchestrator.start/5`; a plain message keeps calling `Sprat.Mission.start/3` (unchanged — `handle_plain/3` is untouched). `/depth quick|standard|deep` persists the depth choice for the *next* staged mission in this session (a `:persistent_term` keyed by session id is enough — no new store table needed; read `lib/sprat/config.ex` first in case depth already has a natural home there per-project, and prefer that if it does).

- [ ] **Step 1: Write the failing test**

```elixir
test "/idea starts a staged Orchestrator mission, not a plain Mission run", %{session_id: session_id, store: store} do
  Sprat.Session.Commands.handle(session_id, store, "/idea gym booking software")
  # assert Sprat.Store.Tasks.by_mission/2 for the new mission has 6 tasks queued/running,
  # matching Sprat.Workflow.Idea.template(:standard)'s stage count — adjust to this file's
  # existing async-wait pattern (poll or Process.sleep per its established convention).
end

test "a plain message still runs the single-agent quick path", %{session_id: session_id, store: store} do
  Sprat.Session.Commands.handle(session_id, store, "what's the weather like")
  # assert exactly one task, role "researcher", objective the plain text — i.e.
  # Sprat.Mission's existing behaviour, unchanged.
end

test "/depth deep changes the depth used by the next /idea or /research", %{session_id: session_id, store: store} do
  Sprat.Session.Commands.handle(session_id, store, "/depth deep")
  Sprat.Session.Commands.handle(session_id, store, "/research gym market UK")
  # assert the created tasks' limits reflect Sprat.Workflow.Depth.limits(:deep)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/session/commands_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

```elixir
# in lib/sprat/session/commands.ex

defp dispatch(session_id, store, rest) do
  {cmd, arg} = split_command(rest)

  case cmd do
    "idea" -> start_staged(session_id, store, Sprat.Workflow.Idea, arg)
    "research" -> start_staged(session_id, store, Sprat.Workflow.Opportunity, arg)
    "depth" -> set_depth(session_id, arg)
    # ...existing clauses unchanged...
    other -> system(session_id, ["Unknown command /#{other}. Try /help."])
  end
end

defp split_command(rest) do
  case String.split(rest, " ", parts: 2) do
    [cmd] -> {cmd, ""}
    [cmd, arg] -> {cmd, String.trim(arg)}
  end
end

defp start_staged(session_id, store, template_mod, "") do
  system(session_id, ["Usage: /#{staged_command_name(template_mod)} <what you want researched>"])
end

defp start_staged(session_id, store, template_mod, text) do
  :ok = Session.submit_user_message(session_id, text)
  depth = depth_for(session_id)
  :ok = Sprat.Orchestrator.start(session_id, text, template_mod, depth, store: store)
end

defp staged_command_name(Sprat.Workflow.Idea), do: "idea"
defp staged_command_name(Sprat.Workflow.Opportunity), do: "research"

defp set_depth(session_id, depth_str) do
  case depth_str do
    d when d in ["quick", "standard", "deep"] ->
      :persistent_term.put(depth_key(session_id), String.to_existing_atom(d))
      system(session_id, ["Depth set to #{d} for the next /idea or /research."])

    _ ->
      system(session_id, ["Usage: /depth quick|standard|deep. Current: #{depth_for(session_id)}"])
  end
end

defp depth_key(session_id), do: {__MODULE__, :depth, session_id}
defp depth_for(session_id), do: :persistent_term.get(depth_key(session_id), :standard)
```

Add `{"idea", "Start the idea-shaping workflow"}`, `{"research", "Start the opportunity-discovery workflow"}`, `{"depth", "Change research depth (quick/standard/deep)"}` to the `@commands` list at the top of the file, in the position matching §10's command table order.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/session/commands_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/sprat/session/commands.ex test/sprat/session/commands_test.exs
git commit -m "Wire /idea, /research, /depth to Sprat.Orchestrator"
```

---

### Task 12: Feed the Mission zone checklist and budget meter from real stage state

**Files:**
- Modify: `lib/sprat/orchestrator.ex` (`announce_stage/2` needs to broadcast the full checklist, not just the agent card)
- Test: extend `test/sprat/orchestrator_test.exs`

**Interfaces:**
- Consumes: `Sprat.Terminal.Zones.Mission.handle_view_update/2`'s existing `%{activity:, checklist:, budget:, mode:}` shape (already implemented — see Task read of `lib/sprat/terminal/zones/mission.ex`; `checklist` is `%{stages: [{label, status}]}` where `status` is `:done | :active | :queued`).
- Produces: after every stage transition, `PubSub.broadcast(session_id, {:live_updated, %{checklist: %{stages: [...]}}})` reflecting every stage of the current template with its real status, plus the existing `broadcast_budget/3`-equivalent (reuse `Sprat.Mission`'s exact `broadcast_budget/3` logic — extract it to a shared helper if convenient, or duplicate the ~10 lines; either is acceptable, note the choice in the commit).

- [ ] **Step 1: Write the failing test**

```elixir
test "each stage transition broadcasts the full checklist with real per-stage status", %{store: store, session: session} do
  model = Sprat.StubModel.scripted_for_idea_delivery()
  Sprat.Session.PubSub.subscribe(session.id)

  :ok =
    Orchestrator.start(session.id, "gym booking software", Idea, :quick,
      store: store, budget: :"budget_#{session.id}", model_mod: model,
      model_id: "stub-model", api_key: "test-key", sync?: true)

  checklists =
    Stream.repeatedly(fn -> receive do msg -> msg after 0 -> nil end end)
    |> Enum.take_while(&(not is_nil(&1)))
    |> Enum.filter(&match?({:live_updated, %{checklist: _}}, &1))

  assert length(checklists) >= 6
  {:live_updated, %{checklist: %{stages: stages}}} = List.last(checklists)
  assert Enum.map(stages, &elem(&1, 0)) == ["Intake", "Research", "Analysis", "Directions", "Recommendation", "Brief + validation plan"]
  assert Enum.all?(stages, fn {_label, status} -> status in [:done, :active, :queued] end)
end
```

Check `Sprat.Session.PubSub.subscribe/1`'s real name/arity in `lib/sprat/session/pub_sub.ex` before writing this — adjust if it differs.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

```elixir
defp announce_stage(session_id, template, stage) do
  :ok = Session.add_block(session_id, %{kind: :stage_change, name: stage.title, reason: nil})

  PubSub.broadcast(session_id, {:agents_updated, %{agents: [%{id: stage.id, role: String.to_atom(stage.role),
    label: stage.title, state: :active, elapsed_s: nil, tokens: nil, activity: "starting", stream_tail: nil}]}})

  broadcast_checklist(session_id, template, stage.id, :active)
end

defp broadcast_checklist(session_id, template, current_stage_id, current_status) do
  stages =
    Enum.map(template.stages, fn s ->
      status =
        cond do
          s.id == current_stage_id -> current_status
          stage_before?(template, s.id, current_stage_id) -> :done
          true -> :queued
        end

      {s.title, status}
    end)

  PubSub.broadcast(session_id, {:live_updated, %{checklist: %{stages: stages}}})
end

defp stage_before?(template, id, current_id) do
  ids = Enum.map(template.stages, & &1.id)
  Enum.find_index(ids, &(&1 == id)) < Enum.find_index(ids, &(&1 == current_id))
end
```

Call `announce_stage(session_id, template, stage)` (now arity 3 — update the one call site in `run_stage/12`) and call `broadcast_checklist(session_id, template, stage.id, :done)` right after a stage's gate passes in `finish_stage/12`, before `advance/9` runs.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 5: Verify on the real screen, not just the pure unit test**

A unit test asserting on a `checklist` map is not evidence the terminal
actually paints it correctly (mismatched keys, a status atom the zone
doesn't recognise, a broadcast that never reaches a live renderer all pass
a mocked-PubSub test and still show a blank Mission zone on screen). Build
the release and drive it under `tmux`:

```bash
mix release sprat_rt --overwrite
tmux new-session -d -s sdd-task12 -x 220 -y 50
tmux send-keys -t sdd-task12 '_build/dev/rel/sprat_rt/bin/sprat' Enter
sleep 2
tmux send-keys -t sdd-task12 '/idea a tool for a small niche you can research in one message' Enter
sleep 8
tmux capture-pane -t sdd-task12 -p > /tmp/sdd-task12-checklist.txt
cat /tmp/sdd-task12-checklist.txt
```

This needs a real (or the test double already wired into `sprat doctor`'s
key resolution — check whether the launcher can run with no key and still
reach the checklist-broadcast point before Intake calls the model; if it
cannot get far enough without a key, this step is deferred to Task 17
where a real key is available, and this task's report must say so
explicitly rather than silently skipping the check) `OPENAI_API_KEY`. The
capture must show the Mission zone's checklist with at least the Intake
stage's status glyph, matching `Sprat.Terminal.Zones.Mission`'s existing
glyph rendering (✓/▸/○ or their ASCII fallbacks). Save the capture as part
of the task report; the reviewer reads it, not just the diff.

- [ ] **Step 6: Commit**

```bash
git add lib/sprat/orchestrator.ex test/sprat/orchestrator_test.exs
git commit -m "Broadcast the real stage checklist to the Mission zone"
```

---

### Task 13: Artifacts tab in the Inspector; `/artifacts`, `/open`, `/claims`, `/export` against real rows

**Files:**
- Modify: `lib/sprat/terminal/zones/inspector.ex` (add `:artifacts` to `@tabs`, `items_for/2`, `item_line/2`, `empty_state/1`)
- Modify: `lib/sprat/session/commands.ex` (add `/artifacts`, `/open`, `/claims`; `/export` already exists per the file read in Task 11 — verify it includes artifacts/claims/decisions and extend if not)
- Modify: `lib/sprat/orchestrator.ex` (broadcast the `:artifacts` inspector data alongside the existing sources/tasks broadcast — reuse `Sprat.Mission.broadcast_inspector/3`'s shape, extended with an `:artifacts` key)
- Test: `test/sprat/terminal/zones/inspector_test.exs` (extend), `test/sprat/session/commands_test.exs` (extend)

**Interfaces:**
- Consumes: `Sprat.Store.Artifacts.by_mission/2` and `.versions/2` (Task 6).
- Produces: Inspector's Artifacts tab lists `%{type, latest_version, owning_role}`; `Enter` on a row emits `{:open_detail, {:artifacts, artifact}}` (already handled generically by `Terminal.Zones.Inspector.open/2` — no change needed there beyond adding `:artifacts` to `@tabs`/`items_for/2`/`item_line/2`/`empty_state/1`). `/artifacts` prints the same list as text; `/open <type>` pages the latest version's content through `$PAGER` (mirror however the existing `/open` — check if one already exists for events/sources; if not, add it following the `export/2` function's file-writing pattern in `commands.ex`, then shell out to `System.get_env("PAGER", "less")`).

- [ ] **Step 1: Write the failing tests**

```elixir
# test/sprat/terminal/zones/inspector_test.exs (extend)
test "artifacts tab lists type, version and owning role; empty state names what's missing" do
  state = Sprat.Terminal.Zones.Inspector.init([])
  assert %{tab_index: _} = state
  # switch_tab/2 to :artifacts (add helper or loop switch_tab 5 times to wrap to it — check @tabs order)
  # with no artifacts: render/4 shows "No artifacts written yet."
  # handle_view_update/2 with %{artifacts: [%{type: "research_memo", latest_version: 2, owning_role: "researcher"}]}
  # then item_line renders "research_memo v2 (researcher)"
end
```

```elixir
# test/sprat/session/commands_test.exs (extend)
test "/artifacts lists every artifact written in the session's latest mission", %{session_id: session_id, store: store} do
  # seed via Sprat.Store.Artifacts.write/3 directly, call Commands.handle(session_id, store, "/artifacts"),
  # assert the resulting system block mentions the type and version
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/sprat/terminal/zones/inspector_test.exs test/sprat/session/commands_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `lib/sprat/terminal/zones/inspector.ex`:

```elixir
@tabs [:evidence, :tasks, :usage, :events, :messages, :artifacts]
```

add `artifacts: []` to the `defstruct`, add to `handle_view_update/2`'s merge, add:

```elixir
defp items_for(state, :artifacts), do: state.artifacts
defp empty_state(:artifacts), do: "No artifacts written yet."
defp item_line(:artifacts, a), do: "#{a.type} v#{a.latest_version} (#{a.owning_role})"
```

In `lib/sprat/orchestrator.ex`, add a `broadcast_inspector/3` (same shape as `Sprat.Mission`'s, plus `:artifacts`):

```elixir
defp broadcast_inspector(session_id, mission_id, store) do
  PubSub.broadcast(session_id, {:inspector_updated, %{
    sources: Sources.by_mission(store, mission_id),
    tasks: Tasks.by_mission(store, mission_id),
    artifacts: Artifacts.by_mission(store, mission_id),
    events: [],
    usage: Sprat.Store.Projection.usage_totals(store, mission_id)
  }})
end
```

Call it after every `finish_stage/12` (gate pass or fail) and after `retry_or_surface/12`.

In `lib/sprat/session/commands.ex`, add:

```elixir
"artifacts" -> artifacts(session_id, store)
"open" -> open_artifact(session_id, store, arg)
"claims" -> claims(session_id, store)
```

```elixir
defp artifacts(session_id, store) do
  case latest_mission(store, session_id) do
    nil -> system(session_id, ["No mission yet."])
    mission ->
      list = Sprat.Store.Artifacts.by_mission(store, mission.id)
      lines = Enum.map(list, &"  #{&1.type} v#{&1.latest_version} (#{&1.owning_role})")
      system(session_id, if(list == [], do: ["No artifacts yet."], else: ["Artifacts:" | lines]))
  end
end

defp open_artifact(session_id, store, type) do
  case latest_mission(store, session_id) do
    nil -> system(session_id, ["No mission yet."])
    mission ->
      case Sprat.Store.Artifacts.latest(store, mission.id, String.to_existing_atom(type)) do
        nil -> system(session_id, ["No artifact of type #{type} yet."])
        content -> page(JSON.encode!(content, pretty: true))
      end
  end
rescue
  ArgumentError -> system(session_id, ["Unknown artifact type: #{type}"])
end

defp claims(session_id, store) do
  case latest_mission(store, session_id) do
    nil -> system(session_id, ["No mission yet."])
    mission ->
      list = Sprat.Store.Claims.by_mission(store, mission.id)
      unsourced = Enum.filter(list, &(&1.is_assumption and &1.confidence == "low"))
      sourced = list -- unsourced
      lines = Enum.map(unsourced ++ sourced, &"  (#{&1.confidence}) #{&1.text}#{if &1.is_assumption, do: " [assumption]", else: ""}")
      system(session_id, if(list == [], do: ["No claims recorded yet."], else: ["Claims (unsupported first):" | lines]))
  end
end

defp latest_mission(store, session_id) do
  store |> Sprat.Store.Missions.by_session(session_id) |> List.last()
end

defp page(text) do
  path = Path.join(System.tmp_dir!(), "sprat_open_#{System.unique_integer([:positive])}.txt")
  File.write!(path, text)
  System.cmd(System.get_env("PAGER", "less"), [path], into: IO.stream(:stdio, :line))
  File.rm(path)
  :ok
end
```

Add `{"artifacts", "Artifact list and versions"}`, `{"open", "Page an artifact through $PAGER"}`, `{"claims", "Claims with confidence, unsupported first"}` to `@commands`.

Check the existing `export/2` in the file (found in Task 11's read) and extend it to also write artifacts and decisions if it currently only writes sources/usage — read that function's full body before editing (it was truncated in the earlier read).

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/sprat/terminal/zones/inspector_test.exs test/sprat/session/commands_test.exs`
Expected: PASS

- [ ] **Step 5: Verify on the real screen**

Same reasoning as Task 12's Step 5 — a pure-zone unit test is not proof the
Artifacts tab renders or that `/open` actually pages content. Build the
release (`mix release sprat_rt --overwrite` if not already built this
session) and, under `tmux`, drive a session far enough to have at least one
artifact (an `/idea` run that reaches Intake, or seed one directly via
`bin/sprat eval` calling `Sprat.Store.Artifacts.write/3` against the
running session's store if driving a full stage is too slow for this
task alone), then:

```bash
tmux send-keys -t sdd-task13 '/artifacts' Enter
sleep 1
tmux send-keys -t sdd-task13 'Alt+4' # or whatever switches focus to the Inspector zone per docs/design/tui-zones.md's keys table
sleep 1
tmux send-keys -t sdd-task13 ']' # cycle to the Artifacts tab
sleep 1
tmux capture-pane -t sdd-task13 -p > /tmp/sdd-task13-artifacts.txt
cat /tmp/sdd-task13-artifacts.txt
```

The capture must show the artifact type and version in the Inspector, and
`/artifacts`' text output in the Conversation zone. Save it as part of the
task report.

- [ ] **Step 6: Commit**

```bash
git add lib/sprat/terminal/zones/inspector.ex lib/sprat/session/commands.ex lib/sprat/orchestrator.ex \
  test/sprat/terminal/zones/inspector_test.exs test/sprat/session/commands_test.exs
git commit -m "Add Artifacts inspector tab and /artifacts, /open, /claims commands"
```

---

### Task 14: `Sprat.Store.MissionState` and a real `paused_budget` mission status

The earlier self-review flagged that `missions.status` is a free-text column
with no enum and nothing ever sets it to anything but `"active"` — so a
mission out of budget would say `"active"` in the UI, which is a lie to the
user (docs/spec-v1.md §12: "the mission enters `paused_budget`"). This task
closes that gap properly: a pure state machine (mirroring
`Sprat.Store.TaskState` exactly), a real column constraint via migration,
and a `Missions.transition/4` that writes status + event in one transaction
(mirroring `Sprat.Store.Tasks.transition/4`).

**Files:**
- Modify: `lib/sprat/store/migrations.ex` (add migration version 3)
- Create: `lib/sprat/store/mission_state.ex`
- Modify: `lib/sprat/store/missions.ex` (add `transition/4`)
- Test: `test/sprat/store/mission_state_test.exs`, `test/sprat/store/migrations_test.exs` (extend — read it first for its existing upgrade-path test pattern; if no such file exists, create one modeled on how `test/sprat/store/tasks_test.exs` exercises `Tasks.transition/4`), extend `test/sprat/store/missions_test.exs`

**Interfaces:**
- Produces: `Sprat.Store.MissionState.states/0 :: [:active, :paused_budget, :completed, :failed, :cancelled]`, `.valid?(from, to) :: boolean()`, `.transition(from, to) :: {:ok, to} | {:error, :invalid_transition}`. `Sprat.Store.Missions.transition(store, mission_id, to_status, attrs) :: {:ok, Missions.t()} | {:error, :invalid_transition} | {:error, :not_found}` — same signature shape as `Sprat.Store.Tasks.transition/4`, `attrs` requires `:session_id`, accepts `:reason`.

- [ ] **Step 1: Write the failing test — pure state machine**

```elixir
defmodule Sprat.Store.MissionStateTest do
  use ExUnit.Case, async: true

  alias Sprat.Store.MissionState

  test "active can move to paused_budget, completed, failed or cancelled" do
    assert MissionState.valid?(:active, :paused_budget)
    assert MissionState.valid?(:active, :completed)
    assert MissionState.valid?(:active, :failed)
    assert MissionState.valid?(:active, :cancelled)
  end

  test "paused_budget can resume to active, or terminate" do
    assert MissionState.valid?(:paused_budget, :active)
    assert MissionState.valid?(:paused_budget, :cancelled)
    assert MissionState.valid?(:paused_budget, :failed)
  end

  test "terminal states have no outgoing transitions" do
    for terminal <- [:completed, :failed, :cancelled] do
      refute MissionState.valid?(terminal, :active)
      refute MissionState.valid?(terminal, :paused_budget)
    end
  end

  test "transition/2 returns the pair the caller expects" do
    assert {:ok, :paused_budget} = MissionState.transition(:active, :paused_budget)
    assert {:error, :invalid_transition} = MissionState.transition(:completed, :active)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/sprat/store/mission_state_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Write minimal implementation**

```elixir
defmodule Sprat.Store.MissionState do
  @moduledoc """
  Pure mission state machine (docs/spec-v1.md §12: "the mission enters
  `paused_budget`"). Mirrors `Sprat.Store.TaskState` exactly — same shape,
  same "no process, no IO" contract, exhaustively unit tested over every
  state pair. `paused_budget` is a real, resumable state: the user can
  raise the cap and the mission returns to `active`, per §12 "the user can
  raise the limit or export what exists."
  """

  @states [:active, :paused_budget, :completed, :failed, :cancelled]

  @transitions %{
    active: [:paused_budget, :completed, :failed, :cancelled],
    paused_budget: [:active, :cancelled, :failed],
    completed: [],
    failed: [],
    cancelled: []
  }

  def states, do: @states

  def valid?(from, to) when from in @states and to in @states do
    to in Map.fetch!(@transitions, from)
  end

  def valid?(_from, _to), do: false

  def transition(from, to) do
    if valid?(from, to), do: {:ok, to}, else: {:error, :invalid_transition}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/sprat/store/mission_state_test.exs`
Expected: PASS

- [ ] **Step 5: Add migration version 3 — a real CHECK constraint, with an upgrade-path test**

SQLite cannot `ALTER TABLE ... ADD CONSTRAINT`; the standard safe pattern is
create-new/copy/drop-old/rename, inside the same transaction `apply_migration/3`
already wraps every migration in (see `lib/sprat/store/migrations.ex`, read
in full before editing — follow its exact `{version, description, sql}`
tuple shape and its `;`-split statement execution).

First, the failing test (upgrade path from a v2 database with existing rows):

```elixir
# test/sprat/store/migrations_test.exs — add this case; if the file
# doesn't exist yet, create it and mirror the setup pattern
# `test/support/store_case.ex` already uses for a bare connection (a
# migration test needs a raw connection, not the full Store GenServer —
# check how other tests in this suite open one, e.g. via
# `Exqlite.Sqlite3.open/1` + `Sprat.Store.Migrations.migrate/1` directly,
# and match that pattern instead of inventing a new one).
test "migrating from version 2 to version 3 preserves existing mission rows and adds the status constraint" do
  {:ok, conn} = Exqlite.Sqlite3.open(":memory:")

  # Apply only migrations 1 and 2 by hand (copy the relevant SQL strings
  # from Sprat.Store.Migrations's @migrations, or call a helper that
  # applies up to a given version if one exists — check the module for
  # this before duplicating SQL).
  # ... apply v1 and v2 ...

  # Insert a session + mission row with the pre-migration-3 schema (status
  # free text, e.g. "active") to prove data survives the rebuild.
  # ... INSERT INTO sessions ...; INSERT INTO missions (..., status, ...) VALUES (..., 'active', ...) ...

  :ok = Sprat.Store.Migrations.migrate(conn)

  # The migrated row is still there with the same status:
  # SELECT status FROM missions WHERE id = ? -> "active"

  # And the constraint rejects a bogus status now:
  # INSERT INTO missions (..., status, ...) VALUES (..., 'bogus_status', ...)
  # must raise/return a constraint-violation error from Exqlite.
end
```

Then add to `@migrations` in `lib/sprat/store/migrations.ex`:

```elixir
{3, "missions: status becomes a checked enum including paused_budget (docs/spec-v1.md §12)",
 """
 CREATE TABLE missions_new (
   id TEXT PRIMARY KEY,
   session_id TEXT NOT NULL REFERENCES sessions(id),
   objective TEXT NOT NULL,
   status TEXT NOT NULL CHECK (status IN ('active', 'paused_budget', 'completed', 'failed', 'cancelled')),
   budget_cents TEXT,
   created_at TEXT NOT NULL,
   updated_at TEXT NOT NULL
 );
 INSERT INTO missions_new SELECT id, session_id, objective, status, budget_cents, created_at, updated_at FROM missions;
 DROP TABLE missions;
 ALTER TABLE missions_new RENAME TO missions;
 CREATE INDEX idx_missions_session ON missions(session_id);
 """}
```

Note: every existing row's `status` is `"active"` (the only value `Sprat.Store.Missions.create/3` has ever written — confirmed in the earlier read of that file), so the `INSERT INTO missions_new SELECT ...` is guaranteed to satisfy the new CHECK constraint for every pre-existing database. If this assumption is wrong for any fixture database in the test suite, the test in this step will fail loudly at the migration step, not silently corrupt data — investigate rather than loosening the constraint.

- [ ] **Step 6: Run the migration test**

Run: `mix test test/sprat/store/migrations_test.exs`
Expected: PASS. Also run `mix test test/sprat/store/missions_test.exs` (existing file) to confirm nothing there broke.

- [ ] **Step 7: Add `Sprat.Store.Missions.transition/4`**

```elixir
# in lib/sprat/store/missions.ex, alongside the existing create/get/by_session

alias Sprat.Store.{Events, MissionState, SQL}

@doc """
Transitions `mission_id` to `to_status` (docs/spec-v1.md §13: state change
+ event in one transaction). Mirrors `Sprat.Store.Tasks.transition/4`
exactly. `attrs` requires `:session_id`, accepts `:reason`.
"""
def transition(store \\ Sprat.Store, mission_id, to_status, attrs) do
  Sprat.Store.transact(store, fn conn -> transition_in_conn(conn, mission_id, to_status, attrs) end)
  |> case do
    {:ok, {:error, reason}} -> {:error, reason}
    {:ok, mission} -> {:ok, mission}
    {:error, reason} -> {:error, reason}
  end
end

def transition_in_conn(conn, mission_id, to_status, attrs) do
  to_status = to_string(to_status)

  case SQL.fetch_one(conn, "SELECT * FROM missions WHERE id = ?1", [mission_id]) do
    nil ->
      {:error, :not_found}

    row ->
      Code.ensure_loaded!(MissionState)
      from_status = String.to_existing_atom(row["status"])

      case MissionState.transition(from_status, String.to_existing_atom(to_status)) do
        {:error, reason} ->
          {:error, reason}

        {:ok, _} ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          SQL.exec(conn, "UPDATE missions SET status = ?1, updated_at = ?2 WHERE id = ?3", [to_status, now, mission_id])

          Events.append_in_conn(conn, Map.fetch!(attrs, :session_id), "mission.transitioned", %{
            mission_id: mission_id,
            payload: %{"from" => row["status"], "to" => to_status, "reason" => attrs[:reason]}
          })

          case SQL.fetch_one(conn, "SELECT * FROM missions WHERE id = ?1", [mission_id]) do
            nil -> nil
            row -> row_to_mission(row)
          end
      end
  end
end
```

Extend `test/sprat/store/missions_test.exs` with a case proving `transition/4` moves `active -> paused_budget` and writes a `mission.transitioned` event, and that `completed -> active` is rejected without writing anything.

- [ ] **Step 8: Run all of this task's tests plus the full suite**

Run: `mix test test/sprat/store/mission_state_test.exs test/sprat/store/migrations_test.exs test/sprat/store/missions_test.exs`
Expected: PASS. Then `mix test` (full suite) to confirm the migration change breaks nothing elsewhere — every other test that creates a mission still only ever writes `"active"`, so this should be a no-op for them.

- [ ] **Step 9: Commit**

```bash
git add lib/sprat/store/migrations.ex lib/sprat/store/mission_state.ex lib/sprat/store/missions.ex \
  test/sprat/store/mission_state_test.exs test/sprat/store/migrations_test.exs test/sprat/store/missions_test.exs
git commit -m "Add a real paused_budget mission status: migration, state machine, transition/4"
```

---

### Task 15: Budget exhaustion mid-workflow and resume without re-running a completed stage

**Files:**
- Modify: `lib/sprat/orchestrator.ex`
- Modify: `lib/sprat/store/recovery.ex` (verify — likely no change needed, since it already scopes to `running` tasks only; add a doc note and a test proving staged-mission resume specifically)
- Test: extend `test/sprat/orchestrator_test.exs`, new `test/sprat/store/recovery_test.exs` case if one doesn't already cover this

**Interfaces:**
- Consumes: `Sprat.Budget.reserve/3`'s existing `{:error, {:would_exceed_cap, _}}` (already returned by the existing `Sprat.Budget` module — see the earlier read). `Sprat.Store.Missions.transition/4` (Task 14).
- Produces: when a stage's `Loop.run/1` returns `{:error, {:would_exceed_cap, _}}`, the Orchestrator transitions the mission's current task to `failed` with that reason, transitions the **mission itself** to `paused_budget` via `Missions.transition/4` (a real state, not just a system message — the gap Task 14 closed), and posts a system block saying so per §12 ("the user can raise the limit or export what exists"). Feed the mission's `status` into the Mission zone's broadcast (`broadcast_checklist`/a small addition to the budget line, e.g. append `" — PAUSED (budget)"` when status is `paused_budget`) so the screen agrees with the stored state.

- [ ] **Step 1: Write the failing test — budget exhaustion**

```elixir
test "budget exhaustion mid-workflow stops the stage and names it, without crashing later stages' state", %{store: store, session: session} do
  model = Sprat.StubModel.scripted_for_idea_delivery()

  :ok =
    Orchestrator.start(session.id, "gym booking software", Idea, :quick,
      store: store, budget: :"budget_#{session.id}", model_mod: model,
      model_id: "stub-model", api_key: "test-key",
      budget_cap: Decimal.new("0.00"), sync?: true)

  [mission] = Missions.by_session(store, session.id)
  [intake_task] = Tasks.by_mission(store, mission.id)
  assert intake_task.status == "failed"
end
```

- [ ] **Step 2: Run test to verify it fails (or note it already passes if `finish_error`-equivalent handling was already generic enough)**

Run: `mix test test/sprat/orchestrator_test.exs`

- [ ] **Step 3: Implement (only if Step 2 failed)**

`settle_stage/13`'s existing `{:error, reason}` branch already calls `safe_transition(store, task.id, :failed, ...)` and posts a system message — confirm `{:would_exceed_cap, _}` reaches that branch (it does, via `Loop.run/1`'s existing `{:error, reason}` return for a reservation failure — no special-casing needed beyond a clearer message):

```elixir
defp settle_stage(session_id, store, budget_mod, mission, template, stage, task, text, model_id, api_key, catalog, opts, {:error, {:would_exceed_cap, detail}}) do
  safe_transition(store, task.id, :failed, session_id, "would exceed mission budget cap")

  case Sprat.Store.Missions.transition(store, mission.id, :paused_budget, %{
         session_id: session_id,
         reason: "would exceed mission budget cap: #{inspect(detail)}"
       }) do
    {:ok, _mission} -> :ok
    # Already paused_budget or otherwise terminal (e.g. a second stage
    # racing the same exhausted cap) — MissionState rejects the
    # transition rather than crashing; the task-level failure above and
    # the system message below still stand regardless.
    {:error, _} -> :ok
  end

  system(session_id, [
    "Mission paused (budget): the cap would be exceeded (#{inspect(detail)}). " <>
      "Raise the cap or export what exists — later stages were not started."
  ])
end
```

Add this clause **before** the generic `{:error, reason}` clause (Elixir matches top to bottom; a more specific pattern must come first). This requires `Sprat.Store.Missions` (Task 14's `transition/4`) to be aliased in `lib/sprat/orchestrator.ex`'s `alias Sprat.Store.{...}` list if it isn't already — add it there rather than fully-qualifying every call site.

- [ ] **Step 4: Write the failing test — resume without re-running a completed stage**

```elixir
# test/sprat/store/recovery_test.exs (new file, or extend existing)
test "a staged mission interrupted mid-stage resumes from the last completed stage, not from the start" do
  store = start_store!()
  {:ok, session} = Sprat.Store.Sessions.create(store, %{project_path: "/tmp/x"})
  {:ok, mission} = Sprat.Store.Missions.create(store, session.id, %{objective: "test"})

  {:ok, intake} = Sprat.Store.Tasks.create(store, mission.id, %{role: "researcher", objective: "Intake"})
  {:ok, intake} = Sprat.Store.Tasks.transition(store, intake.id, :running, %{session_id: session.id})
  {:ok, _} = Sprat.Store.Tasks.transition(store, intake.id, :review_pending, %{session_id: session.id})
  {:ok, _} = Sprat.Store.Tasks.transition(store, intake.id, :completed, %{session_id: session.id})

  {:ok, research} = Sprat.Store.Tasks.create(store, mission.id, %{role: "researcher", objective: "Research"})
  {:ok, _} = Sprat.Store.Tasks.transition(store, research.id, :running, %{session_id: session.id})
  # simulate a kill -9: research stays "running" in the DB, no clean shutdown

  reclassified = Sprat.Store.Recovery.scan(store, session.id)
  assert reclassified == [research.id]

  tasks = Sprat.Store.Tasks.by_mission(store, mission.id)
  assert Enum.find(tasks, &(&1.id == intake.id)).status == "completed"
  assert Enum.find(tasks, &(&1.id == research.id)).status == "interrupted"
end
```

This proves the existing `Sprat.Store.Recovery.scan/2` (unchanged, read in the earlier context-gathering step) already gives the Orchestrator what §13 Recovery needs: a completed stage's task row is never touched, and only the genuinely-mid-flight stage becomes `interrupted`, ready for the TUI's existing resume/skip/cancel prompt (`Sprat.Session`'s `pending_recoveries`/`recovery_choice/2`, unchanged). **No Orchestrator code change is needed for this — the task exists to prove it with a test, since nothing exercised `Recovery.scan/2` against a *multi-task* mission before.**

- [ ] **Step 5: Run all recovery + orchestrator tests**

Run: `mix test test/sprat/store/recovery_test.exs test/sprat/orchestrator_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/sprat/orchestrator.ex test/sprat/orchestrator_test.exs test/sprat/store/recovery_test.exs
git commit -m "Handle budget exhaustion mid-workflow; prove staged-mission resume skips completed stages"
```

---

### Task 16: Full verification pass

**Files:** none created — this task runs the project's existing gates.

- [ ] **Step 1: Compiler warnings**

Run: `mix compile --warnings-as-errors`
Expected: clean. Fix any warning in a file this plan touched before proceeding (per CLAUDE.md: fix every compiler warning in files you touch).

- [ ] **Step 2: Formatting**

Run: `mix format --check-formatted`
Expected: clean, or run `mix format` and re-check.

- [ ] **Step 3: Full test suite, 10 consecutive clean runs**

Run: `for i in $(seq 1 10); do mix test || break; done`
Expected: all 10 runs pass. A flaky run points at a race in the Orchestrator's `:persistent_term` stall tracker or busy guard — investigate before moving on, do not retry past it.

- [ ] **Step 4: `test/tty/verify.sh`**

Read `test/tty/verify.sh` first to learn its existing assertion style, then add two new assertions matching that style: one driving `/idea <short idea>` against a stubbed/mocked model (check how the script already avoids live API calls, if at all — it may require a real key; if so, this step needs `.env` with `OPENAI_API_KEY` and should use `:quick` depth to bound cost) and capturing that the stage checklist in the Mission zone advances past at least one stage, and one opening an artifact via `/open` (or `Enter` on the Inspector's Artifacts tab) and confirming its content renders in the Detail zone.

Run: `bash test/tty/verify.sh`
Expected: fully green, including the two new assertions.

- [ ] **Step 5: Commit** (only if Step 4 required script changes)

```bash
git add test/tty/verify.sh
git commit -m "Add tmux assertions for the staged checklist and artifact open"
```

---

### Task 17: Live end-to-end run — `/idea` at quick depth, real spend capped at $3

**Not a code task.** Run manually (or have an executing agent run it) after Task 16 is fully green:

- [ ] **Step 1:** Confirm `.env` has a real `OPENAI_API_KEY` (per the codebase's existing key resolution in `lib/sprat/secrets.ex` — `sprat doctor` confirms it's found).
- [ ] **Step 2:** Set the mission budget cap to `$3.00` explicitly (the confirm-budget prompt in `Sprat.Orchestrator.start/5`'s `opts` — pass `budget_cap: Decimal.new("3.00")`, or answer the TUI's budget prompt with a custom low cap if the picker doesn't yet offer $3 as a named option; if it only offers $5/$15, note this as a real gap between the plan and `Sprat.Mission`'s existing `confirm_budget/2` prompt, and either extend that prompt to accept a typed custom amount or temporarily set `[budget] default_usd = "3.00"` in `.sprat/config.toml` for this run).
- [ ] **Step 3:** Under `tmux`, run `bin/sprat` (or `mix run` equivalent per the project's existing dev-run instructions — check `docs/` or the Makefile/README for the exact command) in a small real project directory, type `/idea a tool that helps independent gym owners in the UK manage class bookings`, and let it run to Delivery at `:quick` depth (bounded by `Depth.limits(:quick).wall_seconds = 300` per stage).
- [ ] **Step 4:** Capture the tmux pane at three points: (a) the Mission zone checklist mid-run with at least one stage marked done and one active, (b) a gate result line (✓ or ✗) in the Conversation zone, (c) an artifact opened in the Inspector/Detail zone via `/open` or `Enter`. Save these as `docs/superpowers/plans/2026-09-20-staged-workflow-live-run/tmux-capture-1.txt` etc. (`tmux capture-pane -p`).
- [ ] **Step 5:** After the run finishes (or is stopped), run `/usage` and record the actual total cost shown (it must be `Decimal`-backed, per `lib/sprat/model/pricing.ex`/`lib/sprat/store/usage.ex` — this is the "actual figure from usage records" the build brief asks for, not an estimate).
- [ ] **Step 6:** Save the final `product_brief` artifact's content (`/open product_brief`) to `docs/superpowers/plans/2026-09-20-staged-workflow-live-run/product-brief.md`.
- [ ] **Step 7:** If total spend would exceed $3.00 before the mission finishes, stop the mission (`Ctrl+C`, or let the budget-exhaustion handling from Task 15 stop it automatically) and export what exists via `/export` rather than continuing past the cap — the brief's instruction is a **hard** cap, not a target.

No commit for this task (it produces evidence files, not code) — reference the capture and brief paths in the final report back to the user.

---

## Self-Review Notes (for whoever picks this plan up)

- **Spec coverage:** §5 workflows → Tasks 3, 8, 9. §5 Gates table → Task 4. §6 evidence/claims/scorecard → Tasks 2, 4, 5. §8 task states/scheduling/stall/context package → Tasks 8, 10, 14. §4 single-role scoping → encoded in `Template.Stage.role` (Task 1) and never hardcoded in `Sprat.Orchestrator` (Task 8) — this is the answer to "where is the single-role assumption encoded" the build brief asks the report to name. §7 no-search-tool honesty → the stage prompts in Task 3 explicitly say "no live search" and rely only on `web_fetch`. §10 UI feed → Tasks 12, 13. §13 Orchestrator-is-code / transactional state+event → every task-state change in Task 8 routes through the existing `Sprat.Store.Tasks.transition/4`, never a raw update.
- **`paused_budget` gap closed, not deferred:** the original self-review flagged that `missions.status` was free text with nothing ever setting `paused_budget` (§12). Task 14 closes this properly — `Sprat.Store.MissionState` (a pure state machine mirroring `Sprat.Store.TaskState`), a migration (version 3) that rebuilds the `missions` table with a real `CHECK` constraint including `paused_budget`, and `Sprat.Store.Missions.transition/4` (status + event in one transaction, mirroring `Tasks.transition/4`). Task 15 then uses it: a budget-exhausted stage transitions both its task to `failed` *and* the mission itself to `paused_budget`, and the Mission zone shows it. If the live run in Task 17 shows this still reads wrong in the UI, that is now a real regression to fix, not a known-and-accepted gap.
- **Search backend:** per the build brief's "what search would need" — report back that Sprat's research stages are honest-but-blind: no discovery of *new* URLs beyond what the user supplies or what's linked from an already-fetched page. A working `/research` needs a real `web_search` tool (§7's Anthropic-server-tool or Brave/Tavily fallback) before its "landscape research" stage can find anything beyond what the user already knew to link.
