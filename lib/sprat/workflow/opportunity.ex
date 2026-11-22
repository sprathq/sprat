defmodule Sprat.Workflow.Opportunity do
  @moduledoc """
  "Discover an opportunity" (docs/spec-v1.md §5.B): Intake → Landscape
  research → Hypotheses → Scoring → Counter-evidence → Recommendation →
  Validation plan → Delivery. Same single-role scope as `Sprat.Workflow.Idea`.
  """

  alias Sprat.Workflow.{ArtifactSchema, Depth, Template}

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
          prompt: with_shapes(intake_prompt(), [:intake_summary]),
          required_inputs: [],
          deliverables: [:intake_summary],
          gate: :intake_to_research,
          limits: limits
        ),
        Template.stage(
          id: :landscape,
          title: "Landscape research",
          role: @role,
          prompt:
            with_shapes(landscape_prompt(depth), [
              :research_memo,
              :competitor_matrix,
              :source_register
            ]),
          required_inputs: [:intake_summary],
          deliverables: [:research_memo, :competitor_matrix, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :hypotheses,
          title: "Hypotheses",
          role: @role,
          prompt:
            with_shapes(
              "Propose 5-10 opportunity hypotheses grounded in the research memo, as " <>
                "an assumption_register artifact ranked by risk.",
              [:assumption_register]
            ),
          required_inputs: [:research_memo],
          deliverables: [:assumption_register],
          gate: :analysis_gate,
          limits: limits
        ),
        Template.stage(
          id: :scoring,
          title: "Scoring",
          role: @role,
          prompt:
            with_shapes(
              "Score the top 3 hypotheses against the §6 weighted dimensions as an " <>
                "opportunity_scorecard artifact (a 1-5 rating per dimension, cited evidence; " <>
                "unknown where unevidenced). You describe the ratings; the code computes totals.",
              [:opportunity_scorecard]
            ),
          required_inputs: [:assumption_register],
          deliverables: [:opportunity_scorecard],
          gate: nil,
          limits: limits
        ),
        Template.stage(
          id: :counter_evidence,
          title: "Counter-evidence",
          role: @role,
          prompt:
            with_shapes(
              "Actively look for evidence against the top-scored hypothesis (same " <>
                "no-live-search constraint as landscape research). Update research_memo and " <>
                "source_register with what you find, including if you find nothing.",
              [:research_memo, :source_register]
            ),
          required_inputs: [:opportunity_scorecard],
          deliverables: [:research_memo, :source_register],
          gate: :research_to_analysis,
          limits: limits
        ),
        Template.stage(
          id: :recommendation,
          title: "Recommendation",
          role: @role,
          prompt:
            with_shapes(
              "Recommend go, revise, validate_first or stop, with tradeoffs and cited " <>
                "evidence, as a recommendation_memo artifact.",
              [:recommendation_memo]
            ),
          required_inputs: [:opportunity_scorecard],
          deliverables: [:recommendation_memo],
          gate: :recommendation_to_delivery,
          limits: limits
        ),
        Template.stage(
          id: :delivery,
          title: "Validation plan",
          role: @role,
          prompt: with_shapes("Write the validation_plan artifact.", [:validation_plan]),
          required_inputs: [:recommendation_memo],
          deliverables: [:validation_plan],
          gate: :validation_plan_gate,
          limits: limits
        )
      ]
    )
  end

  # See `Sprat.Workflow.Idea.with_shapes/2`'s comment — same idea, shared
  # only in spirit (each module owns its own tiny prompt-list, ponytail:
  # not worth a shared helper module for a one-line `Enum.reduce`).
  defp with_shapes(prompt, types) do
    Enum.reduce(types, prompt, fn type, acc -> acc <> "\n\n" <> ArtifactSchema.describe(type) end)
  end

  defp intake_prompt do
    "Restate the market question. You do not get to ask the user directly in this " <>
      "build — record at most three direction-changing questions as open_questions in " <>
      "the intake_summary artifact instead of asking them in chat. You MUST call " <>
      "write_artifact with type \"intake_summary\" before your final answer — a " <>
      "response with no write_artifact call has not completed this stage."
  end

  defp landscape_prompt(depth) do
    {min, max} = Depth.source_target(depth)
    target = if max, do: "#{min}-#{max}", else: "#{min}+"

    "Target #{target} sources. Record every source and material " <>
      "claim before writing research_memo, competitor_matrix and source_register."
  end
end
