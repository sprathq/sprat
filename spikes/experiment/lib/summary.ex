defmodule Experiment.Summary do
  @moduledoc "Builds summary.md from per-task results (§14 decision rule)."

  alias Experiment.Pure

  @doc """
  `task_results` is a list of maps:
  `%{id:, team: %{tokens_raw:, tokens_adjusted:, calls:, failures: []} | nil,
     solo: %{...} | nil, judge: %{verdict:, blind_map:} | nil}`.
  `baseline_per_call` is the measured trivial-call token cost.
  """
  def build(task_results, baseline_per_call) do
    judged = Enum.filter(task_results, & &1.judge)
    total_judged = length(judged)

    team_wins =
      Enum.count(judged, fn r ->
        winner_label = r.judge["verdict"]
        winner_label != "tie" and r.judge_blind_map[winner_label] == "team"
      end)

    team_raw =
      task_results |> Enum.map(& &1.team[:tokens_raw]) |> Enum.reject(&is_nil/1) |> Enum.sum()

    solo_raw =
      task_results |> Enum.map(& &1.solo[:tokens_raw]) |> Enum.reject(&is_nil/1) |> Enum.sum()

    team_adj =
      task_results
      |> Enum.map(& &1.team[:tokens_adjusted])
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    solo_adj =
      task_results
      |> Enum.map(& &1.solo[:tokens_adjusted])
      |> Enum.reject(&is_nil/1)
      |> Enum.sum()

    raw_ratio = safe_ratio(team_raw, solo_raw)
    adjusted_ratio = safe_ratio(team_adj, solo_adj)

    decision = Pure.decision(team_wins, total_judged, raw_ratio, adjusted_ratio)

    """
    # Phase 0 experiment summary

    Baseline per call: #{baseline_per_call} tokens.

    | Task | Workflow | Team calls | Team raw | Team adj. | Solo calls | Solo raw | Solo adj. | Verdict |
    |---|---|---:|---:|---:|---:|---:|---:|---|
    #{Enum.map_join(task_results, "\n", &row/1)}

    ## Token totals

    - Team: #{team_raw} raw, #{team_adj} baseline-adjusted
    - Solo: #{solo_raw} raw, #{solo_adj} baseline-adjusted
    - Ratio (team ÷ solo): #{format_ratio(raw_ratio)} raw, #{format_ratio(adjusted_ratio)} baseline-adjusted

    ## Evidence quality

    Team won #{team_wins}/#{total_judged} judged tasks on evidence quality.

    ## Decision

    **#{decision}** — #{Pure.decision_message(decision)}

    ## Failures

    #{failures_section(task_results)}
    """
  end

  defp row(r) do
    verdict =
      case r.judge do
        nil -> "not judged"
        %{"verdict" => v} -> "#{v} (#{r.judge_blind_map[v] || "tie"})"
      end

    "| #{r.id} | #{r.workflow} | #{r.team[:calls] || "-"} | #{r.team[:tokens_raw] || "-"} | " <>
      "#{r.team[:tokens_adjusted] || "-"} | #{r.solo[:calls] || "-"} | #{r.solo[:tokens_raw] || "-"} | " <>
      "#{r.solo[:tokens_adjusted] || "-"} | #{verdict} |"
  end

  defp failures_section(task_results) do
    lines =
      for r <- task_results,
          {config, data} <- [{"team", r.team}, {"solo", r.solo}],
          data,
          failure <- data[:failures] || [] do
        "- #{r.id}/#{config}: stage `#{failure}` failed twice and was skipped"
      end

    if lines == [], do: "None.", else: Enum.join(lines, "\n")
  end

  defp safe_ratio(_num, 0), do: nil
  defp safe_ratio(num, denom), do: num / denom

  defp format_ratio(nil), do: "n/a"
  defp format_ratio(r), do: :erlang.float_to_binary(r, decimals: 2) <> "x"
end
