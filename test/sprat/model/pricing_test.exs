defmodule Sprat.Model.PricingTest do
  use ExUnit.Case, async: true

  alias Sprat.Model.Pricing

  test "loads the shipped allowlist file" do
    catalog = Pricing.load()
    assert catalog.version == 1
    assert catalog.provider == "openai"
    assert is_binary(catalog.effective_date)
    assert length(catalog.models) > 0
    assert Enum.all?(catalog.models, &is_binary(&1.id))
  end

  test "find/2 returns the entry for a known model, nil for an unknown one" do
    catalog = Pricing.load()
    assert %{id: "gpt-5-nano"} = Pricing.find(catalog, "gpt-5-nano")
    assert Pricing.find(catalog, "no-such-model") == nil
  end

  test "tool_fee/2 returns the shipped per-call fee for a hosted tool, nil for an unknown one" do
    catalog = Pricing.load()
    assert Decimal.equal?(Pricing.tool_fee(catalog, "web_search"), Decimal.new("0.01"))
    assert Pricing.tool_fee(catalog, "no-such-tool") == nil
  end

  test "intersect/2 splits into tested/untested without dropping account access" do
    catalog = Pricing.load()
    ids = ["gpt-4.1-mini", "some-brand-new-unlisted-model"]
    result = Pricing.intersect(catalog, ids)
    assert Enum.any?(result.tested, &(&1.id == "gpt-4.1-mini"))
    assert "some-brand-new-unlisted-model" in result.untested
  end

  test "cost/2 computes cost as a Decimal, cache reads not double-counted as input" do
    entry = %{
      price: %{
        input: Decimal.new("2.00"),
        cached_input: Decimal.new("0.50"),
        output: Decimal.new("8.00")
      }
    }

    cost =
      Pricing.cost(entry, %{
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        cache_read_tokens: 500_000
      })

    # 1M non-cached input at $2 + 500k cached at $0.50 + 1M output at $8
    expected =
      Decimal.new("2.00") |> Decimal.add(Decimal.new("0.25")) |> Decimal.add(Decimal.new("8.00"))

    assert Decimal.equal?(cost, expected)
  end

  test "cost/2 is nil (price unknown) when a rate is missing but tokens were used in that category" do
    entry = %{
      price: %{input: Decimal.new("1.00"), cached_input: nil, output: Decimal.new("1.00")}
    }

    assert Pricing.cost(entry, %{input_tokens: 10, output_tokens: 10, cache_read_tokens: 5}) ==
             nil
  end

  test "cost/2 tolerates a nil price category when zero tokens were used there" do
    entry = %{
      price: %{input: Decimal.new("1.00"), cached_input: nil, output: Decimal.new("1.00")}
    }

    cost = Pricing.cost(entry, %{input_tokens: 10, output_tokens: 10, cache_read_tokens: 0})
    assert Decimal.equal?(cost, Decimal.new("0.00002"))
  end

  test "worst_case/3 uses max_tokens as the output side" do
    entry = %{
      price: %{input: Decimal.new("1.00"), cached_input: nil, output: Decimal.new("2.00")}
    }

    wc = Pricing.worst_case(entry, 1000, 500)

    expected =
      Decimal.new("1.00")
      |> Decimal.mult(1000)
      |> Decimal.div(1_000_000)
      |> Decimal.add(Decimal.new("2.00") |> Decimal.mult(500) |> Decimal.div(1_000_000))

    assert Decimal.equal?(wc, expected)
  end
end
