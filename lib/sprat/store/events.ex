defmodule Sprat.Store.Events do
  @moduledoc """
  Append and query the event log (docs/spec-v1.md §11 envelope).

  Sequence numbers are per-session, gap-free and strictly increasing under
  concurrent writers: since `Sprat.Store` serializes every call through
  one GenServer, `MAX(seq)+1` computed and inserted inside the same
  `Store.transact/2` call can never race with another append for the same
  session — there is only ever one writer in the whole OS process, by
  construction, not by locking.

  Every payload is scrubbed via `Sprat.Store.Redact` before it touches
  disk, in `append/3` itself — callers cannot opt out. Payloads above
  `@inline_threshold` bytes are written to the blob store and referenced
  by `payload_ref` instead of inlined, matching §15's blob store rule
  (large payloads referenced, not duplicated across events and blobs).
  """

  alias Sprat.Store.{Blob, Redact, SQL}

  @schema_version 1
  # ponytail: 4KB inline threshold is a guess at "small"; revisit with real
  # payload sizes once the model/tool layers exist.
  @inline_threshold 4_096

  defstruct [
    :event_id,
    :schema_version,
    :session_id,
    :mission_id,
    :task_id,
    :attempt,
    :agent_id,
    :seq,
    :type,
    :occurred_at,
    :recorded_at,
    :correlation_id,
    :causation_id,
    :payload,
    :payload_ref,
    :redaction_applied
  ]

  @doc """
  Appends an event for `session_id`. `attrs` may include `:mission_id`,
  `:task_id`, `:attempt`, `:agent_id`, `:correlation_id`, `:causation_id`
  and `:payload`. `secrets` is the redaction set (see `Sprat.Store.Redact`).
  Allocates the next `seq` for the session and writes the row inside one
  `Store.transact/2` call. Returns `{:ok, %__MODULE__{}}`.
  """
  def append(store \\ Sprat.Store, session_id, type, attrs \\ %{}, secrets \\ []) do
    Sprat.Store.transact(store, fn conn ->
      append_in_conn(conn, session_id, type, attrs, secrets)
    end)
  end

  @doc "Same as `append/5` but for use inside a caller's own `Store.transact/2` block."
  def append_in_conn(conn, session_id, type, attrs \\ %{}, secrets \\ []) do
    now = utc_now_iso8601()
    seq = next_seq(conn, session_id)
    {payload, payload_ref, redacted?} = store_payload(attrs[:payload], secrets)

    event = %__MODULE__{
      event_id: attrs[:event_id] || generate_id(),
      schema_version: @schema_version,
      session_id: session_id,
      mission_id: attrs[:mission_id],
      task_id: attrs[:task_id],
      attempt: attrs[:attempt],
      agent_id: attrs[:agent_id],
      seq: seq,
      type: type,
      occurred_at: attrs[:occurred_at] || now,
      recorded_at: now,
      correlation_id: attrs[:correlation_id],
      causation_id: attrs[:causation_id],
      payload: payload,
      payload_ref: payload_ref,
      redaction_applied: redacted?
    }

    SQL.exec(
      conn,
      """
      INSERT INTO events
        (event_id, schema_version, session_id, mission_id, task_id, attempt, agent_id,
         seq, type, occurred_at, recorded_at, correlation_id, causation_id, payload,
         payload_ref, redaction_applied)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
      """,
      [
        event.event_id,
        event.schema_version,
        event.session_id,
        event.mission_id,
        event.task_id,
        event.attempt,
        event.agent_id,
        event.seq,
        event.type,
        event.occurred_at,
        event.recorded_at,
        event.correlation_id,
        event.causation_id,
        event.payload,
        event.payload_ref,
        bool_to_int(event.redaction_applied)
      ]
    )

    event
  end

  @doc "All events for a session, oldest first."
  def by_session(store \\ Sprat.Store, session_id, opts \\ []) do
    fetch(store, "session_id = ?1", [session_id], opts)
  end

  @doc "All events for a task, oldest first."
  def by_task(store \\ Sprat.Store, task_id, opts \\ []) do
    fetch(store, "task_id = ?1", [task_id], opts)
  end

  @doc "All events for a mission, oldest first."
  def by_mission(store \\ Sprat.Store, mission_id, opts \\ []) do
    fetch(store, "mission_id = ?1", [mission_id], opts)
  end

  @doc "All events of a given type within a session, oldest first."
  def by_type(store \\ Sprat.Store, session_id, type, opts \\ []) do
    fetch(store, "session_id = ?1 AND type = ?2", [session_id, type], opts)
  end

  @doc "All events in `[from_iso8601, to_iso8601]` occurred_at range, oldest first."
  def by_time_range(store \\ Sprat.Store, from_iso8601, to_iso8601, opts \\ []) do
    fetch(store, "occurred_at >= ?1 AND occurred_at <= ?2", [from_iso8601, to_iso8601], opts)
  end

  defp fetch(store, where, params, opts) do
    limit = Keyword.get(opts, :limit, 1000)
    offset = Keyword.get(opts, :offset, 0)

    sql = """
    SELECT * FROM events WHERE #{where}
    ORDER BY seq ASC LIMIT ?#{length(params) + 1} OFFSET ?#{length(params) + 2}
    """

    store
    |> Sprat.Store.fetch_all(sql, params ++ [limit, offset])
    |> Enum.map(&row_to_event/1)
  end

  defp row_to_event(row) do
    %__MODULE__{
      event_id: row["event_id"],
      schema_version: row["schema_version"],
      session_id: row["session_id"],
      mission_id: row["mission_id"],
      task_id: row["task_id"],
      attempt: row["attempt"],
      agent_id: row["agent_id"],
      seq: row["seq"],
      type: row["type"],
      occurred_at: row["occurred_at"],
      recorded_at: row["recorded_at"],
      correlation_id: row["correlation_id"],
      causation_id: row["causation_id"],
      payload: row["payload"],
      payload_ref: row["payload_ref"],
      redaction_applied: row["redaction_applied"] == 1
    }
  end

  defp next_seq(conn, session_id) do
    case SQL.fetch_one(conn, "SELECT MAX(seq) AS s FROM events WHERE session_id = ?1", [
           session_id
         ]) do
      %{"s" => s} when is_integer(s) -> s + 1
      _ -> 1
    end
  end

  defp store_payload(nil, _secrets), do: {nil, nil, false}

  defp store_payload(payload, secrets) do
    {scrubbed, redacted?} = Redact.scrub(payload, secrets)
    encoded = JSON.encode!(scrubbed)

    if byte_size(encoded) > @inline_threshold do
      {:ok, hash} = Blob.put(encoded, [])
      {nil, "blob:sha256:#{hash}", redacted?}
    else
      {encoded, nil, redacted?}
    end
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp generate_id,
    do: "evt_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

  defp utc_now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
