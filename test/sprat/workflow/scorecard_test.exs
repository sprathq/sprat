defmodule Sprat.Workflow.ScorecardTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Workflow.Scorecard

  test "default_weights/0 sums to 100" do
    total = Scorecard.default_weights() |> Map.values() |> Enum.sum()
    assert total == 100
  end

  test "score/2 computes a weighted total from code, not the model" do
    ratings = %{
      pain_severity: 5,
      willingness_to_pay: 4,
      buyer_reachability: 3,
      alternative_weakness: 3,
      feasibility: 4,
      unit_economics: 3,
      founder_advantage: 5
    }

    result = Scorecard.score(ratings)

    expected =
      Decimal.new(5)
      |> Decimal.mult(Decimal.new("0.20"))
      |> Decimal.add(Decimal.new(4) |> Decimal.mult(Decimal.new("0.20")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.15")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.15")))
      |> Decimal.add(Decimal.new(4) |> Decimal.mult(Decimal.new("0.10")))
      |> Decimal.add(Decimal.new(3) |> Decimal.mult(Decimal.new("0.10")))
      |> Decimal.add(Decimal.new(5) |> Decimal.mult(Decimal.new("0.10")))

    assert Decimal.equal?(result.total, expected)
    assert result.coverage == 1.0
  end

  test "unknown dimensions stay unknown, are excluded from the average, not scored as zero" do
    ratings = %{
      pain_severity: :unknown,
      willingness_to_pay: 4,
      buyer_reachability: 3,
      alternative_weakness: 3,
      feasibility: 4,
      unit_economics: 3,
      founder_advantage: 5
    }

    result = Scorecard.score(ratings)
    refute Decimal.equal?(result.total, Decimal.new(0))
    assert result.coverage < 1.0
    assert result.by_dimension.pain_severity == :unknown
  end

  test "all-unknown ratings produce total: :unknown, never zero and never an average" do
    ratings = Scorecard.default_weights() |> Map.keys() |> Map.new(&{&1, :unknown})
    assert %{total: :unknown, coverage: +0.0} = Scorecard.score(ratings)
  end

  test "sensitivity/2 reports whether ±5-point weight changes flip the top pick" do
    stable = [
      %{
        id: :a,
        ratings: %{
          pain_severity: 5,
          willingness_to_pay: 5,
          buyer_reachability: 5,
          alternative_weakness: 5,
          feasibility: 5,
          unit_economics: 5,
          founder_advantage: 5
        }
      },
      %{
        id: :b,
        ratings: %{
          pain_severity: 1,
          willingness_to_pay: 1,
          buyer_reachability: 1,
          alternative_weakness: 1,
          feasibility: 1,
          unit_economics: 1,
          founder_advantage: 1
        }
      }
    ]

    assert %{top_pick_stable?: true} = Scorecard.sensitivity(stable, Scorecard.default_weights())
  end

  property "score/2 total is always within [0, 5] when no dimension is unknown" do
    check all(ratings <- rating_map()) do
      %{total: total} = Scorecard.score(ratings)
      assert Decimal.compare(total, Decimal.new(0)) in [:gt, :eq]
      assert Decimal.compare(total, Decimal.new(5)) in [:lt, :eq]
    end
  end

  defp rating_map do
    dims = Scorecard.default_weights() |> Map.keys()
    dims |> Enum.map(&{&1, integer(1..5)}) |> Map.new() |> build_fixed_map()
  end

  defp build_fixed_map(kv_gens) do
    kv_gens
    |> Enum.reduce(constant(%{}), fn {k, gen}, acc ->
      bind(acc, fn m -> bind(gen, fn v -> constant(Map.put(m, k, v)) end) end)
    end)
  end
end
