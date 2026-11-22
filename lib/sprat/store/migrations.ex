defmodule Sprat.Store.Migrations.SchemaTooNewError do
  @moduledoc """
  Raised by `Sprat.Store.Migrations.migrate/1` when a database's recorded
  schema version is newer than this build's `latest_version/0` — refusing
  to run against it rather than risk corrupting it (see `migrate/1`'s own
  moduledoc for why there's no downgrade path).

  A dedicated struct rather than a bare `raise "string"` on purpose:
  `Sprat.Store.precheck/1` classifies this specific, expected failure by
  matching this exception's TYPE, not by regex-matching a message that a
  future, purely-cosmetic reword could silently break.
  """
  defexception [:applied, :latest]

  @impl true
  def message(%{applied: applied, latest: latest}) do
    "database schema is at version #{applied}, but this build of Sprat only knows " <>
      "migrations up to version #{latest}. Refusing to start against a database from a " <>
      "newer version rather than risk corrupting it."
  end
end

defmodule Sprat.Store.Migrations do
  @moduledoc """
  Versioned schema migrations, applied once at startup inside a single
  transaction and recorded in `schema_migrations`. There is no down
  migration in V1 (nothing needs one yet); instead `migrate/1` refuses to
  run against a database stamped with a version newer than the running
  code knows about, rather than guessing how to proceed against a schema
  it doesn't understand.

  Tables are the V1 cut of docs/spec-v1.md §15: `sessions`, `missions`,
  `tasks`, `events`, `messages`, `artifacts`, `artifact_versions`,
  `sources`, `claims`, `claim_sources`, `decisions`, `usage_records`,
  `grants`. Indexes cover the read paths §13 Recovery/§12/§6 imply: events
  by session+seq and by task, tasks by mission+status, sources by
  canonical URL, usage by task.
  """

  alias Sprat.Store.Migrations.SchemaTooNewError
  alias Sprat.Store.SQL

  @migrations [
    {1, "v1 base schema",
     """
     CREATE TABLE sessions (
       id TEXT PRIMARY KEY,
       started_at TEXT NOT NULL,
       ended_at TEXT,
       project_path TEXT,
       mode TEXT NOT NULL DEFAULT 'team'
     );

     CREATE TABLE missions (
       id TEXT PRIMARY KEY,
       session_id TEXT NOT NULL REFERENCES sessions(id),
       objective TEXT NOT NULL,
       status TEXT NOT NULL,
       budget_cents TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL
     );
     CREATE INDEX idx_missions_session ON missions(session_id);

     CREATE TABLE tasks (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       parent_task_id TEXT REFERENCES tasks(id),
       role TEXT NOT NULL,
       objective TEXT NOT NULL,
       status TEXT NOT NULL,
       attempt INTEGER NOT NULL DEFAULT 1,
       inputs TEXT,
       deliverables TEXT,
       acceptance_criteria TEXT,
       limits TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL
     );
     CREATE INDEX idx_tasks_mission_status ON tasks(mission_id, status);

     CREATE TABLE events (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       event_id TEXT NOT NULL UNIQUE,
       schema_version INTEGER NOT NULL,
       session_id TEXT NOT NULL,
       mission_id TEXT,
       task_id TEXT,
       attempt INTEGER,
       agent_id TEXT,
       seq INTEGER NOT NULL,
       type TEXT NOT NULL,
       occurred_at TEXT NOT NULL,
       recorded_at TEXT NOT NULL,
       correlation_id TEXT,
       causation_id TEXT,
       payload TEXT,
       payload_ref TEXT,
       redaction_applied INTEGER NOT NULL DEFAULT 0
     );
     CREATE UNIQUE INDEX idx_events_session_seq ON events(session_id, seq);
     CREATE INDEX idx_events_task ON events(task_id);
     CREATE INDEX idx_events_session_type ON events(session_id, type);
     CREATE INDEX idx_events_occurred_at ON events(occurred_at);

     CREATE TABLE messages (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       session_id TEXT NOT NULL,
       task_id TEXT,
       role TEXT NOT NULL,
       agent_id TEXT,
       content TEXT NOT NULL,
       occurred_at TEXT NOT NULL
     );
     CREATE INDEX idx_messages_session ON messages(session_id, occurred_at);

     CREATE TABLE artifacts (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       type TEXT NOT NULL,
       owning_role TEXT NOT NULL,
       latest_version INTEGER NOT NULL DEFAULT 0,
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_artifacts_mission ON artifacts(mission_id);

     CREATE TABLE artifact_versions (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       artifact_id TEXT NOT NULL REFERENCES artifacts(id),
       version INTEGER NOT NULL,
       content TEXT,
       blob_hash TEXT,
       created_by TEXT,
       created_at TEXT NOT NULL
     );
     CREATE UNIQUE INDEX idx_artifact_versions ON artifact_versions(artifact_id, version);

     CREATE TABLE sources (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       url TEXT NOT NULL,
       canonical_url TEXT NOT NULL,
       title TEXT,
       publisher TEXT,
       published_at TEXT,
       retrieved_at TEXT NOT NULL,
       source_type TEXT NOT NULL,
       content_hash TEXT,
       snapshot_blob_hash TEXT,
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_sources_canonical_url ON sources(canonical_url);
     CREATE INDEX idx_sources_mission ON sources(mission_id);

     CREATE TABLE claims (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       artifact_id TEXT REFERENCES artifacts(id),
       section TEXT,
       text TEXT NOT NULL,
       confidence TEXT NOT NULL,
       justification TEXT,
       scope TEXT,
       is_assumption INTEGER NOT NULL DEFAULT 0,
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_claims_mission ON claims(mission_id);

     CREATE TABLE claim_sources (
       claim_id TEXT NOT NULL REFERENCES claims(id),
       source_id TEXT NOT NULL REFERENCES sources(id),
       stance TEXT NOT NULL,
       PRIMARY KEY (claim_id, source_id, stance)
     );

     CREATE TABLE decisions (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       summary TEXT NOT NULL,
       evidence_for TEXT,
       evidence_against TEXT,
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_decisions_mission ON decisions(mission_id);

     CREATE TABLE usage_records (
       id TEXT PRIMARY KEY,
       task_id TEXT NOT NULL,
       mission_id TEXT NOT NULL,
       role_instance TEXT,
       provider TEXT NOT NULL,
       model TEXT NOT NULL,
       request_id TEXT,
       attempt INTEGER,
       raw_payload TEXT NOT NULL,
       normalization_version INTEGER NOT NULL,
       input_tokens INTEGER,
       output_tokens INTEGER,
       cache_read_tokens INTEGER,
       cache_write_tokens INTEGER,
       server_tool_counts TEXT,
       cost_decimal TEXT,
       pricing_version TEXT,
       coverage TEXT NOT NULL,
       started_at TEXT,
       first_token_at TEXT,
       ended_at TEXT
     );
     CREATE INDEX idx_usage_task ON usage_records(task_id);
     CREATE INDEX idx_usage_mission ON usage_records(mission_id);

     CREATE TABLE grants (
       id TEXT PRIMARY KEY,
       session_id TEXT NOT NULL REFERENCES sessions(id),
       tool TEXT NOT NULL,
       scope TEXT,
       decision TEXT NOT NULL,
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_grants_session ON grants(session_id);
     """},
    {2, "grants: action/resource/lifetime/mission (docs/spec-v1.md §9)",
     """
     ALTER TABLE grants ADD COLUMN action TEXT;
     ALTER TABLE grants ADD COLUMN resource TEXT;
     ALTER TABLE grants ADD COLUMN resource_scope TEXT;
     ALTER TABLE grants ADD COLUMN lifetime TEXT;
     ALTER TABLE grants ADD COLUMN mission_id TEXT REFERENCES missions(id);
     CREATE INDEX idx_grants_session_action_resource ON grants(session_id, action, resource);
     """},
    {3, "missions: status becomes a checked enum including paused_budget (docs/spec-v1.md §12)",
     """
     CREATE TABLE missions_new (
       id TEXT PRIMARY KEY,
       session_id TEXT NOT NULL REFERENCES sessions(id),
       objective TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('active', 'paused_budget', 'completed', 'failed', 'cancelled')),
       budget_cents TEXT,
       created_at TEXT NOT NULL,
       updated_at TEXT NOT NULL
     );
     INSERT INTO missions_new SELECT id, session_id, objective, status, budget_cents, created_at, updated_at FROM missions;
     DROP TABLE missions;
     ALTER TABLE missions_new RENAME TO missions;
     CREATE INDEX idx_missions_session ON missions(session_id);
     """},
    {4,
     "mid-mission steering (docs/spec-v1.md §10): queued/delivered user " <>
       "messages per mission, and a stale marker on artifacts a steering " <>
       "message may have invalidated",
     """
     ALTER TABLE artifacts ADD COLUMN stale INTEGER NOT NULL DEFAULT 0;
     ALTER TABLE artifacts ADD COLUMN stale_reason TEXT;

     CREATE TABLE steering_messages (
       id TEXT PRIMARY KEY,
       session_id TEXT NOT NULL REFERENCES sessions(id),
       mission_id TEXT NOT NULL REFERENCES missions(id),
       text TEXT NOT NULL,
       status TEXT NOT NULL CHECK (status IN ('queued', 'delivered')),
       created_at TEXT NOT NULL,
       delivered_at TEXT
     );
     CREATE INDEX idx_steering_mission ON steering_messages(mission_id, created_at);
     """},
    {5,
     "run evidence (docs/spec-v2.md §10): every shell/tool execution the " <>
       "build phase performs, queryable by mission and by task",
     """
     CREATE TABLE runs (
       id TEXT PRIMARY KEY,
       mission_id TEXT NOT NULL REFERENCES missions(id),
       task_id TEXT REFERENCES tasks(id),
       command TEXT NOT NULL,
       args TEXT NOT NULL,
       cwd TEXT NOT NULL,
       exit_code INTEGER,
       duration_ms INTEGER NOT NULL,
       output_blob_hash TEXT,
       truncated INTEGER NOT NULL DEFAULT 0,
       network INTEGER NOT NULL DEFAULT 0,
       sandbox_strength TEXT NOT NULL CHECK (sandbox_strength IN ('enforced', 'partial', 'none')),
       purpose TEXT NOT NULL CHECK (purpose IN ('install', 'test', 'run', 'health_check', 'lint', 'other')),
       created_at TEXT NOT NULL
     );
     CREATE INDEX idx_runs_mission ON runs(mission_id, created_at);
     CREATE INDEX idx_runs_task ON runs(task_id, created_at);
     """}
  ]

  @latest_version @migrations |> Enum.map(&elem(&1, 0)) |> Enum.max()

  @doc "Applies any migration versions not yet recorded, each inside its own transaction."
  def migrate(conn) do
    SQL.exec(conn, """
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL
    )
    """)

    applied = current_version(conn)

    if applied > @latest_version do
      raise SchemaTooNewError, applied: applied, latest: @latest_version
    end

    @migrations
    |> Enum.filter(fn {version, _desc, _sql} -> version > applied end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {version, _desc, sql} -> apply_migration(conn, version, sql) end)

    :ok
  end

  @doc "Highest migration version this build knows about."
  def latest_version, do: @latest_version

  defp current_version(conn) do
    case SQL.fetch_one(conn, "SELECT MAX(version) AS v FROM schema_migrations") do
      %{"v" => v} when is_integer(v) -> v
      _ -> 0
    end
  end

  # `foreign_keys` is toggled off for the duration of the migration, not
  # just inside its transaction: SQLite ignores a `PRAGMA foreign_keys`
  # change made while a transaction is already open, and a create-new/
  # copy/drop-old/rename rebuild (see migration 3) drops a table other
  # tables still reference — with the pragma on, that DROP TABLE fails
  # with "FOREIGN KEY constraint failed" against any database that
  # already has rows referencing it. Off for the whole migration, back on
  # once it's committed, same as SQLite's own documented recipe for this
  # rebuild pattern.
  defp apply_migration(conn, version, sql) do
    :ok = SQL.exec(conn, "PRAGMA foreign_keys=OFF")
    :ok = SQL.exec(conn, "BEGIN IMMEDIATE")

    sql
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&SQL.exec(conn, &1))

    SQL.exec(conn, "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)", [
      version,
      DateTime.utc_now() |> DateTime.to_iso8601()
    ])

    :ok = SQL.exec(conn, "COMMIT")
    :ok = SQL.exec(conn, "PRAGMA foreign_keys=ON")
  end
end
