defmodule Sprat.Store.Decisions do
  @moduledoc "CRUD for the decision log (docs/spec-v1.md §4 'Disagreements are recorded in the decision log with the evidence on both sides')."

  alias Sprat.Store.SQL

  defstruct [:id, :mission_id, :summary, :evidence_for, :evidence_against, :created_at]

  def record(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, mission_id, attrs) end)
  end

  def record_in_conn(conn, mission_id, attrs) do
    decision = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: mission_id,
      summary: Map.fetch!(attrs, :summary),
      evidence_for: attrs[:evidence_for],
      evidence_against: attrs[:evidence_against],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO decisions (id, mission_id, summary, evidence_for, evidence_against, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [
        decision.id,
        decision.mission_id,
        decision.summary,
        decision.evidence_for,
        decision.evidence_against,
        decision.created_at
      ]
    )

    decision
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM decisions WHERE mission_id = ?1 ORDER BY created_at ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_decision/1)
  end

  defp row_to_decision(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      summary: row["summary"],
      evidence_for: row["evidence_for"],
      evidence_against: row["evidence_against"],
      created_at: row["created_at"]
    }
  end

  defp generate_id,
    do: "dec_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
