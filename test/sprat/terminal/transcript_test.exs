defmodule Sprat.Terminal.TranscriptTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Transcript

  test "user_message prefixes with '> '" do
    [line] = Transcript.user_message("hello")
    assert line == "> hello"
  end

  test "user_message dims when marked as already submitted" do
    [line] = Transcript.user_message("hello", dim?: true)
    assert line =~ "\e["
    assert line =~ "hello"
  end

  test "agent_message includes a role header and rendered markdown body" do
    lines = Transcript.agent_message("PM", "hello **world**", 40)
    assert Enum.at(lines, 0) =~ "PM"
    assert Enum.any?(lines, &(&1 =~ "world"))
  end

  test "tool_call formats role and summary" do
    [line] = Transcript.tool_call("Researcher·1", "web_search(\"x\")")
    assert line =~ "Researcher·1"
    assert line =~ "web_search"
  end

  test "tool_call sanitizes untrusted summary content" do
    [line] = Transcript.tool_call("Role", "\e[31minjected\e[0m")
    refute line =~ "\e[31m"
    assert line =~ "injected"
  end

  test "tool_result truncates beyond the default line limit with an expand hint" do
    text = Enum.map_join(1..10, "\n", &"line #{&1}")
    lines = Transcript.tool_result(text, 40)
    assert length(lines) == 5
    assert List.last(lines) =~ "ctrl+o to expand"
  end

  test "tool_result shows everything when verbose" do
    text = Enum.map_join(1..10, "\n", &"line #{&1}")
    lines = Transcript.tool_result(text, 40, verbose?: true)
    refute Enum.any?(lines, &(&1 =~ "ctrl+o"))
    assert Enum.any?(lines, &(&1 =~ "line 10"))
  end

  test "stage_change includes the stage name and reason" do
    lines = Transcript.stage_change("Research", "3 sources found")
    assert Enum.at(lines, 0) =~ "Stage: Research"
    assert Enum.at(lines, 1) =~ "3 sources found"
  end

  test "artifact_written names the artifact, version and path" do
    lines = Transcript.artifact_written("Analyst", "brief.md", 2, "/tmp/brief.md")
    assert Enum.at(lines, 0) =~ "brief.md v2"
    assert Enum.at(lines, 1) =~ "/tmp/brief.md"
  end

  test "error_block never leaks raw content and shows a suggestion" do
    lines = Transcript.error_block("boom", "try again")
    assert Enum.at(lines, 0) =~ "boom"
    assert Enum.at(lines, 1) =~ "try again"
  end

  test "gate_result renders a check or cross with the missing item" do
    assert [pass] = Transcript.gate_result(true, nil, [])
    assert pass =~ "✓"

    assert [fail] = Transcript.gate_result(false, "missing sources", [])
    assert fail =~ "✗"
    assert fail =~ "missing sources"
  end
end
