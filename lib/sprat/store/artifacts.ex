defmodule Sprat.Store.Artifacts do
  @moduledoc """
  Versioned artifact CRUD (docs/spec-v1.md §5 "Artifacts... Versioned,
  with author, sources and acceptance state; new evidence produces a new
  version"). One `artifacts` row per `(mission_id, type)`; every write
  appends an `artifact_versions` row and bumps `artifacts.latest_version`
  in the same transaction, mirroring `Sprat.Store.Tasks.transition/4`'s
  "state change + event together" rule.
  """

  alias Sprat.Store.SQL

  defstruct [
    :id,
    :mission_id,
    :type,
    :owning_role,
    :latest_version,
    :created_at,
    stale: false,
    stale_reason: nil
  ]

  defmodule Version do
    @moduledoc "One artifact version."
    defstruct [:id, :artifact_id, :version, :content, :blob_hash, :created_by, :created_at]
  end

  @doc "Writes a new version of `attrs.type` for `mission_id`, creating the artifact row if this is the first write."
  def write(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> write_in_conn(conn, mission_id, attrs) end)
  end

  def write_in_conn(conn, mission_id, attrs) do
    type = to_string(Map.fetch!(attrs, :type))
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    artifact =
      case SQL.fetch_one(conn, "SELECT * FROM artifacts WHERE mission_id = ?1 AND type = ?2", [
             mission_id,
             type
           ]) do
        nil ->
          id = generate_artifact_id()

          SQL.exec(
            conn,
            """
            INSERT INTO artifacts (id, mission_id, type, owning_role, latest_version, created_at)
            VALUES (?1, ?2, ?3, ?4, 0, ?5)
            """,
            [id, mission_id, type, Map.fetch!(attrs, :owning_role), now]
          )

          %__MODULE__{
            id: id,
            mission_id: mission_id,
            type: type,
            owning_role: Map.fetch!(attrs, :owning_role),
            latest_version: 0,
            created_at: now
          }

        row ->
          row_to_artifact(row)
      end

    version = artifact.latest_version + 1

    SQL.exec(
      conn,
      """
      INSERT INTO artifact_versions (artifact_id, version, content, blob_hash, created_by, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [
        artifact.id,
        version,
        JSON.encode!(Map.fetch!(attrs, :content)),
        attrs[:blob_hash],
        attrs[:created_by],
        now
      ]
    )

    # A fresh write clears staleness (docs/spec-v1.md §10): whatever
    # invalidated the previous version, this new one was written with
    # that context already available (steering is folded into every
    # stage's context package before any tool runs — see `Sprat.Steering`)
    # so it's the mission's honest current answer again, whether or not it
    # actually addressed the steering. See `mark_stale_in_conn/3`'s
    # comment for the conservative line this draws.
    SQL.exec(
      conn,
      "UPDATE artifacts SET latest_version = ?1, stale = 0, stale_reason = NULL WHERE id = ?2",
      [version, artifact.id]
    )

    %{
      artifact: %{artifact | latest_version: version, stale: false, stale_reason: nil},
      version: version
    }
  end

  @doc """
  Marks every artifact this mission has already written as stale, with
  `reason` (docs/spec-v1.md §10: "marks relevant artifacts stale when
  scope changes"). Called once per queued steering message
  (`Sprat.Steering.queue/4`), inside the same transaction that records it.

  Conservative by construction: an artifact is never deleted or
  rewritten here, only flagged — `Sprat.Workflow.Gate.check/5`'s
  `stale_types` reads this back and refuses to let a stale artifact
  satisfy a gate's existence requirement, but nothing else in this build
  looks at the flag to change behaviour (a stage's `required_inputs`
  context still includes a stale artifact's latest content, alongside the
  steering that made it stale, and lets the model judge — see
  `Sprat.Orchestrator.build_stage_context/5`). Returns the artifact types
  actually marked (already-stale rows are left alone, so a second
  steering message layered on the first doesn't blow away the first
  message's `stale_reason`).
  """
  def mark_stale_in_conn(conn, mission_id, reason) do
    rows =
      SQL.fetch_all(conn, "SELECT type FROM artifacts WHERE mission_id = ?1 AND stale = 0", [
        mission_id
      ])

    types = Enum.map(rows, & &1["type"])

    if types != [] do
      SQL.exec(
        conn,
        "UPDATE artifacts SET stale = 1, stale_reason = ?1 WHERE mission_id = ?2 AND stale = 0",
        [reason, mission_id]
      )
    end

    types
  end

  @doc "Artifact type atoms currently marked stale for `mission_id` — the set `Sprat.Workflow.Gate.check/5` refuses to satisfy a requirement with."
  def stale_types(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all("SELECT type FROM artifacts WHERE mission_id = ?1 AND stale = 1", [
      mission_id
    ])
    |> Enum.map(&String.to_atom(&1["type"]))
    |> MapSet.new()
  end

  @doc "The decoded content of `type`'s latest version for `mission_id`, or `nil`."
  def latest(store \\ Sprat.Store, mission_id, type) do
    case Sprat.Store.fetch_one(
           store,
           """
           SELECT v.content FROM artifact_versions v
           JOIN artifacts a ON a.id = v.artifact_id
           WHERE a.mission_id = ?1 AND a.type = ?2
           ORDER BY v.version DESC LIMIT 1
           """,
           [mission_id, to_string(type)]
         ) do
      nil -> nil
      %{"content" => content} -> JSON.decode!(content)
    end
  end

  @doc "Every artifact type this mission has written, mapped to its latest version's decoded content — the shape `Sprat.Workflow.Gate.check/3` takes."
  def latest_all(store \\ Sprat.Store, mission_id) do
    store
    |> by_mission(mission_id)
    |> Map.new(fn a -> {String.to_atom(a.type), latest(store, mission_id, a.type)} end)
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM artifacts WHERE mission_id = ?1 ORDER BY created_at ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_artifact/1)
  end

  @doc """
  `by_mission/2`, each entry a plain map also carrying its latest
  version's real decoded `:content` (`by_mission/2` alone is metadata
  only — type, owning_role, latest_version). Shared by `Sprat.Export`
  (the export bundle) and `Sprat.Orchestrator`'s Inspector broadcast (the
  TUI's Artifacts tab / Detail card render), so both read artifact
  content the same one way.
  """
  def by_mission_with_content(store \\ Sprat.Store, mission_id) do
    store
    |> by_mission(mission_id)
    |> Enum.map(fn artifact ->
      artifact
      |> Map.from_struct()
      |> Map.put(:content, latest(store, mission_id, artifact.type))
    end)
  end

  @doc "All versions of one artifact, oldest first — for the Inspector's Artifacts tab."
  def versions(store \\ Sprat.Store, artifact_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM artifact_versions WHERE artifact_id = ?1 ORDER BY version ASC",
      [artifact_id]
    )
    |> Enum.map(&row_to_version/1)
  end

  defp row_to_artifact(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      type: row["type"],
      owning_role: row["owning_role"],
      latest_version: row["latest_version"],
      created_at: row["created_at"],
      stale: row["stale"] == 1,
      stale_reason: row["stale_reason"]
    }
  end

  defp row_to_version(row) do
    %Version{
      id: row["id"],
      artifact_id: row["artifact_id"],
      version: row["version"],
      content: JSON.decode!(row["content"]),
      blob_hash: row["blob_hash"],
      created_by: row["created_by"],
      created_at: row["created_at"]
    }
  end

  defp generate_artifact_id,
    do: "art_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
