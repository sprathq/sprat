defmodule Sprat.Model.Pricing do
  @moduledoc """
  Loads the shipped model allowlist/pricing file (docs/spec-v1.md §7 owner
  decision #2: "a shipped data file with a version, easy to update without
  code changes") and computes cost as `Decimal` (§12: "Money uses
  `Decimal`. No floats.").

  `intersect/1` is the owner-specified model picker: it takes whatever
  `GET /v1/models` returns and splits it into `:tested` (on the allowlist)
  and `:untested` (everything else, still selectable, with a warning) —
  never silently drops an id the account actually has access to.
  """

  defstruct [:version, :provider, :effective_date, :source, :models, tool_fees: %{}]

  @type t :: %__MODULE__{}

  @doc "Path to the shipped pricing file."
  def default_path, do: Application.app_dir(:sprat, "priv/models/openai.json")

  @doc "Loads and parses the shipped pricing file (or `path`, mainly for tests)."
  def load(path \\ default_path()) do
    data = path |> File.read!() |> JSON.decode!()

    %__MODULE__{
      version: data["version"],
      provider: data["provider"],
      effective_date: data["effective_date"],
      source: data["source"],
      models: Enum.map(data["models"], &parse_model/1),
      tool_fees: parse_tool_fees(data["tools"])
    }
  end

  defp parse_tool_fees(nil), do: %{}

  defp parse_tool_fees(tools) do
    Map.new(tools, fn {name, %{"per_call" => fee}} -> {name, Decimal.new(fee)} end)
  end

  defp parse_model(m) do
    %{
      id: m["id"],
      supports_tools: m["supports_tools"],
      supports_streaming: m["supports_streaming"],
      context_window: m["context_window"],
      price: parse_price(m["price"])
    }
  end

  defp parse_price(nil), do: %{input: nil, cached_input: nil, output: nil}

  defp parse_price(p) do
    %{
      input: decimal_or_nil(p["input"]),
      cached_input: decimal_or_nil(p["cached_input"]),
      output: decimal_or_nil(p["output"])
    }
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(str), do: Decimal.new(str)

  @doc "The allowlist entry for `model_id`, or `nil` if it isn't on the shipped list."
  def find(%__MODULE__{models: models}, model_id), do: Enum.find(models, &(&1.id == model_id))

  @doc """
  Per-call fee for a hosted server-side tool (e.g. `"web_search"`), as a
  `Decimal`, or `nil` if the shipped file has no price for it (§7 owner
  decision #3: never guess — a `nil` fee must stop a cost calculation, not
  silently treat it as free).
  """
  def tool_fee(%__MODULE__{tool_fees: fees}, tool_name), do: Map.get(fees, tool_name)

  @doc """
  Splits `model_ids` (as returned by the provider's model list) into
  `%{tested: [...], untested: [...]}` against `catalog`. `tested` entries
  are the shipped allowlist rows (with pricing); `untested` are bare ids
  the account has access to but Sprat hasn't verified for streaming + tool
  use.
  """
  def intersect(%__MODULE__{models: models}, model_ids) do
    allowed_ids = MapSet.new(models, & &1.id)

    tested = Enum.filter(models, &MapSet.member?(MapSet.new(model_ids), &1.id))
    untested = model_ids |> Enum.reject(&MapSet.member?(allowed_ids, &1)) |> Enum.sort()

    %{tested: tested, untested: untested}
  end

  @doc """
  Cost of a call in whole-token terms, as `Decimal`, or `nil` if the
  model's price is unknown (§7 owner decision #3: never guess). Cached
  input tokens are billed at `cached_input` and *not* also counted as
  ordinary `input` (§12: "cache reads are not also counted as input") —
  callers pass `input_tokens` already net of `cached_tokens`.
  """
  def cost(%{price: %{input: i, cached_input: c, output: o}}, %{
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cached
      }) do
    with true <- known?(i, input), true <- known?(c, cached), true <- known?(o, output) do
      per_million = Decimal.new(1_000_000)

      [
        {i, input},
        {c, cached},
        {o, output}
      ]
      |> Enum.map(fn {price, tokens} -> rate_cost(price, tokens, per_million) end)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    else
      false -> nil
    end
  end

  defp rate_cost(_price, nil, _per_million), do: Decimal.new(0)
  defp rate_cost(_price, 0, _per_million), do: Decimal.new(0)

  defp rate_cost(price, tokens, per_million),
    do: Decimal.mult(price, tokens) |> Decimal.div(per_million)

  # A price is "known enough" to cost if either there's no price entry
  # needed (tokens nil/0) or the price itself is set.
  defp known?(_price, nil), do: true
  defp known?(_price, 0), do: true
  defp known?(nil, _tokens), do: false
  defp known?(_price, _tokens), do: true

  @doc "Worst-case cost for a call before it's made (§12 budget rule): `input_tokens` (counted locally) plus `max_tokens` output, at list price. `nil` if price is unknown."
  def worst_case(model_entry, input_tokens, max_tokens) do
    cost(model_entry, %{
      input_tokens: input_tokens,
      output_tokens: max_tokens,
      cache_read_tokens: 0
    })
  end
end
