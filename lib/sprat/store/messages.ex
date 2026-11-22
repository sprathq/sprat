defmodule Sprat.Store.Messages do
  @moduledoc """
  Append/query for the `messages` table — one row per displayed transcript
  block (docs/spec-v1.md §13 storage layout, §10 transcript blocks).
  `append_in_conn/3` exists so a caller (`Sprat.Session`) can write a
  block's message row and its event in the same `Store.transact/2` call,
  matching the rule that a state change and its event are never split
  across transactions.
  """

  alias Sprat.Store.SQL

  defstruct [:id, :session_id, :task_id, :role, :agent_id, :content, :occurred_at]

  @doc "attrs: :role (required), :content (required), :task_id, :agent_id, :occurred_at."
  def append(store \\ Sprat.Store, session_id, attrs) do
    Sprat.Store.transact(store, fn conn -> append_in_conn(conn, session_id, attrs) end)
  end

  def append_in_conn(conn, session_id, attrs) do
    message = %__MODULE__{
      session_id: session_id,
      task_id: attrs[:task_id],
      role: to_string(Map.fetch!(attrs, :role)),
      agent_id: attrs[:agent_id],
      content: Map.fetch!(attrs, :content),
      occurred_at: attrs[:occurred_at] || DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO messages (session_id, task_id, role, agent_id, content, occurred_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [
        message.session_id,
        message.task_id,
        message.role,
        message.agent_id,
        message.content,
        message.occurred_at
      ]
    )

    message
  end

  @doc "All messages for a session, oldest first, stable under same-timestamp writes (tiebroken by row id)."
  def by_session(store \\ Sprat.Store, session_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM messages WHERE session_id = ?1 ORDER BY occurred_at ASC, id ASC",
      [session_id]
    )
    |> Enum.map(&row_to_message/1)
  end

  defp row_to_message(row) do
    %__MODULE__{
      id: row["id"],
      session_id: row["session_id"],
      task_id: row["task_id"],
      role: row["role"],
      agent_id: row["agent_id"],
      content: row["content"],
      occurred_at: row["occurred_at"]
    }
  end
end
