defmodule Sprat.Store.Claims do
  @moduledoc "CRUD for claim records and their claim↔source links (docs/spec-v1.md §6)."

  alias Sprat.Store.SQL

  defstruct [
    :id,
    :mission_id,
    :artifact_id,
    :section,
    :text,
    :confidence,
    :justification,
    :scope,
    :is_assumption,
    :created_at
  ]

  @confidences ~w(high medium low)

  def record(store \\ Sprat.Store, mission_id, attrs, source_ids \\ []) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, mission_id, attrs, source_ids) end)
  end

  def record_in_conn(conn, mission_id, attrs, source_ids \\ []) do
    confidence = Map.fetch!(attrs, :confidence) |> to_string()

    confidence in @confidences ||
      raise ArgumentError, "invalid confidence: #{inspect(confidence)}"

    claim = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: mission_id,
      artifact_id: attrs[:artifact_id],
      section: attrs[:section],
      text: Map.fetch!(attrs, :text),
      confidence: confidence,
      justification: attrs[:justification],
      scope: attrs[:scope],
      is_assumption: !!attrs[:is_assumption],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO claims (id, mission_id, artifact_id, section, text, confidence, justification, scope, is_assumption, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        claim.id,
        claim.mission_id,
        claim.artifact_id,
        claim.section,
        claim.text,
        claim.confidence,
        claim.justification,
        claim.scope,
        bool_to_int(claim.is_assumption),
        claim.created_at
      ]
    )

    Enum.each(source_ids, fn {source_id, stance} ->
      SQL.exec(
        conn,
        "INSERT INTO claim_sources (claim_id, source_id, stance) VALUES (?1, ?2, ?3)",
        [claim.id, source_id, to_string(stance)]
      )
    end)

    claim
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM claims WHERE mission_id = ?1 ORDER BY created_at ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_claim/1)
  end

  @doc """
  Claims for a mission with their supporting source ids attached, as
  `{claim, source_ids}`. A gate needs both halves: a claim recorded by
  `record/4` keeps its sources in `claim_sources`, not on the row.
  """
  def by_mission_with_sources(store \\ Sprat.Store, mission_id) do
    links =
      store
      |> Sprat.Store.fetch_all(
        """
        SELECT cs.claim_id AS claim_id, cs.source_id AS source_id
        FROM claim_sources cs
        JOIN claims c ON c.id = cs.claim_id
        WHERE c.mission_id = ?1
        """,
        [mission_id]
      )
      |> Enum.group_by(& &1["claim_id"], & &1["source_id"])

    store
    |> by_mission(mission_id)
    |> Enum.map(&{&1, Map.get(links, &1.id, [])})
  end

  defp row_to_claim(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      artifact_id: row["artifact_id"],
      section: row["section"],
      text: row["text"],
      confidence: row["confidence"],
      justification: row["justification"],
      scope: row["scope"],
      is_assumption: row["is_assumption"] == 1,
      created_at: row["created_at"]
    }
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp generate_id,
    do: "clm_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
