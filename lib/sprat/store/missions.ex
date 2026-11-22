defmodule Sprat.Store.Missions do
  @moduledoc """
  Minimal CRUD for the `missions` table — enough to satisfy `tasks`'
  foreign key and back the Projection. `transition/4` is the one place a
  mission's `status` changes, always writing the new status and a
  `mission.transitioned` event in the same `Store.transact/2` call —
  mirrors `Sprat.Store.Tasks.transition/4` exactly.
  """

  alias Sprat.Store.{Events, MissionState, SQL}

  defstruct [:id, :session_id, :objective, :status, :budget_cents, :created_at, :updated_at]

  def create(store \\ Sprat.Store, session_id, attrs \\ %{}) do
    Sprat.Store.transact(store, fn conn -> create_in_conn(conn, session_id, attrs) end)
  end

  def create_in_conn(conn, session_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    mission = %__MODULE__{
      id: attrs[:id] || generate_id(),
      session_id: session_id,
      objective: Map.fetch!(attrs, :objective),
      status: attrs[:status] || "active",
      budget_cents: attrs[:budget_cents],
      created_at: now,
      updated_at: now
    }

    SQL.exec(
      conn,
      """
      INSERT INTO missions (id, session_id, objective, status, budget_cents, created_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [
        mission.id,
        mission.session_id,
        mission.objective,
        mission.status,
        mission.budget_cents,
        mission.created_at,
        mission.updated_at
      ]
    )

    mission
  end

  @doc """
  Transitions `mission_id` to `to_status`. Rejects invalid transitions
  (per `Sprat.Store.MissionState`) without writing anything. `attrs`
  requires `:session_id` (to write the event under the right session) and
  accepts `:reason`. Returns `{:ok, mission}`,
  `{:error, :invalid_transition}` or `{:error, :not_found}`.
  """
  def transition(store \\ Sprat.Store, mission_id, to_status, attrs) do
    Sprat.Store.transact(store, fn conn ->
      transition_in_conn(conn, mission_id, to_status, attrs)
    end)
    |> case do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, mission} -> {:ok, mission}
      {:error, reason} -> {:error, reason}
    end
  end

  def transition_in_conn(conn, mission_id, to_status, attrs) do
    to_status = to_string(to_status)

    case SQL.fetch_one(conn, "SELECT * FROM missions WHERE id = ?1", [mission_id]) do
      nil ->
        {:error, :not_found}

      row ->
        # Ensure MissionState's module code is loaded before
        # to_existing_atom/1 below: the atoms it names as literals
        # (:active, :paused_budget, ...) only enter the VM's atom table
        # once the module itself is loaded.
        Code.ensure_loaded!(MissionState)
        from_status = String.to_existing_atom(row["status"])

        case MissionState.transition(from_status, String.to_existing_atom(to_status)) do
          {:error, reason} ->
            {:error, reason}

          {:ok, _} ->
            now = DateTime.utc_now() |> DateTime.to_iso8601()

            SQL.exec(conn, "UPDATE missions SET status = ?1, updated_at = ?2 WHERE id = ?3", [
              to_status,
              now,
              mission_id
            ])

            Events.append_in_conn(conn, Map.fetch!(attrs, :session_id), "mission.transitioned", %{
              mission_id: mission_id,
              payload: %{"from" => row["status"], "to" => to_status, "reason" => attrs[:reason]}
            })

            case SQL.fetch_one(conn, "SELECT * FROM missions WHERE id = ?1", [mission_id]) do
              nil -> nil
              row -> row_to_mission(row)
            end
        end
    end
  end

  def get(store \\ Sprat.Store, id) do
    case Sprat.Store.fetch_one(store, "SELECT * FROM missions WHERE id = ?1", [id]) do
      nil -> nil
      row -> row_to_mission(row)
    end
  end

  @doc "All missions for a session, oldest first — used to summarize a session in `sprat sessions list`."
  def by_session(store \\ Sprat.Store, session_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM missions WHERE session_id = ?1 ORDER BY created_at ASC",
      [session_id]
    )
    |> Enum.map(&row_to_mission/1)
  end

  defp row_to_mission(row) do
    %__MODULE__{
      id: row["id"],
      session_id: row["session_id"],
      objective: row["objective"],
      status: row["status"],
      budget_cents: row["budget_cents"],
      created_at: row["created_at"],
      updated_at: row["updated_at"]
    }
  end

  defp generate_id,
    do: "mis_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
