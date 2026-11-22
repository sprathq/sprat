defmodule Experiment.Pure do
  @moduledoc """
  Pure, model-free logic for the Phase 0 team-vs-solo experiment: URL
  normalisation/dedup, citation checks, usage arithmetic, the §6 scorecard
  and the §14 decision rule. No I/O, no codex calls — kept separate so it
  can be exercised by `test_pure.exs` without spending any quota.
  """

  @tracking_params ~w(utm_source utm_medium utm_campaign utm_term utm_content
                       gclid fbclid mc_cid mc_eid ref ref_src igshid)

  @scorecard_weights %{
    severity: 0.20,
    willingness_to_pay: 0.20,
    reachability: 0.15,
    weak_alternatives: 0.15,
    feasibility: 0.10,
    unit_economics: 0.10,
    founder_advantage: 0.10
  }

  def scorecard_weights, do: @scorecard_weights

  @doc "Normalise a URL for de-duplication: lowercase host, strip fragment, trailing slash, tracking params."
  def normalize_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))
    host = uri.host && String.downcase(uri.host)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.drop(@tracking_params)
      |> then(fn m -> if map_size(m) == 0, do: nil, else: URI.encode_query(Enum.sort(m)) end)

    path = (uri.path || "") |> String.trim_trailing("/")
    path = if path == "", do: "/", else: path

    %{uri | host: host, fragment: nil, query: query, path: path}
    |> URI.to_string()
  end

  @doc """
  Merge source lists gathered across several stage outputs, de-duplicating
  by normalised URL. Each input source map keeps a `stage` and its
  stage-local `id` under `refs`. First-seen title/publisher/published wins;
  `supports` lists are concatenated.
  """
  def merge_and_dedup_sources(stage_source_lists) when is_list(stage_source_lists) do
    stage_source_lists
    |> Enum.reduce(%{}, fn {stage, sources}, acc ->
      Enum.reduce(sources, acc, fn source, acc ->
        key = normalize_url(source["url"] || source[:url] || "")

        ref = %{stage: stage, id: source["id"] || source[:id]}

        Map.update(
          acc,
          key,
          Map.merge(source, %{"refs" => [ref], "normalized_url" => key}),
          fn existing ->
            existing
            |> Map.update("refs", [ref], &[ref | &1])
            |> Map.update(
              "supports",
              source["supports"] || [],
              &(&1 ++ (source["supports"] || []))
            )
          end
        )
      end)
    end)
    |> Map.values()
  end

  @citation_regex ~r/\[S\d+\]/

  @doc "Citation tokens like [S1] found in markdown text that do not appear in `source_ids`."
  def dangling_citations(markdown, source_ids) when is_binary(markdown) do
    ids = MapSet.new(source_ids)

    @citation_regex
    |> Regex.scan(markdown)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, ["[", "]"], ""))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(ids, &1))
  end

  @doc "Sum a list of codex `turn.completed` usage maps into totals."
  def sum_usage(usage_maps) when is_list(usage_maps) do
    fields =
      ~w(input_tokens cached_input_tokens cache_write_input_tokens output_tokens reasoning_output_tokens)

    totals =
      Enum.reduce(usage_maps, Map.new(fields, &{&1, 0}), fn usage, acc ->
        Enum.reduce(fields, acc, fn f, acc ->
          Map.update!(acc, f, &(&1 + (usage[f] || usage[String.to_atom(f)] || 0)))
        end)
      end)

    Map.put(totals, "total_tokens", totals["input_tokens"] + totals["output_tokens"])
  end

  @doc "Raw total minus (baseline tokens per call × call count), floored at 0."
  def baseline_adjusted(raw_total, baseline_per_call, call_count) do
    max(raw_total - baseline_per_call * call_count, 0)
  end

  @doc """
  Weighted scorecard score for one hypothesis's ratings, e.g.
  `%{severity: 4, willingness_to_pay: :unknown, ...}`. Unknown dimensions
  are excluded from both numerator and denominator (not scored as 0 or
  averaged in) — the weighted mean over evidenced dimensions only.
  Returns `{score, evidence_coverage}`, both `nil` score if nothing is known.
  """
  def weighted_score(ratings, weights \\ @scorecard_weights) do
    {num, denom} =
      Enum.reduce(weights, {0.0, 0.0}, fn {dim, weight}, {num, denom} ->
        case Map.get(ratings, dim) do
          rating when is_integer(rating) -> {num + weight * rating, denom + weight}
          _ -> {num, denom}
        end
      end)

    total_weight = weights |> Map.values() |> Enum.sum()
    coverage = denom / total_weight
    score = if denom > 0, do: num / denom, else: nil
    {score, coverage}
  end

  @doc """
  ±5 percentage-point sensitivity check: for each dimension, nudge its
  weight by +0.05/-0.05 (renormalising the rest proportionally) and see
  whether the top-scoring hypothesis among `ratings_by_hypothesis`
  (a map of hypothesis name/id => ratings map) changes. Returns
  `%{baseline_top: id, sensitive: boolean, flips: [dimension, ...]}`.
  """
  def sensitivity_check(ratings_by_hypothesis, weights \\ @scorecard_weights) do
    top_for = fn weights ->
      ratings_by_hypothesis
      |> Enum.map(fn {id, ratings} -> {id, weighted_score(ratings, weights) |> elem(0)} end)
      |> Enum.reject(fn {_, score} -> is_nil(score) end)
      |> Enum.max_by(fn {_, score} -> score end, fn -> {nil, nil} end)
      |> elem(0)
    end

    baseline_top = top_for.(weights)

    flips =
      for dim <- Map.keys(weights), delta <- [0.05, -0.05], reduce: [] do
        acc ->
          nudged = nudge_weight(weights, dim, delta)
          if top_for.(nudged) != baseline_top, do: [{dim, delta} | acc], else: acc
      end

    %{baseline_top: baseline_top, sensitive: flips != [], flips: Enum.uniq(flips)}
  end

  defp nudge_weight(weights, dim, delta) do
    new_dim_weight = max(Map.fetch!(weights, dim) + delta, 0.0)
    others = Map.delete(weights, dim)
    others_sum = others |> Map.values() |> Enum.sum()
    remaining = 1.0 - new_dim_weight

    others =
      if others_sum > 0 do
        Map.new(others, fn {k, w} -> {k, w / others_sum * remaining} end)
      else
        others
      end

    Map.put(others, dim, new_dim_weight)
  end

  @doc """
  §14 decision rule. `total` is how many tasks ran (normally 10);
  thresholds scale with it (7/10 pass, 5/10 ambiguous floor).
  """
  def decision(wins, total, raw_ratio, adjusted_ratio) do
    pass_threshold = total * 7 / 10
    ambiguous_low = total * 5 / 10

    cond do
      wins >= pass_threshold and adjusted_ratio <= 2.0 -> :pass
      wins >= ambiguous_low and wins < pass_threshold -> :ambiguous
      wins >= pass_threshold and adjusted_ratio > 2.0 and raw_ratio <= 2.0 -> :ambiguous
      true -> :fail
    end
  end

  def decision_message(:pass), do: "build roles as specified"
  def decision_message(:fail), do: "V1 ships solo mode; the roles section is removed"
  def decision_message(:ambiguous), do: "owner decides, per-rubric breakdown attached"
end
