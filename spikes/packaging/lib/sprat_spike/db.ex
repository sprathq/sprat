defmodule SpratSpike.Db do
  @moduledoc """
  Proves exqlite's precompiled NIF works: opens a WAL-mode SQLite database
  under the platform app data dir, creates a table, inserts inside a
  transaction, and reads it back.
  """

  alias Exqlite.Sqlite3

  alias SpratSpike.Paths

  @doc "Opens the DB, runs a create/insert/select round-trip, returns {:ok, row} | {:error, term}."
  def smoke_test do
    db_path = Path.join(Paths.data_dir(), "spike.db")

    with {:ok, conn} <- Sqlite3.open(db_path),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS pings (id INTEGER PRIMARY KEY, note TEXT)"
           ),
         :ok <- Sqlite3.execute(conn, "BEGIN"),
         {:ok, stmt} <- Sqlite3.prepare(conn, "INSERT INTO pings (note) VALUES (?1)"),
         :ok <- Sqlite3.bind(stmt, [note()]),
         :done <- Sqlite3.step(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt),
         :ok <- Sqlite3.execute(conn, "COMMIT"),
         {:ok, stmt} <-
           Sqlite3.prepare(conn, "SELECT id, note FROM pings ORDER BY id DESC LIMIT 1"),
         {:row, row} <- Sqlite3.step(conn, stmt),
         :ok <- Sqlite3.release(conn, stmt),
         {:ok, version_stmt} <- Sqlite3.prepare(conn, "SELECT sqlite_version()"),
         {:row, [version]} <- Sqlite3.step(conn, version_stmt),
         :ok <- Sqlite3.release(conn, version_stmt),
         :ok <- Sqlite3.close(conn) do
      {:ok, %{path: db_path, row: row, sqlite_version: version}}
    end
  end

  defp note, do: "spike-#{System.system_time(:millisecond)}"
end
