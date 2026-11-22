defmodule Sprat.Store.PrecheckTest do
  # async: false — this sets SPRAT_DATA_DIR, which is process-global: running it
  # alongside Sprat.Store.PathsTest made that suite see an override it never set.
  use ExUnit.Case, async: false

  alias Sprat.Store.{Migrations, SQL}

  describe "precheck/1" do
    test "returns :ok for a fresh, writable location" do
      tmp_dir = mk_tmp_dir()
      db_path = Path.join(tmp_dir, "sprat.db")

      assert :ok = Sprat.Store.precheck(db_path)
    end

    test "returns a clean, specific error for a database from a newer schema version" do
      tmp_dir = mk_tmp_dir()
      db_path = Path.join(tmp_dir, "sprat.db")

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      SQL.exec(conn, """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)

      SQL.exec(conn, "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)", [
        Migrations.latest_version() + 1,
        "2099-01-01T00:00:00Z"
      ])

      Exqlite.Sqlite3.close(conn)

      assert {:error, message} = Sprat.Store.precheck(db_path)
      assert message =~ "schema version #{Migrations.latest_version() + 1}"
      assert message =~ "only understands up to version #{Migrations.latest_version()}"
      assert message =~ "SPRAT_DATA_DIR"
      refute message =~ "** ("
      refute message =~ "Kernel pid terminated"
    end

    test "returns a clean, specific error for a corrupt database file" do
      tmp_dir = mk_tmp_dir()
      db_path = Path.join(tmp_dir, "sprat.db")
      File.write!(db_path, "not a sqlite database, just garbage bytes")

      assert {:error, message} = Sprat.Store.precheck(db_path)
      assert message =~ "could not open its database"
      assert message =~ "corrupt"
      assert message =~ "SPRAT_DATA_DIR"
    end

    test "returns a clean, specific error for an unwritable data directory" do
      tmp_dir = mk_tmp_dir()
      locked_parent = Path.join(tmp_dir, "locked")
      File.mkdir_p!(locked_parent)
      File.chmod!(locked_parent, 0o500)
      on_exit(fn -> File.chmod(locked_parent, 0o700) end)

      db_path = Path.join([locked_parent, "sub", "sprat.db"])

      assert {:error, message} = Sprat.Store.precheck(db_path)
      assert message =~ "data directory is not writable"
      assert message =~ "SPRAT_DATA_DIR"
    end
  end

  defp mk_tmp_dir do
    dir =
      Path.join(System.tmp_dir!(), "sprat-precheck-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
