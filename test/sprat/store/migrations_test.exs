defmodule Sprat.Store.MigrationsTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.{Migrations, SQL}

  describe "migrate/1" do
    test "creates every V1 table", %{store: store} do
      tables =
        Sprat.Store.fetch_all(store, "SELECT name FROM sqlite_master WHERE type = 'table'")
        |> Enum.map(& &1["name"])

      for table <-
            ~w(sessions missions tasks events messages artifacts artifact_versions
                       sources claims claim_sources decisions usage_records grants schema_migrations) do
        assert table in tables
      end
    end

    test "records every applied version in schema_migrations, up to the latest", %{store: store} do
      rows = Sprat.Store.fetch_all(store, "SELECT version FROM schema_migrations")
      versions = Enum.map(rows, & &1["version"]) |> Enum.sort()
      assert versions == Enum.to_list(1..Migrations.latest_version())
    end

    test "is idempotent: starting a second Store against the same file re-applies nothing", %{
      tmp_dir: tmp_dir
    } do
      db_path = Path.join(tmp_dir, "reopen.db")

      {:ok, s1} =
        Sprat.Store.start_link(name: :"reopen_#{System.unique_integer()}", db_path: db_path)

      GenServer.stop(s1)

      {:ok, s2} =
        Sprat.Store.start_link(name: :"reopen2_#{System.unique_integer()}", db_path: db_path)

      rows = Sprat.Store.fetch_all(s2, "SELECT version FROM schema_migrations")
      assert length(rows) == Migrations.latest_version()
    end

    test "refuses to start against a database from a newer schema version", %{
      tmp_dir: tmp_dir
    } do
      db_path = Path.join(tmp_dir, "future.db")

      {:ok, s1} =
        Sprat.Store.start_link(name: :"future_#{System.unique_integer()}", db_path: db_path)

      Sprat.Store.call(s1, fn conn ->
        SQL.exec(conn, "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)", [
          Migrations.latest_version() + 1,
          "2099-01-01T00:00:00Z"
        ])
      end)

      GenServer.stop(s1)

      Process.flag(:trap_exit, true)

      assert {:error, {%Migrations.SchemaTooNewError{}, _}} =
               Sprat.Store.start_link(
                 name: :"future2_#{System.unique_integer()}",
                 db_path: db_path
               )
    end

    test "migrating from version 2 to version 3 preserves existing mission rows and adds the status constraint" do
      {:ok, conn} = Exqlite.Sqlite3.open(":memory:")

      # Hand-build the pre-migration-3 schema (status free text, no CHECK) —
      # the exact v1 DDL for the two tables migration 3 touches — and stamp
      # schema_migrations as already at version 2, so the upcoming
      # `Migrations.migrate/1` call below applies only migration 3.
      SQL.exec(conn, """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)

      SQL.exec(conn, """
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        project_path TEXT,
        mode TEXT NOT NULL DEFAULT 'team'
      )
      """)

      SQL.exec(conn, """
      CREATE TABLE missions (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        objective TEXT NOT NULL,
        status TEXT NOT NULL,
        budget_cents TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      """)

      # A child table with a live FK reference to missions(id) — the real
      # v1 schema has several (tasks, artifacts, sources, claims,
      # decisions, grants). Migration 3 rebuilds `missions` via
      # create-new/copy/drop-old/rename, and dropping a table other
      # tables still reference is exactly what breaks under
      # `PRAGMA foreign_keys=ON` if it isn't turned off for the rebuild.
      SQL.exec(conn, """
      CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        mission_id TEXT NOT NULL REFERENCES missions(id)
      )
      """)

      # Migration 4 (mid-mission steering) `ALTER TABLE`s `artifacts` —
      # present here with its original v1 shape so it, and any migration
      # after it, can run for real against this fixture rather than the
      # test needing to know about every migration added after 3.
      SQL.exec(conn, """
      CREATE TABLE artifacts (
        id TEXT PRIMARY KEY,
        mission_id TEXT NOT NULL REFERENCES missions(id),
        type TEXT NOT NULL,
        owning_role TEXT NOT NULL,
        latest_version INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
      """)

      SQL.exec(conn, "PRAGMA foreign_keys=ON")

      for version <- [1, 2] do
        SQL.exec(conn, "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)", [
          version,
          "2020-01-01T00:00:00Z"
        ])
      end

      SQL.exec(
        conn,
        "INSERT INTO sessions (id, started_at) VALUES (?1, ?2)",
        ["sess_pre", "2020-01-01T00:00:00Z"]
      )

      SQL.exec(
        conn,
        """
        INSERT INTO missions (id, session_id, objective, status, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """,
        [
          "mis_pre",
          "sess_pre",
          "pre-existing mission",
          "active",
          "2020-01-01T00:00:00Z",
          "2020-01-01T00:00:00Z"
        ]
      )

      SQL.exec(conn, "INSERT INTO tasks (id, mission_id) VALUES (?1, ?2)", [
        "task_pre",
        "mis_pre"
      ])

      :ok = Migrations.migrate(conn)

      assert %{"version" => v} =
               SQL.fetch_one(conn, "SELECT MAX(version) AS version FROM schema_migrations")

      assert v == Migrations.latest_version()

      assert %{"status" => "active"} =
               SQL.fetch_one(conn, "SELECT status FROM missions WHERE id = ?1", ["mis_pre"])

      assert %{"id" => "task_pre"} =
               SQL.fetch_one(conn, "SELECT id FROM tasks WHERE id = ?1", ["task_pre"])

      # foreign_keys enforcement is back on after the migration commits.
      assert_raise CaseClauseError, fn ->
        SQL.exec(conn, "INSERT INTO tasks (id, mission_id) VALUES (?1, ?2)", [
          "task_orphan",
          "mission_missing"
        ])
      end

      assert_raise CaseClauseError, fn ->
        SQL.exec(
          conn,
          """
          INSERT INTO missions (id, session_id, objective, status, created_at, updated_at)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6)
          """,
          [
            "mis_bogus",
            "sess_pre",
            "bad status",
            "bogus_status",
            "2020-01-01T00:00:00Z",
            "2020-01-01T00:00:00Z"
          ]
        )
      end
    end
  end
end
