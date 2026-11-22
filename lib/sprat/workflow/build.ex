defmodule Sprat.Workflow.Build do
  @moduledoc """
  The build workflow's spine (docs/spec-v2.md §5/§15 Phase A): Technical
  design (SWE, a normal model-driven stage) → [checkpoint 1: design
  approved] → Scaffold (SWE, deterministic — see `Sprat.Build.Scaffold`).
  Phase A stops here; Plan/Implement/Review/Integrate/Acceptance are
  later phases, appended to this same template rather than rebuilding it.

  `/build` (`Sprat.Session.Commands`) seeds a fresh mission with the
  originating mission's `product_brief` artifact before running this
  template's first stage, so `:technical_design`'s `required_inputs:
  [:product_brief]` finds it exactly the way any other stage finds a
  prior stage's deliverable (`Sprat.Orchestrator.build_stage_context/5`)
  — no cross-mission read needed anywhere else.
  """

  alias Sprat.Workflow.{ArtifactSchema, Depth, Template}

  @role "swe"

  def template(depth) when depth in [:quick, :standard, :deep] do
    limits = Depth.limits(depth)

    Template.new(
      id: :build,
      title: "Build",
      stages: [
        Template.stage(
          id: :technical_design,
          title: "Technical design",
          role: @role,
          prompt: with_shapes(design_prompt(), [:technical_design]),
          required_inputs: [:product_brief],
          deliverables: [:technical_design],
          gate: :design_to_scaffold,
          limits: limits
        ),
        Template.stage(
          id: :scaffold,
          title: "Scaffold",
          role: @role,
          prompt: "",
          required_inputs: [:technical_design],
          deliverables: [],
          gate: :scaffold_gate,
          limits: limits,
          executor: &Sprat.Build.Scaffold.run/4
        )
      ]
    )
  end

  defp with_shapes(prompt, types) do
    Enum.reduce(types, prompt, fn type, acc -> acc <> "\n\n" <> ArtifactSchema.describe(type) end)
  end

  defp design_prompt do
    supported = Sprat.Build.Profile.names() |> Enum.join(", ")

    "You are the SWE role, writing a technical_design artifact from the product_brief " <>
      "above (docs/spec-v2.md §4/§8). Pick exactly one stack profile from: #{supported} — " <>
      "never anything else, never a stack Sprat has no tested recipe for. If the brief " <>
      "genuinely needs something outside that list, do not improvise: set \"profile\" to " <>
      "a short label for the unsupported stack the brief actually needs (e.g. " <>
      "\"python-django\") and explain in \"excluded_scope\" why this mission cannot " <>
      "proceed on a supported profile — the gate will stop the mission here and name " <>
      "exactly what's unsupported. Otherwise: design a data model with real entities and " <>
      "relations, list the app's main components, any external services (or none), what " <>
      "is deliberately excluded from this MVP and why, and an estimated build cost " <>
      "labelled as an estimate. You MUST call write_artifact with type \"technical_design\" " <>
      "before your final answer."
  end
end
