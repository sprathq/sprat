defmodule Sprat.Store.Tasks do
  @moduledoc """
  Task CRUD and state transitions. `transition/5` is the one place a
  task's `status` column changes, and it always writes the new status and
  a `task.transitioned` event in the same `Store.transact/2` call — the
  core rule from docs/spec-v1.md §13. Invalid transitions (per
  `Sprat.Store.TaskState`) are rejected before any write happens.
  """

  alias Sprat.Store.{Events, SQL, TaskState}

  defstruct [
    :id,
    :mission_id,
    :parent_task_id,
    :role,
    :objective,
    :status,
    :attempt,
    :inputs,
    :deliverables,
    :acceptance_criteria,
    :limits,
    :created_at,
    :updated_at
  ]

  def create(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> create_in_conn(conn, mission_id, attrs) end)
  end

  def create_in_conn(conn, mission_id, attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    task = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: mission_id,
      parent_task_id: attrs[:parent_task_id],
      role: Map.fetch!(attrs, :role),
      objective: Map.fetch!(attrs, :objective),
      status: "queued",
      attempt: 1,
      inputs: encode(attrs[:inputs]),
      deliverables: encode(attrs[:deliverables]),
      acceptance_criteria: encode(attrs[:acceptance_criteria]),
      limits: encode(attrs[:limits]),
      created_at: now,
      updated_at: now
    }

    SQL.exec(
      conn,
      """
      INSERT INTO tasks
        (id, mission_id, parent_task_id, role, objective, status, attempt,
         inputs, deliverables, acceptance_criteria, limits, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
      """,
      [
        task.id,
        task.mission_id,
        task.parent_task_id,
        task.role,
        task.objective,
        task.status,
        task.attempt,
        task.inputs,
        task.deliverables,
        task.acceptance_criteria,
        task.limits,
        task.created_at,
        task.updated_at
      ]
    )

    task
  end

  @doc """
  Transitions `task_id` to `to_status`. Rejects invalid transitions
  without writing anything. `attrs` may include `:actor`, `:reason` (event
  metadata) and `:session_id` (required, to write the event under the
  right session). Bumps `attempt` by one when transitioning
  `changes_requested -> queued`. Returns `{:ok, task}`,
  `{:error, :invalid_transition}` or `{:error, :not_found}`.
  """
  def transition(store \\ Sprat.Store, task_id, to_status, attrs) do
    Sprat.Store.transact(store, fn conn -> transition_in_conn(conn, task_id, to_status, attrs) end)
    |> case do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, task} -> {:ok, task}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition_in_conn(conn, task_id, to_status, attrs) do
    to_status = to_string(to_status)

    case SQL.fetch_one(conn, "SELECT * FROM tasks WHERE id = ?1", [task_id]) do
      nil ->
        {:error, :not_found}

      row ->
        # Ensure TaskState's module code is loaded before to_existing_atom/1
        # below: the atoms it names as literals (:queued, :running, ...)
        # only enter the VM's atom table once the module itself is loaded,
        # which a bare String.to_existing_atom/1 call does not trigger.
        Code.ensure_loaded!(TaskState)
        from_status = String.to_existing_atom(row["status"])

        case TaskState.transition(from_status, String.to_existing_atom(to_status)) do
          {:error, reason} ->
            {:error, reason}

          {:ok, _} ->
            attempt =
              if from_status == :changes_requested and to_status == "queued" do
                row["attempt"] + 1
              else
                row["attempt"]
              end

            now = DateTime.utc_now() |> DateTime.to_iso8601()

            SQL.exec(
              conn,
              "UPDATE tasks SET status = ?1, attempt = ?2, updated_at = ?3 WHERE id = ?4",
              [to_status, attempt, now, task_id]
            )

            Events.append_in_conn(conn, Map.fetch!(attrs, :session_id), "task.transitioned", %{
              mission_id: row["mission_id"],
              task_id: task_id,
              attempt: attempt,
              agent_id: attrs[:actor],
              payload: %{
                "from" => row["status"],
                "to" => to_status,
                "reason" => attrs[:reason]
              }
            })

            get_in_conn(conn, task_id)
        end
    end
  end

  def get(store \\ Sprat.Store, id) do
    case Sprat.Store.fetch_one(store, "SELECT * FROM tasks WHERE id = ?1", [id]) do
      nil -> nil
      row -> row_to_task(row)
    end
  end

  defp get_in_conn(conn, id) do
    case SQL.fetch_one(conn, "SELECT * FROM tasks WHERE id = ?1", [id]) do
      nil -> nil
      row -> row_to_task(row)
    end
  end

  @doc "All tasks for a mission, optionally filtered by `status`."
  def by_mission(store \\ Sprat.Store, mission_id, status \\ nil) do
    {where, params} =
      if status,
        do: {"mission_id = ?1 AND status = ?2", [mission_id, to_string(status)]},
        else: {"mission_id = ?1", [mission_id]}

    store
    |> Sprat.Store.fetch_all("SELECT * FROM tasks WHERE #{where} ORDER BY created_at ASC", params)
    |> Enum.map(&row_to_task/1)
  end

  @doc "All tasks currently in `running` status, across every mission — used by Recovery."
  def running(store \\ Sprat.Store) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM tasks WHERE status = 'running'")
    |> Enum.map(&row_to_task/1)
  end

  @doc """
  Tasks in `running` status that belong to `session_id` (via their
  mission). Recovery must never touch a task outside its own session — a
  second `sprat` process for a different session (its own new session id)
  can have a task genuinely running right now, and a global `running/1`
  scan would yank it out from under that live process the instant this
  one boots (see docs/PAUSE.md / the finish_ok crash this was written to
  fix: two different session ids racing on one task row).
  """
  def running_for_session(store \\ Sprat.Store, session_id) do
    store
    |> Sprat.Store.fetch_all(
      """
      SELECT t.* FROM tasks t
      JOIN missions m ON m.id = t.mission_id
      WHERE t.status = 'running' AND m.session_id = ?1
      """,
      [session_id]
    )
    |> Enum.map(&row_to_task/1)
  end

  defp row_to_task(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      parent_task_id: row["parent_task_id"],
      role: row["role"],
      objective: row["objective"],
      status: row["status"],
      attempt: row["attempt"],
      inputs: decode(row["inputs"]),
      deliverables: decode(row["deliverables"]),
      acceptance_criteria: decode(row["acceptance_criteria"]),
      limits: decode(row["limits"]),
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  defp encode(nil), do: nil
  defp encode(value), do: JSON.encode!(value)

  defp decode(nil), do: nil
  defp decode(value), do: JSON.decode!(value)

  defp generate_id,
    do: "task_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
