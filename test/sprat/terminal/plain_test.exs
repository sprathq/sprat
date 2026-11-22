defmodule Sprat.Terminal.PlainTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Plain

  test "commit passes committed lines through unchanged" do
    assert Plain.commit(["a", "b"]) == ["a", "b"]
  end

  test "activity_line has no spinner, just the verb" do
    assert Plain.activity_line(%{verb: "Researching"}) == ["Researching…"]
  end

  test "checklist_lines renders a status word per stage" do
    lines = Plain.checklist_lines(%{stages: [{"Intake", :done}, {"Research", :active}]})
    assert lines == ["[done] Intake", "[active] Research"]
  end

  test "prompt_lines is a numbered line prompt, not a redrawn box" do
    prompt = %{title: "Fetch URL", lines: ["proceed?"], options: ["Yes", "No"]}
    lines = Plain.prompt_lines(prompt)
    assert Enum.at(lines, 0) == "Fetch URL:"
    assert Enum.any?(lines, &(&1 == "  1) Yes"))
    assert List.last(lines) == "Enter a number:"
  end

  test "markdown_lines strips color and uses ascii glyphs" do
    [line | _] = Plain.markdown_lines("- one", 40)
    refute line =~ "\e["
    assert line =~ "*"
  end

  test "sanitize strips escape sequences" do
    assert Plain.sanitize("\e[31mred\e[0m") == "red"
  end
end
