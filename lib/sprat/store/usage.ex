defmodule Sprat.Store.Usage do
  @moduledoc """
  Usage records (docs/spec-v1.md §12): one row per model call, including
  failed/cancelled/retried calls. Cost is always a `Decimal`, stored as its
  string representation — never a float, per the spec's explicit rule.

  Aggregation sums leaf records only ("task and mission totals are sums of
  call records, never sums of sums") and returns `nil` for any field where
  every contributing record is `nil`/unknown, rather than treating unknown
  as zero.
  """

  alias Sprat.Store.SQL

  defstruct [
    :id,
    :task_id,
    :mission_id,
    :role_instance,
    :provider,
    :model,
    :request_id,
    :attempt,
    :raw_payload,
    :normalization_version,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :server_tool_counts,
    :cost_decimal,
    :pricing_version,
    :coverage,
    :started_at,
    :first_token_at,
    :ended_at
  ]

  @coverages ~w(reported estimated unavailable)

  @doc """
  Records a usage record. `attrs[:cost]`, if given, must be a `Decimal`
  (raises otherwise — money is never a float). `attrs[:coverage]` must be
  one of #{inspect(@coverages)}.
  """
  def record(store \\ Sprat.Store, attrs) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, attrs) end)
  end

  def record_in_conn(conn, attrs) do
    coverage = Map.fetch!(attrs, :coverage) |> to_string()
    coverage in @coverages || raise ArgumentError, "invalid coverage: #{inspect(coverage)}"

    cost = attrs[:cost]

    if cost != nil and not is_struct(cost, Decimal),
      do: raise(ArgumentError, "cost must be a Decimal, got: #{inspect(cost)}")

    record = %__MODULE__{
      id: attrs[:id] || generate_id(),
      task_id: Map.fetch!(attrs, :task_id),
      mission_id: Map.fetch!(attrs, :mission_id),
      role_instance: attrs[:role_instance],
      provider: Map.fetch!(attrs, :provider),
      model: Map.fetch!(attrs, :model),
      request_id: attrs[:request_id],
      attempt: attrs[:attempt],
      raw_payload: JSON.encode!(Map.fetch!(attrs, :raw_payload)),
      normalization_version: attrs[:normalization_version] || 1,
      input_tokens: attrs[:input_tokens],
      output_tokens: attrs[:output_tokens],
      cache_read_tokens: attrs[:cache_read_tokens],
      cache_write_tokens: attrs[:cache_write_tokens],
      server_tool_counts: attrs[:server_tool_counts] && JSON.encode!(attrs[:server_tool_counts]),
      cost_decimal: cost && Decimal.to_string(cost),
      pricing_version: attrs[:pricing_version],
      coverage: coverage,
      started_at: attrs[:started_at],
      first_token_at: attrs[:first_token_at],
      ended_at: attrs[:ended_at]
    }

    SQL.exec(
      conn,
      """
      INSERT INTO usage_records
        (id, task_id, mission_id, role_instance, provider, model, request_id, attempt,
         raw_payload, normalization_version, input_tokens, output_tokens, cache_read_tokens,
         cache_write_tokens, server_tool_counts, cost_decimal, pricing_version, coverage,
         started_at, first_token_at, ended_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)
      """,
      [
        record.id,
        record.task_id,
        record.mission_id,
        record.role_instance,
        record.provider,
        record.model,
        record.request_id,
        record.attempt,
        record.raw_payload,
        record.normalization_version,
        record.input_tokens,
        record.output_tokens,
        record.cache_read_tokens,
        record.cache_write_tokens,
        record.server_tool_counts,
        record.cost_decimal,
        record.pricing_version,
        record.coverage,
        record.started_at,
        record.first_token_at,
        record.ended_at
      ]
    )

    record
  end

  def by_task(store \\ Sprat.Store, task_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM usage_records WHERE task_id = ?1", [task_id])
    |> Enum.map(&row_to_record/1)
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM usage_records WHERE mission_id = ?1", [mission_id])
    |> Enum.map(&row_to_record/1)
  end

  @doc """
  Aggregate totals over a list of `%__MODULE__{}` leaf records: total cost
  (Decimal or nil if any contributing record has an unknown cost),
  input/output/cache token sums (nil if every record is nil for that
  field; known records still sum, unknown ones are just skipped — an
  "unknown" field never contributes a silent zero and never turns the
  whole total into zero either). Never re-sums an already-aggregated
  total — only ever called on leaf `usage_records` rows.
  """
  def totals(records) do
    %{
      calls: length(records),
      cost: sum_decimals(records, & &1.cost_decimal),
      input_tokens: sum_ints(records, & &1.input_tokens),
      output_tokens: sum_ints(records, & &1.output_tokens),
      cache_read_tokens: sum_ints(records, & &1.cache_read_tokens),
      cache_write_tokens: sum_ints(records, & &1.cache_write_tokens)
    }
  end

  defp sum_decimals(records, getter) do
    values = records |> Enum.map(getter) |> Enum.reject(&is_nil/1) |> Enum.map(&Decimal.new/1)

    case values do
      [] -> nil
      _ -> Enum.reduce(values, Decimal.new(0), &Decimal.add/2)
    end
  end

  defp sum_ints(records, getter) do
    values = records |> Enum.map(getter) |> Enum.reject(&is_nil/1)
    if values == [], do: nil, else: Enum.sum(values)
  end

  defp row_to_record(row) do
    %__MODULE__{
      id: row["id"],
      task_id: row["task_id"],
      mission_id: row["mission_id"],
      role_instance: row["role_instance"],
      provider: row["provider"],
      model: row["model"],
      request_id: row["request_id"],
      attempt: row["attempt"],
      raw_payload: row["raw_payload"] && JSON.decode!(row["raw_payload"]),
      normalization_version: row["normalization_version"],
      input_tokens: row["input_tokens"],
      output_tokens: row["output_tokens"],
      cache_read_tokens: row["cache_read_tokens"],
      cache_write_tokens: row["cache_write_tokens"],
      server_tool_counts: row["server_tool_counts"] && JSON.decode!(row["server_tool_counts"]),
      cost_decimal: row["cost_decimal"],
      pricing_version: row["pricing_version"],
      coverage: row["coverage"],
      started_at: row["started_at"],
      first_token_at: row["first_token_at"],
      ended_at: row["ended_at"]
    }
  end

  defp generate_id,
    do: "usg_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
