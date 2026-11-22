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
