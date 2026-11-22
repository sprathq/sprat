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
