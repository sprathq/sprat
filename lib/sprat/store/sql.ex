defmodule Sprat.Store.SQL do
  @moduledoc """
  Thin IO layer over a raw `Exqlite.Sqlite3` connection. Every function here
  takes the connection directly rather than going through the `Sprat.Store`
  GenServer, so it can be called both from `Sprat.Store.call/2` (one
  statement) and from inside `Sprat.Store.transact/2` (several statements,
  one BEGIN/COMMIT) without deadlocking the owning process against itself.
  """

  alias Exqlite.Sqlite3

  @doc """
  Runs a statement, discarding any result rows (DDL, INSERT/UPDATE/DELETE,
  or a PRAGMA that happens to return its setting as a row, e.g.
  `PRAGMA journal_mode=WAL`).
  """
  def exec(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    step_to_done(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    :ok
  end

  defp step_to_done(conn, stmt) do
    case Sqlite3.step(conn, stmt) do
      :done -> :ok
      {:row, _} -> step_to_done(conn, stmt)
    end
  end

  @doc "Runs a statement and returns all result rows as a list of maps keyed by column name."
  def fetch_all(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, columns} = Sqlite3.columns(conn, stmt)
    columns = Enum.map(columns, &to_string/1)
    rows = collect_rows(conn, stmt, columns, [])
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  @doc "Runs a statement and returns the first row as a map, or nil."
  def fetch_one(conn, sql, params \\ []) do
    case fetch_all(conn, sql, params) do
      [row | _] -> row
      [] -> nil
    end
  end

  defp collect_rows(conn, stmt, columns, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, values} ->
        collect_rows(conn, stmt, columns, [Enum.zip(columns, values) |> Map.new() | acc])

      :done ->
        Enum.reverse(acc)
    end
  end
end
