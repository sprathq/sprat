defmodule Sprat.Workflow.Scorecard do
  @moduledoc """
  Pure opportunity scorecard arithmetic (docs/spec-v1.md §6): "Scores are
  computed by code from the ratings, not by the model." Missing evidence
  is `:unknown` — excluded from the weighted average and never treated as
  zero. `total: :unknown` (not a partial average) when every dimension is
  unknown, since an average of nothing is not a score. Weight-sensitivity
  is computed here too, with no model call.
  """

  @default_weights %{
    pain_severity: 20,
    willingness_to_pay: 20,
    buyer_reachability: 15,
    alternative_weakness: 15,
    feasibility: 10,
    unit_economics: 10,
    founder_advantage: 10
  }

  def default_weights, do: @default_weights

  @doc """
  `ratings`: `%{dimension => 1..5 | :unknown}` for every key in `weights`.
  Returns `%{total:, coverage:, by_dimension:}`. `total` is a `Decimal` in
  `[0, 5]` re-normalised over the known dimensions' weights, or `:unknown`
  if every dimension is unknown. `coverage` is the fraction (float) of
  weight backed by a known rating.
  """
  def score(ratings, weights \\ @default_weights) do
    known = Enum.reject(weights, fn {dim, _w} -> ratings[dim] == :unknown end)
    known_weight = known |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    total_weight = weights |> Map.values() |> Enum.sum()

    total =
      if known_weight == 0 do
        :unknown
      else
        known
        |> Enum.reduce(Decimal.new(0), fn {dim, w}, acc ->
          rating = Decimal.new(ratings[dim])
          share = Decimal.div(Decimal.new(w), Decimal.new(known_weight))
          Decimal.add(acc, Decimal.mult(rating, share))
        end)
      end

    %{
      total: total,
      coverage: known_weight / total_weight,
      by_dimension: Map.new(weights, fn {dim, _w} -> {dim, ratings[dim]} end)
    }
  end

  @doc """
  Whether the top-scored candidate (by `score/2`'s total) stays on top
  under every ±5-point single-weight perturbation (docs/spec-v1.md §6:
  "reports whether ±5-point weight changes alter the top pick"), keeping
  the perturbed dimension's delta spread evenly across the rest so
  weights still sum to 100. `candidates`: `[%{id:, ratings:}]`.
  """
  def sensitivity(candidates, weights \\ @default_weights) do
    baseline_top = top_pick(candidates, weights)

    deltas =
      for dim <- Map.keys(weights), delta <- [-5, 5] do
        perturbed = perturb(weights, dim, delta)
        pick = top_pick(candidates, perturbed)
        %{dimension: dim, delta: delta, top_pick: pick, changed?: pick != baseline_top}
      end

    %{
      top_pick: baseline_top,
      top_pick_stable?: Enum.all?(deltas, &(not &1.changed?)),
      deltas: deltas
    }
  end

  defp top_pick(candidates, weights) do
    candidates
    |> Enum.map(fn c -> {c.id, score(c.ratings, weights).total} end)
    |> Enum.reject(fn {_id, total} -> total == :unknown end)
    |> Enum.max_by(fn {_id, total} -> total end, Decimal, fn -> nil end)
    |> case do
      {id, _total} -> id
      nil -> nil
    end
  end

  defp perturb(weights, dim, delta) do
    others = Map.keys(weights) -- [dim]
    spread = div(-delta, length(others))
    remainder = -delta - spread * length(others)

    weights
    |> Map.update!(dim, &(&1 + delta))
    |> then(fn w ->
      sign = if remainder < 0, do: -1, else: 1

      others
      |> Enum.with_index()
      |> Enum.reduce(w, fn {o, i}, acc ->
        # Distribute remainder round-robin: first abs(remainder) dimensions get ±1
        bump = spread + if i < abs(remainder), do: sign, else: 0
        Map.update!(acc, o, &(&1 + bump))
      end)
    end)
  end
end
