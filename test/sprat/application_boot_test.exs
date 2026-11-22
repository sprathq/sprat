defmodule Sprat.ApplicationBootTest do
  # Boots the real :sprat application in a genuinely separate OS process
  # (`mix run --no-start`, then starting it ourselves once SPRAT_DATA_DIR
  # points at a scratch fixture) — the same boot path
  # `Sprat.Application.start/2` runs in production, so this is the most
  # direct proof (short of a full tmux/release round-trip, which
  # test/tty/verify.sh also covers for the schema-mismatch case) that an
  # expected startup failure prints one clean message and exits non-zero
  # instead of a VM panic. A separate OS process is required rather than
  # calling `Sprat.Application.start/2` in-process: on a real failure it
  # calls `System.halt/1`, which would kill this very test run.
  #
  # Booted with `MIX_ENV=dev`, not `test`: `Sprat.Application`'s
  # `halt_on_expected_startup_failure!/0` deliberately skips itself under
  # `@env == :test` (`mix test`'s data dir is stable across runs in the
  # same checkout, so a stray `System.halt/1` there could kill a whole
  # ExUnit run with no test report — see that function's comment), so
  # exercising the actual precheck-and-halt behavior needs a non-test
  # env. `SPRAT_DATA_DIR` is still set explicitly on every call below
  # regardless (belt-and-braces — `Paths.resolve/1` already makes it the
  # top-priority override in every env), so this never risks the real
  # dev or production data directory.
  use ExUnit.Case, async: true

  alias Sprat.Store.{Migrations, SQL}

  @moduletag timeout: 30_000

  describe "Sprat.Application.start/2, booted as a real OS process" do
    test "a database from a newer schema version: clean message, exit 1, no crash dump" do
      dir = mk_scratch_dir()
      db_path = Path.join(dir, "sprat.db")

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      SQL.exec(conn, """
      CREATE TABLE schema_migrations (
        version INTEGER PRIMARY KEY,
        applied_at TEXT NOT NULL
      )
      """)

      newer_version = Migrations.latest_version() + 1

      SQL.exec(conn, "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)", [
        newer_version,
        "2099-01-01T00:00:00Z"
      ])

      Exqlite.Sqlite3.close(conn)

      {output, status} = boot_sprat(dir)

      assert status != 0
      assert output =~ "schema version #{newer_version}"
      assert output =~ "only understands up to version"
      assert output =~ "SPRAT_DATA_DIR"
      refute output =~ "Kernel pid terminated"
      refute output =~ "application_start_failure"
      refute output =~ "** ("
      refute_crash_dump()
    end

    test "a corrupt database file: clean message, exit 1, no crash dump" do
      dir = mk_scratch_dir()
      db_path = Path.join(dir, "sprat.db")
      File.write!(db_path, "not a sqlite database, just garbage bytes")

      {output, status} = boot_sprat(dir)

      assert status != 0
      assert output =~ "could not open its database"
      assert output =~ "corrupt"
      refute output =~ "Kernel pid terminated"
      refute output =~ "** ("
      refute_crash_dump()
    end

    test "an unwritable data directory: clean message, exit 1, no crash dump" do
      parent = mk_scratch_dir()
      File.chmod!(parent, 0o500)
      on_exit(fn -> File.chmod(parent, 0o700) end)
      dir = Path.join(parent, "sub")

      {output, status} = boot_sprat(dir)

      assert status != 0
      assert output =~ "data directory is not writable"
      refute output =~ "Kernel pid terminated"
      refute output =~ "** ("
      refute_crash_dump()
    end
  end

  defp boot_sprat(data_dir) do
    System.cmd(
      "mix",
      ["run", "--no-start", "-e", "Application.ensure_all_started(:sprat)"],
      cd: File.cwd!(),
      env: [{"SPRAT_DATA_DIR", data_dir}, {"MIX_ENV", "dev"}],
      stderr_to_stdout: true
    )
  end

  defp refute_crash_dump do
    refute File.exists?(Path.join(File.cwd!(), "erl_crash.dump"))
  end

  defp mk_scratch_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sprat-appboot-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.chmod(dir, 0o700)
      File.rm_rf(dir)
    end)

    dir
  end
end
