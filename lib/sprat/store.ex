defmodule Sprat.Store do
  @moduledoc """
  Owns the single SQLite connection (per docs/spec-v1.md §13: "The database
  is the source of truth; process state is a cache", and V1 has one
  process, one writer — no durable broker, no read pool). All reads and
  writes are serialized through this GenServer's mailbox; at Sprat's scale
  (one user, one mission running at a time) that serialization is not a
  bottleneck, and it is what makes `transact/2` trivially correct: a state
  change and its event land in one SQLite transaction because they run as
  one function inside this process, never interleaved with another call.

  ## Durability: WAL + `synchronous=NORMAL`

  The spec's durability target is "event durability acknowledged < 100 ms
  p95" and its recovery acceptance test is `kill -9` at random points, not
  power loss. `synchronous=NORMAL` in WAL mode fsyncs at checkpoints
  rather than after every commit: a committed transaction is always
  handed to the OS and survives the *process* being killed, and the
  database file itself can never be corrupted by a crash mid-write — the
  only thing `NORMAL` risks losing versus `FULL` is the last few commits
  in the unsynced OS buffer if the *machine* loses power, which is out of
  scope here (V1 has no power-loss durability requirement, same as its
  "no encryption at rest" stance: stated openly, not silently assumed).
  `FULL` would fsync every commit and cost real latency for no acceptance
  criterion we actually need to meet.

  Every function here that touches the database takes a `store` argument
  (a pid or registered name) rather than assuming the singleton
  `Sprat.Store`, so tests can run many isolated instances, each against
  its own temp file, with `async: true`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Sprat.Store.Migrations.SchemaTooNewError
  alias Sprat.Store.{Migrations, Paths, SQL}

  defstruct [:conn, :db_path]

  @busy_timeout_ms 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs `fun.(conn)` inside this process, serialized with every other call. No implicit transaction."
  def call(store \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(store, {:call, fun}, :infinity)
  end

  @doc """
  Runs `fun.(conn)` inside one SQLite transaction (`BEGIN IMMEDIATE` /
  `COMMIT`, rolled back on any exception). This is the mechanism behind
  §13's rule that a state change and its event are written together.
  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def transact(store \\ __MODULE__, fun) when is_function(fun, 1) do
    GenServer.call(store, {:transact, fun}, :infinity)
  end

  @doc "Convenience: `call/2` a plain statement with no rows expected."
  def exec(store \\ __MODULE__, sql, params \\ []), do: call(store, &SQL.exec(&1, sql, params))

  @doc "Convenience: `call/2` a SELECT, returning all rows as maps."
  def fetch_all(store \\ __MODULE__, sql, params \\ []),
    do: call(store, &SQL.fetch_all(&1, sql, params))

  @doc "Convenience: `call/2` a SELECT, returning the first row as a map or nil."
  def fetch_one(store \\ __MODULE__, sql, params \\ []),
    do: call(store, &SQL.fetch_one(&1, sql, params))

  @doc """
  Opens `db_path` (default `Paths.db_path/0`) and runs migrations exactly
  as `init/1` is about to, but returns `{:error, message}` instead of
  letting one of three expected startup failures — an unwritable data
  directory, a database from a newer schema version than this build
  understands (`Migrations.migrate/1`'s own refusal, unchanged), or a
  corrupt database file — crash `Sprat.Application.start/2`'s
  `Supervisor.start_link/2` and take the whole VM down with it (a
  `Kernel pid terminated (application_controller)` panic plus an
  `erl_crash.dump` written into the user's cwd — see
  `Sprat.Application.start/2`, which calls this first and halts cleanly
  on `{:error, _}` instead).
  """
  def precheck(db_path \\ nil) do
    # `resolved` is bound by this `case`'s own pattern match, not inside
    # the `try` below — a variable assigned *inside* a `try` body is not
    # visible in its `rescue` clauses (it silently reads as the
    # pre-`try` binding instead, `nil` here), so resolving the path has
    # to happen, and be rescued, before the `try` that opens/migrates it.
    case resolve_writable_path(db_path) do
      {:ok, resolved} -> open_and_migrate(resolved)
      {:error, _message} = error -> error
    end
  end

  defp resolve_writable_path(db_path) do
    db_path = db_path || Paths.db_path()
    db_path |> Path.dirname() |> File.mkdir_p!()
    {:ok, db_path}
  rescue
    error in [File.Error] ->
      {:error,
       "Sprat's data directory is not writable (#{Exception.message(error)}). Fix its " <>
         "permissions, or set SPRAT_DATA_DIR to a writable location, and try again."}
  end

  # Only the three named, expected failures are caught here, each by its
  # own specific exception TYPE/SHAPE — never by a bare `error -> ...`
  # catch-all. A genuine bug reachable from here (a bad migration, an
  # exqlite NIF error, anything else unrecognized) is deliberately left
  # to propagate uncaught: it must surface as a real, visible crash, not
  # get mislabeled to a user as "your database may be corrupt, delete it."
  defp open_and_migrate(db_path) do
    case Sqlite3.open(db_path) do
      {:ok, conn} -> migrate_and_close(db_path, conn)
      {:error, reason} -> corrupt_db_error(db_path, reason)
    end
  end

  defp migrate_and_close(db_path, conn) do
    :ok = Migrations.migrate(conn)
    Sqlite3.close(conn)
    :ok
  rescue
    error in [SchemaTooNewError] ->
      {:error,
       "Sprat's database (#{db_path}) is at schema version #{error.applied}, but this build " <>
         "only understands up to version #{error.latest}. Upgrade Sprat to a build that " <>
         "supports version #{error.applied}, or set SPRAT_DATA_DIR to point at a different " <>
         "database, and try again."}

    error in [MatchError] ->
      reason =
        case error.term do
          {:error, reason} -> reason
          other -> inspect(other)
        end

      corrupt_db_error(db_path, reason)
  end

  defp corrupt_db_error(db_path, reason) do
    {:error,
     "Sprat could not open its database (#{db_path}): #{reason}. It may be corrupt — move " <>
       "or delete it, or set SPRAT_DATA_DIR to point at a different location, and try again."}
  end

  @impl true
  def init(opts) do
    db_path = Keyword.get(opts, :db_path, Paths.db_path())
    db_path |> Path.dirname() |> File.mkdir_p!()

    {:ok, conn} = Sqlite3.open(db_path)
    :ok = SQL.exec(conn, "PRAGMA journal_mode=WAL")
    :ok = SQL.exec(conn, "PRAGMA synchronous=NORMAL")
    :ok = SQL.exec(conn, "PRAGMA foreign_keys=ON")
    :ok = SQL.exec(conn, "PRAGMA busy_timeout=#{@busy_timeout_ms}")

    if File.exists?(db_path), do: File.chmod!(db_path, 0o600)

    :ok = Migrations.migrate(conn)

    {:ok, %__MODULE__{conn: conn, db_path: db_path}}
  end

  @impl true
  def handle_call({:call, fun}, _from, state) do
    {:reply, fun.(state.conn), state}
  end

  def handle_call({:transact, fun}, _from, state) do
    :ok = SQL.exec(state.conn, "BEGIN IMMEDIATE")

    try do
      result = fun.(state.conn)
      :ok = SQL.exec(state.conn, "COMMIT")
      {:reply, {:ok, result}, state}
    rescue
      error ->
        SQL.exec(state.conn, "ROLLBACK")
        {:reply, {:error, error}, state}
    end
  end
end
