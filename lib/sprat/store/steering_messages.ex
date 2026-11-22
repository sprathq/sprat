defmodule Sprat.Store.SteeringMessages do
  @moduledoc """
  Mid-mission steering messages (docs/spec-v1.md §10): a plain message
  typed while its mission's agent loop is running. `Sprat.Steering` is the
  domain module that decides when to enqueue/deliver these; this module
  is the plain CRUD underneath it, mirroring `Sprat.Store.Grants`'s shape
  (a small table, insert + status flip, no update-in-place of the text
  itself — a steering message's `text` is immutable once persisted, only
  `status`/`delivered_at` change).

  `status` is `"queued"` until a turn boundary delivers it
  (`Sprat.Steering.take_pending/3`), then `"delivered"` — permanently:
  nothing here ever un-delivers a message. `by_mission/2` returns every
  message regardless of status, oldest first, which is what lets a later
  stage's context package carry the mission's whole steering history
  forward (§10 "reaches agents at supported safe boundaries" — every
  stage boundary is one).
  """

  alias Sprat.Store.SQL

  defstruct [:id, :session_id, :mission_id, :text, :status, :created_at, :delivered_at]

  @doc "Persists a new queued steering message. Use inside a caller's own `Store.transact/2` block (see `Sprat.Steering.queue/4`, which also marks the mission's artifacts stale in the same transaction)."
  def enqueue_in_conn(conn, session_id, mission_id, text) do
    message = %__MODULE__{
      id: generate_id(),
      session_id: session_id,
      mission_id: mission_id,
      text: text,
      status: "queued",
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO steering_messages (id, session_id, mission_id, text, status, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [message.id, session_id, mission_id, text, "queued", message.created_at]
    )

    message
  end

  @doc "Flips one message to delivered. Use inside a caller's own `Store.transact/2` block."
  def mark_delivered_in_conn(conn, id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    SQL.exec(
      conn,
      "UPDATE steering_messages SET status = 'delivered', delivered_at = ?1 WHERE id = ?2",
      [now, id]
    )

    :ok
  end

  @doc "Queued (not yet delivered) messages for `mission_id`, oldest first — delivery order."
  def pending(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM steering_messages WHERE mission_id = ?1 AND status = 'queued' ORDER BY created_at ASC, id ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_message/1)
  end

  @doc "Every steering message for `mission_id` (queued and delivered), oldest first."
  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM steering_messages WHERE mission_id = ?1 ORDER BY created_at ASC, id ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_message/1)
  end

  defp row_to_message(row) do
    %__MODULE__{
      id: row["id"],
      session_id: row["session_id"],
      mission_id: row["mission_id"],
      text: row["text"],
      status: row["status"],
      created_at: row["created_at"],
      delivered_at: row["delivered_at"]
    }
  end

  defp generate_id,
    do: "stm_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
