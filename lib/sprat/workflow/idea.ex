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

  alias Sprat.Workflow.{ArtifactSchema, Depth, Template}

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
          prompt: with_shapes(intake_prompt(), [:intake_summary]),
          required_inputs: [],
          deliverables: [:intake_summary],
          gate: :intake_to_research,
          limits: limits
        ),
        Template.stage(
          id: :research,
          title: "Research",
          role: @role,
          prompt: with_shapes(research_prompt(depth), [:research_memo, :source_register]),
          required_inputs: [:intake_summary],
          deliverables: [:research_memo, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :analysis,
          title: "Analysis",
          role: @role,
          prompt: with_shapes(analysis_prompt(), [:assumption_register]),
          required_inputs: [:research_memo, :source_register],
          deliverables: [:assumption_register],
          gate: :analysis_gate,
          limits: limits
        ),
        Template.stage(
          id: :directions,
          title: "Directions",
          role: @role,
          prompt: with_shapes(directions_prompt(), [:product_directions]),
          required_inputs: [:assumption_register],
          deliverables: [:product_directions],
          gate: nil,
          limits: limits
        ),
        Template.stage(
          id: :recommendation,
          title: "Recommendation",
          role: @role,
          prompt: with_shapes(recommendation_prompt(), [:recommendation_memo]),
          required_inputs: [:product_directions],
          deliverables: [:recommendation_memo],
          gate: :recommendation_to_delivery,
          limits: limits
        ),
        Template.stage(
          id: :delivery,
          title: "Brief + validation plan",
          role: @role,
          prompt: with_shapes(delivery_prompt(), [:product_brief, :validation_plan]),
          required_inputs: [:recommendation_memo],
          deliverables: [:product_brief, :validation_plan],
          gate: :delivery_gate,
          limits: limits
        )
      ]
    )
  end

  # Splices `Sprat.Workflow.ArtifactSchema.describe/1` for each of this
  # stage's deliverables onto its hand-written prose (build brief item 4:
  # "generate the shape description that goes into the prompt FROM the
  # schema itself"). The prose above still carries the *what and why* of a
  # stage; this is the *exact shape*, generated from the same source the
  # gate validates against, so the two can never drift the way they did
  # live — a stage prompt saying "risk rating" in prose while the schema
  # silently also accepted `risk_rank` was harmless, but a schema
  # requiring a field the prose never mentioned at all is exactly how
  # `research_memo`'s missing `claims`/`limitations` kept happening.
  defp with_shapes(prompt, types) do
    Enum.reduce(types, prompt, fn type, acc -> acc <> "\n\n" <> ArtifactSchema.describe(type) end)
  end

  defp intake_prompt do
    "Restate the user's idea in your own words. You do not get to ask the user directly " <>
      "in this build — record at most three direction-changing questions (target " <>
      "customer, geography, constraints, intended outcome) as open_questions in the " <>
      "intake_summary artifact instead of asking them in chat. Anything unanswered " <>
      "becomes an assumption, not a blocker. You MUST call write_artifact with type " <>
      "\"intake_summary\" before your final answer — a response with no write_artifact " <>
      "call has not completed this stage."
  end

  defp research_prompt(depth) do
    {min, max} = Depth.source_target(depth)
    target = if max, do: "#{min}-#{max}", else: "#{min}+"

    "Study existing workflows, competitors, alternatives, complaints and " <>
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
    "Write the product_brief and validation_plan artifacts."
  end
end
