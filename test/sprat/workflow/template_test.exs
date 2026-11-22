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
    stage = fn id ->
      Template.stage(
        id: id,
        title: "x",
        role: "researcher",
        prompt: "p",
        required_inputs: [],
        deliverables: [],
        gate: nil,
        limits: %{}
      )
    end

    assert %Template{id: :t, stages: [_, _]} =
             Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:b)])

    assert_raise ArgumentError, fn ->
      Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:a)])
    end

    assert_raise ArgumentError, fn -> Template.new(id: :t, title: "T", stages: []) end
  end

  test "stage_after/2 and first_stage/1 walk the template in order" do
    stage = fn id ->
      Template.stage(
        id: id,
        title: "x",
        role: "researcher",
        prompt: "p",
        required_inputs: [],
        deliverables: [],
        gate: nil,
        limits: %{}
      )
    end

    template = Template.new(id: :t, title: "T", stages: [stage.(:a), stage.(:b), stage.(:c)])

    assert Template.first_stage(template).id == :a
    assert Template.stage_after(template, :a).id == :b
    assert Template.stage_after(template, :c) == nil
  end
end
