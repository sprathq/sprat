defmodule Sprat.Workflow.OpportunityTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.{Opportunity, Template}

  test "template/1 has the seven §5.B stages in order, single role" do
    template = Opportunity.template(:standard)

    assert Enum.map(template.stages, & &1.id) == [
             :intake,
             :landscape,
             :hypotheses,
             :scoring,
             :counter_evidence,
             :recommendation,
             :delivery
           ]

    assert Enum.all?(template.stages, &(&1.role == "researcher"))
  end

  test "each stage's deliverables and gate match §5" do
    template = Opportunity.template(:standard)

    assert Template.find_stage(template, :intake).deliverables == [:intake_summary]
    assert Template.find_stage(template, :intake).gate == :intake_to_research

    assert Template.find_stage(template, :landscape).deliverables == [
             :research_memo,
             :competitor_matrix,
             :source_register
           ]

    assert Template.find_stage(template, :landscape).gate == :research_to_analysis

    assert Template.find_stage(template, :hypotheses).deliverables == [:assumption_register]
    assert Template.find_stage(template, :hypotheses).gate == :analysis_gate

    assert Template.find_stage(template, :scoring).deliverables == [:opportunity_scorecard]
    assert Template.find_stage(template, :scoring).gate == nil

    assert Template.find_stage(template, :counter_evidence).deliverables == [
             :research_memo,
             :source_register
           ]

    assert Template.find_stage(template, :counter_evidence).gate == :research_to_analysis

    assert Template.find_stage(template, :recommendation).deliverables == [
             :recommendation_memo
           ]

    assert Template.find_stage(template, :recommendation).gate == :recommendation_to_delivery

    assert Template.find_stage(template, :delivery).deliverables == [:validation_plan]
    # Discovery delivers a validation plan, not a product brief (§5B), so it
    # cannot share idea shaping's delivery gate.
    assert Template.find_stage(template, :delivery).gate == :validation_plan_gate
  end

  test "limits scale with depth" do
    quick = Opportunity.template(:quick)
    deep = Opportunity.template(:deep)
    assert Template.find_stage(quick, :landscape).limits.wall_seconds == 300
    assert Template.find_stage(deep, :landscape).limits.wall_seconds == 3600
  end
end
