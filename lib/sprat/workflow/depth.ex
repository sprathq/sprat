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
