Code.require_file(Path.join(__DIR__, "lib/pure.ex"))
alias Experiment.Pure

defmodule Check do
  def ok!(true), do: :ok
  def ok!(false), do: raise("assertion failed")
end

# --- normalize_url / dedup ---------------------------------------------
Check.ok!(
  Pure.normalize_url("https://Example.com/foo/") == Pure.normalize_url("https://example.com/foo")
)

Check.ok!(
  Pure.normalize_url("https://example.com/foo?utm_source=x&b=1") ==
    Pure.normalize_url("https://example.com/foo?b=1")
)

Check.ok!(
  Pure.normalize_url("https://example.com/foo#section") ==
    Pure.normalize_url("https://example.com/foo")
)

Check.ok!(Pure.normalize_url("https://example.com/") == Pure.normalize_url("https://example.com"))

merged =
  Pure.merge_and_dedup_sources([
    {"stage_a",
     [%{"id" => "S1", "url" => "https://example.com/x/", "title" => "T", "supports" => ["a"]}]},
    {"stage_b",
     [%{"id" => "S1", "url" => "https://example.com/x", "title" => "T2", "supports" => ["b"]}]},
    {"stage_b",
     [%{"id" => "S2", "url" => "https://other.com/y", "title" => "U", "supports" => []}]}
  ])

Check.ok!(length(merged) == 2)
dup = Enum.find(merged, &(&1["normalized_url"] == Pure.normalize_url("https://example.com/x")))
Check.ok!(length(dup["refs"]) == 2)
Check.ok!(dup["supports"] == ["a", "b"])

# --- dangling citations --------------------------------------------------
md = "Gyms use spreadsheets [S1]. Pricing is unclear [S3]. Also [assumption]."
Check.ok!(Pure.dangling_citations(md, ["S1", "S2"]) == ["S3"])
Check.ok!(Pure.dangling_citations(md, ["S1", "S3"]) == [])

# --- usage summation ------------------------------------------------------
usages = [
  %{
    "input_tokens" => 100,
    "output_tokens" => 20,
    "cached_input_tokens" => 50,
    "cache_write_input_tokens" => 0,
    "reasoning_output_tokens" => 5
  },
  %{
    "input_tokens" => 200,
    "output_tokens" => 40,
    "cached_input_tokens" => 0,
    "cache_write_input_tokens" => 10,
    "reasoning_output_tokens" => 0
  }
]

totals = Pure.sum_usage(usages)
Check.ok!(totals["input_tokens"] == 300)
Check.ok!(totals["output_tokens"] == 60)
Check.ok!(totals["total_tokens"] == 360)

Check.ok!(Pure.baseline_adjusted(360, 50, 2) == 260)
Check.ok!(Pure.baseline_adjusted(10, 50, 2) == 0)

# --- scorecard weighted arithmetic ---------------------------------------
{score, coverage} =
  Pure.weighted_score(%{
    severity: 5,
    willingness_to_pay: 3,
    reachability: 4,
    weak_alternatives: :unknown,
    feasibility: 5,
    unit_economics: 3,
    founder_advantage: 4
  })

# weights excl. weak_alternatives (0.15) sum to 0.85; numerator by hand:
expected_num = 0.20 * 5 + 0.20 * 3 + 0.15 * 4 + 0.10 * 5 + 0.10 * 3 + 0.10 * 4
expected = expected_num / 0.85
in_delta? = fn a, b -> abs(a - b) < 0.0001 end
Check.ok!(in_delta?.(score, expected))
Check.ok!(in_delta?.(coverage, 0.85))

{nil_score, zero_cov} = Pure.weighted_score(%{severity: :unknown})
Check.ok!(nil_score == nil)
Check.ok!(zero_cov == 0.0)

sensitivity =
  Pure.sensitivity_check(%{
    "hyp_a" => %{
      severity: 5,
      willingness_to_pay: 5,
      reachability: 3,
      weak_alternatives: 3,
      feasibility: 3,
      unit_economics: 3,
      founder_advantage: 3
    },
    "hyp_b" => %{
      severity: 3,
      willingness_to_pay: 3,
      reachability: 5,
      weak_alternatives: 5,
      feasibility: 5,
      unit_economics: 5,
      founder_advantage: 5
    }
  })

Check.ok!(sensitivity.baseline_top in ["hyp_a", "hyp_b"])
Check.ok!(is_boolean(sensitivity.sensitive))

# clear-cut winner should never flip
stable =
  Pure.sensitivity_check(%{
    "hyp_a" => %{
      severity: 5,
      willingness_to_pay: 5,
      reachability: 5,
      weak_alternatives: 5,
      feasibility: 5,
      unit_economics: 5,
      founder_advantage: 5
    },
    "hyp_b" => %{
      severity: 1,
      willingness_to_pay: 1,
      reachability: 1,
      weak_alternatives: 1,
      feasibility: 1,
      unit_economics: 1,
      founder_advantage: 1
    }
  })

Check.ok!(stable.sensitive == false)

# --- decision rule ---------------------------------------------------------
Check.ok!(Pure.decision(7, 10, 1.5, 1.8) == :pass)
Check.ok!(Pure.decision(10, 10, 1.2, 1.2) == :pass)
Check.ok!(Pure.decision(7, 10, 1.5, 2.5) == :ambiguous)
Check.ok!(Pure.decision(6, 10, 1.0, 1.0) == :ambiguous)
Check.ok!(Pure.decision(5, 10, 1.0, 1.0) == :ambiguous)
Check.ok!(Pure.decision(4, 10, 1.0, 1.0) == :fail)
Check.ok!(Pure.decision(8, 10, 2.5, 3.0) == :fail)
Check.ok!(Pure.decision(7, 10, 2.5, 2.5) == :fail)

IO.puts("All #{__ENV__.file} checks passed.")
