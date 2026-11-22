defmodule Sprat.Store.Sessions do
  @moduledoc "Minimal CRUD for the `sessions` table — enough to satisfy `missions`' foreign key and back the Projection."

  alias Sprat.Store.SQL

  defstruct [:id, :started_at, :ended_at, :project_path, :mode]

  def create(store \\ Sprat.Store, attrs \\ %{}) do
    Sprat.Store.transact(store, fn conn -> create_in_conn(conn, attrs) end)
  end

  def create_in_conn(conn, attrs \\ %{}) do
    session = %__MODULE__{
      id: attrs[:id] || generate_id(),
      started_at: attrs[:started_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
      ended_at: nil,
      project_path: attrs[:project_path],
      mode: attrs[:mode] || "team"
    }

    SQL.exec(
      conn,
      "INSERT INTO sessions (id, started_at, ended_at, project_path, mode) VALUES (?1, ?2, ?3, ?4, ?5)",
      [session.id, session.started_at, session.ended_at, session.project_path, session.mode]
    )

    session
  end

  def get(store \\ Sprat.Store, id) do
    case Sprat.Store.fetch_one(store, "SELECT * FROM sessions WHERE id = ?1", [id]) do
      nil -> nil
      row -> row_to_session(row)
    end
  end

  @doc "All sessions, most recently started first."
  def all(store \\ Sprat.Store) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM sessions ORDER BY started_at DESC")
    |> Enum.map(&row_to_session/1)
  end

  @doc "Sessions for one project path, most recently started first — backs `--continue`/`--resume`."
  def by_project(store \\ Sprat.Store, project_path) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM sessions WHERE project_path = ?1 ORDER BY started_at DESC",
      [project_path]
    )
    |> Enum.map(&row_to_session/1)
  end

  @doc """
  Permanently deletes a session and everything scoped to it: its missions
  (and their tasks, artifacts, sources, claims, decisions, usage records),
  its messages, events and grants (docs/spec-v1.md §11: "`sprat sessions
  delete <id>` removes a session's rows"). Blob garbage collection is out
  of scope here — see `Sprat.Store.Blob` moduledoc; V1 payloads are small
  enough that nothing has been written to the blob store yet in practice.
  Returns `:ok` even if the session doesn't exist (idempotent).
  """
  def delete(store \\ Sprat.Store, id) do
    Sprat.Store.transact(store, fn conn -> delete_in_conn(conn, id) end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_in_conn(conn, id) do
    mission_ids =
      SQL.fetch_all(conn, "SELECT id FROM missions WHERE session_id = ?1", [id])
      |> Enum.map(& &1["id"])

    Enum.each(mission_ids, fn mission_id ->
      SQL.exec(conn, "DELETE FROM usage_records WHERE mission_id = ?1", [mission_id])

      SQL.exec(
        conn,
        "DELETE FROM claim_sources WHERE claim_id IN (SELECT id FROM claims WHERE mission_id = ?1)",
        [mission_id]
      )

      SQL.exec(conn, "DELETE FROM claims WHERE mission_id = ?1", [mission_id])
      SQL.exec(conn, "DELETE FROM sources WHERE mission_id = ?1", [mission_id])
      SQL.exec(conn, "DELETE FROM decisions WHERE mission_id = ?1", [mission_id])

      SQL.exec(
        conn,
        "DELETE FROM artifact_versions WHERE artifact_id IN (SELECT id FROM artifacts WHERE mission_id = ?1)",
        [mission_id]
      )

      SQL.exec(conn, "DELETE FROM artifacts WHERE mission_id = ?1", [mission_id])
      SQL.exec(conn, "DELETE FROM tasks WHERE mission_id = ?1", [mission_id])
      SQL.exec(conn, "DELETE FROM missions WHERE id = ?1", [mission_id])
    end)

    SQL.exec(conn, "DELETE FROM messages WHERE session_id = ?1", [id])
    SQL.exec(conn, "DELETE FROM events WHERE session_id = ?1", [id])
    SQL.exec(conn, "DELETE FROM grants WHERE session_id = ?1", [id])
    SQL.exec(conn, "DELETE FROM sessions WHERE id = ?1", [id])
    :ok
  end

  defp row_to_session(row) do
    %__MODULE__{
      id: row["id"],
      started_at: row["started_at"],
      ended_at: row["ended_at"],
      project_path: row["project_path"],
      mode: row["mode"]
    }
  end

  defp generate_id,
    do: "ses_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
