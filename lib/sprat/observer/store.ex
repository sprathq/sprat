defmodule Sprat.Observer.Store do
  @moduledoc """
  The V4 observer's own SQLite store (spec §11): findings, PM runs, nudges,
  roadmap writes, accounts, served-today, settings, transcript offsets and an
  event log.

  A GenServer owning one `Exqlite` connection to its own file, by default
  `<data dir>/observer.db`, separate from `Sprat.Store`'s database. Start it
  with `start_link(path: ..., name: ...)`; every API function takes the server
  (a name or pid) first, explicitly.

  Datetimes are stored as ISO 8601 text in UTC with microsecond precision, so
  they sort and compare as strings. Structured fields are JSON. The schema is
  versioned in `schema_version` and migrated forward on start.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Sprat.Observer.Model.{Account, Decision, Finding, Project, Served}
  alias Sprat.Store.SQL

  @busy_timeout_ms 5_000

  @migrations [
    {1,
     [
       """
       CREATE TABLE projects (
         root TEXT PRIMARY KEY, name TEXT, autonomy TEXT NOT NULL DEFAULT 'propose',
         first_seen_at TEXT, archived INTEGER NOT NULL DEFAULT 0,
         autonomy_changed_at TEXT, autonomy_changed_by TEXT)
       """,
       """
       CREATE TABLE offsets (
         transcript_path TEXT PRIMARY KEY, offset INTEGER NOT NULL, next_line INTEGER NOT NULL)
       """,
       """
       CREATE TABLE findings (
         id TEXT PRIMARY KEY, rule TEXT NOT NULL, kind TEXT, project_root TEXT NOT NULL,
         session_id TEXT, summary TEXT, evidence_json TEXT NOT NULL DEFAULT '[]',
         data_json TEXT NOT NULL DEFAULT '{}', state TEXT NOT NULL DEFAULT 'open',
         first_seen_at TEXT, last_seen_at TEXT, dismiss_reason TEXT)
       """,
       "CREATE INDEX findings_state ON findings(state, project_root)",
       """
       CREATE TABLE pm_runs (
         id TEXT PRIMARY KEY, finding_id TEXT, started_at TEXT, finished_at TEXT,
         decision_json TEXT, cost_usd REAL, turns INTEGER, session_id TEXT,
         sources_json TEXT NOT NULL DEFAULT '[]', error TEXT)
       """,
       "CREATE INDEX pm_runs_finding ON pm_runs(finding_id)",
       "CREATE INDEX pm_runs_started ON pm_runs(started_at)",
       """
       CREATE TABLE nudges (
         id TEXT PRIMARY KEY, finding_id TEXT, session_id TEXT, text TEXT, adapter TEXT,
         state TEXT, created_at TEXT, delivered_at TEXT, outcome TEXT, outcome_at TEXT)
       """,
       "CREATE INDEX nudges_session ON nudges(session_id, delivered_at)",
       """
       CREATE TABLE roadmap_writes (
         id TEXT PRIMARY KEY, project_root TEXT, item_id TEXT, from_state TEXT, to_state TEXT,
         reason TEXT, pm_run_id TEXT, at TEXT, reverted_at TEXT)
       """,
       """
       CREATE TABLE accounts (
         config_dir TEXT PRIMARY KEY, limited_until TEXT, limit_kind TEXT, limit_text TEXT,
         resume_queue_json TEXT NOT NULL DEFAULT '[]')
       """,
       """
       CREATE TABLE served (
         id TEXT PRIMARY KEY, at TEXT NOT NULL, project_root TEXT, project_name TEXT,
         text TEXT, by TEXT, ref TEXT)
       """,
       "CREATE INDEX served_at ON served(at)",
       "CREATE TABLE settings (key TEXT PRIMARY KEY, value_json TEXT)",
       """
       CREATE TABLE events (
         id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, type TEXT NOT NULL, data_json TEXT)
       """
     ]},
    # The login (Claude account uuid) a config dir had when its limit hit.
    {2,
     [
       "ALTER TABLE accounts ADD COLUMN login TEXT",
       "ALTER TABLE accounts ADD COLUMN limited_at TEXT"
     ]}
  ]

  @finding_states ~w(open pm_running acted resolved dismissed escalated snoozed)a
  @finding_kinds ~w(needs_you stuck stalled scheduled)a
  @autonomy_levels ~w(watch propose act act_resume)a
  @closed_states ~w(resolved dismissed)

  # ── lifecycle ────────────────────────────────────────────────────────────

  @doc "The default database path: `observer.db` in Sprat's data dir."
  def default_path, do: Path.join(Sprat.Store.Paths.data_dir(), "observer.db")

  @doc "Options: `:path` (db file), `:name` (GenServer name, default `#{inspect(__MODULE__)}`; `nil` for none)."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name) || __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The schema version of the open database."
  def schema_version(server), do: call(server, &current_version/1)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()
    path |> Path.dirname() |> File.mkdir_p!()
    {:ok, conn} = Sqlite3.open(path)
    :ok = SQL.exec(conn, "PRAGMA journal_mode=WAL")
    :ok = SQL.exec(conn, "PRAGMA synchronous=NORMAL")
    :ok = SQL.exec(conn, "PRAGMA busy_timeout=#{@busy_timeout_ms}")
    File.chmod(path, 0o600)
    :ok = migrate(conn)
    {:ok, %{conn: conn, path: path}}
  end

  @impl true
  def handle_call({:call, fun}, _from, state), do: {:reply, fun.(state.conn), state}

  def handle_call({:transact, fun}, _from, state) do
    :ok = SQL.exec(state.conn, "BEGIN IMMEDIATE")

    try do
      result = fun.(state.conn)
      :ok = SQL.exec(state.conn, "COMMIT")
      {:reply, result, state}
    rescue
      error ->
        SQL.exec(state.conn, "ROLLBACK")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.conn)

  defp call(server, fun), do: GenServer.call(server, {:call, fun})
  defp transact(server, fun), do: GenServer.call(server, {:transact, fun})

  defp migrate(conn) do
    :ok = SQL.exec(conn, "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
    current = current_version(conn)

    for {version, statements} <- @migrations, version > current do
      :ok = SQL.exec(conn, "BEGIN IMMEDIATE")
      Enum.each(statements, &(:ok = SQL.exec(conn, &1)))
      :ok = SQL.exec(conn, "DELETE FROM schema_version")
      :ok = SQL.exec(conn, "INSERT INTO schema_version (version) VALUES (?)", [version])
      :ok = SQL.exec(conn, "COMMIT")
    end

    :ok
  end

  defp current_version(conn) do
    case SQL.fetch_one(conn, "SELECT MAX(version) AS v FROM schema_version") do
      %{"v" => v} when is_integer(v) -> v
      _ -> 0
    end
  end

  # ── projects ─────────────────────────────────────────────────────────────

  @doc """
  Records a project on first sight. On later calls only `name` and `archived?`
  change; autonomy and first-seen stay as stored.
  """
  @spec upsert_project(GenServer.server(), Project.t()) :: :ok
  def upsert_project(server, %Project{} = p) do
    call(server, fn conn ->
      SQL.exec(
        conn,
        """
        INSERT INTO projects (root, name, autonomy, first_seen_at, archived) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(root) DO UPDATE SET name = excluded.name, archived = excluded.archived
        """,
        [
          p.root,
          p.name,
          to_string(p.autonomy || :propose),
          iso(p.first_seen_at),
          bool(p.archived?)
        ]
      )
    end)
  end

  @doc "Sets a project's autonomy level, recording who changed it and when."
  @spec set_autonomy(
          GenServer.server(),
          String.t(),
          Project.autonomy(),
          String.t() | atom(),
          DateTime.t()
        ) ::
          :ok
  def set_autonomy(server, root, level, by, %DateTime{} = at)
      when level in @autonomy_levels do
    call(server, fn conn ->
      SQL.exec(
        conn,
        """
        INSERT INTO projects (root, autonomy, first_seen_at, autonomy_changed_at, autonomy_changed_by)
        VALUES (?1, ?2, ?3, ?3, ?4)
        ON CONFLICT(root) DO UPDATE SET autonomy = ?2, autonomy_changed_at = ?3, autonomy_changed_by = ?4
        """,
        [root, to_string(level), iso(at), to_string(by)]
      )
    end)
  end

  @doc "Every stored project as `%Project{}` (root, name, autonomy, first_seen_at, archived?)."
  @spec get_projects(GenServer.server()) :: [Project.t()]
  def get_projects(server) do
    call(server, &SQL.fetch_all(&1, "SELECT * FROM projects ORDER BY root"))
    |> Enum.map(fn r ->
      %Project{
        root: r["root"],
        name: r["name"],
        autonomy: to_atom(r["autonomy"], @autonomy_levels, :propose),
        first_seen_at: dt(r["first_seen_at"]),
        archived?: r["archived"] == 1
      }
    end)
  end

  @doc "When and by whom a project's autonomy last changed, or nil."
  @spec autonomy_change(GenServer.server(), String.t()) ::
          %{level: Project.autonomy(), at: DateTime.t() | nil, by: String.t() | nil} | nil
  def autonomy_change(server, root) do
    case call(server, &SQL.fetch_one(&1, "SELECT * FROM projects WHERE root = ?", [root])) do
      nil ->
        nil

      r ->
        %{
          level: to_atom(r["autonomy"], @autonomy_levels, :propose),
          at: dt(r["autonomy_changed_at"]),
          by: r["autonomy_changed_by"]
        }
    end
  end

  # ── offsets ──────────────────────────────────────────────────────────────

  @doc "Stores where tailing a transcript stopped: byte offset and the next 1-based line number."
  def put_offset(server, path, offset, next_line) do
    call(server, fn conn ->
      SQL.exec(
        conn,
        """
        INSERT INTO offsets (transcript_path, offset, next_line) VALUES (?, ?, ?)
        ON CONFLICT(transcript_path) DO UPDATE SET offset = excluded.offset, next_line = excluded.next_line
        """,
        [path, offset, next_line]
      )
    end)
  end

  @doc "`{offset, next_line}` for a transcript, or nil when never read."
  def get_offset(server, path) do
    case call(
           server,
           &SQL.fetch_one(&1, "SELECT * FROM offsets WHERE transcript_path = ?", [path])
         ) do
      nil -> nil
      r -> {r["offset"], r["next_line"]}
    end
  end

  # ── findings ─────────────────────────────────────────────────────────────

  @doc """
  Inserts a finding, or updates it when its id is already stored: summary,
  evidence, data and `last_seen_at` refresh; `first_seen_at` and state are kept.
  A dismissed or resolved finding whose evidence changed reopens (spec §7:
  dismissed stays dismissed until the evidence changes). Returns the stored
  finding.
  """
  @spec upsert_finding(GenServer.server(), Finding.t()) :: {:ok, Finding.t()}
  def upsert_finding(server, %Finding{} = f) do
    evidence = encode(f.evidence || [])

    transact(server, fn conn ->
      case SQL.fetch_one(conn, "SELECT * FROM findings WHERE id = ?", [f.id]) do
        nil ->
          :ok =
            SQL.exec(
              conn,
              """
              INSERT INTO findings (id, rule, kind, project_root, session_id, summary, evidence_json,
                data_json, state, first_seen_at, last_seen_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
              [
                f.id,
                f.rule,
                str(f.kind),
                f.project_root,
                f.session_id,
                f.summary,
                evidence,
                encode(f.data || %{}),
                str(f.state || :open),
                iso(f.first_seen_at),
                iso(f.last_seen_at || f.first_seen_at)
              ]
            )

        row ->
          reopen? = row["state"] in @closed_states and row["evidence_json"] != evidence

          :ok =
            SQL.exec(
              conn,
              """
              UPDATE findings SET summary = ?, evidence_json = ?, data_json = ?, last_seen_at = ?,
                state = ?, dismiss_reason = ?
              WHERE id = ?
              """,
              [
                f.summary,
                evidence,
                encode(f.data || %{}),
                iso(f.last_seen_at),
                if(reopen?, do: "open", else: row["state"]),
                if(reopen?, do: nil, else: row["dismiss_reason"]),
                f.id
              ]
            )
      end

      {:ok,
       conn |> SQL.fetch_one("SELECT * FROM findings WHERE id = ?", [f.id]) |> row_to_finding()}
    end)
  end

  @doc "One finding by id, or nil."
  @spec get_finding(GenServer.server(), String.t()) :: Finding.t() | nil
  def get_finding(server, id) do
    call(server, &SQL.fetch_one(&1, "SELECT * FROM findings WHERE id = ?", [id]))
    |> row_to_finding()
  end

  @doc """
  Findings not resolved or dismissed, oldest first. Options:
  `project_root: root`, `session_id: sid`.
  """
  @spec list_open_findings(GenServer.server(), keyword()) :: [Finding.t()]
  def list_open_findings(server, opts \\ []) do
    {where, params} =
      Enum.reduce(opts, {["state NOT IN ('resolved', 'dismissed')"], []}, fn
        {:project_root, v}, {w, p} -> {["project_root = ?" | w], p ++ [v]}
        {:session_id, v}, {w, p} -> {["session_id = ?" | w], p ++ [v]}
        _, acc -> acc
      end)

    sql = "SELECT * FROM findings WHERE #{Enum.join(where, " AND ")} ORDER BY first_seen_at, id"
    call(server, &SQL.fetch_all(&1, sql, params)) |> Enum.map(&row_to_finding/1)
  end

  @doc "Moves a finding to `state`. Option `dismiss_reason:` for `:dismissed`."
  @spec set_finding_state(GenServer.server(), String.t(), atom(), keyword()) :: :ok
  def set_finding_state(server, id, state, opts \\ []) when state in @finding_states do
    call(server, fn conn ->
      SQL.exec(conn, "UPDATE findings SET state = ?, dismiss_reason = ? WHERE id = ?", [
        to_string(state),
        Keyword.get(opts, :dismiss_reason),
        id
      ])
    end)
  end

  defp row_to_finding(nil), do: nil

  defp row_to_finding(r) do
    %Finding{
      id: r["id"],
      rule: r["rule"],
      kind: to_atom(r["kind"], @finding_kinds, nil),
      project_root: r["project_root"],
      session_id: r["session_id"],
      summary: r["summary"],
      evidence: decode(r["evidence_json"]) || [],
      data: (decode(r["data_json"]) || %{}) |> atomize(),
      state: to_atom(r["state"], @finding_states, :open),
      first_seen_at: dt(r["first_seen_at"]),
      last_seen_at: dt(r["last_seen_at"])
    }
  end

  @doc "The stored dismissal reason of a finding, or nil."
  def dismiss_reason(server, id) do
    case call(
           server,
           &SQL.fetch_one(&1, "SELECT dismiss_reason FROM findings WHERE id = ?", [id])
         ) do
      %{"dismiss_reason" => r} -> r
      nil -> nil
    end
  end

  # ── PM runs ──────────────────────────────────────────────────────────────

  @doc """
  Records a PM run (insert, or replace by `:id` so a run can be recorded at
  start and again when it finishes). Keys: `id` (generated when absent),
  `finding_id`, `started_at`, `finished_at`, `decision` (`%Decision{}`),
  `cost_usd`, `turns`, `session_id`, `sources` (list), `error`.
  """
  @spec record_pm_run(GenServer.server(), map()) :: {:ok, String.t()}
  def record_pm_run(server, %{} = run) do
    id = run[:id] || new_id("pm")

    :ok =
      call(server, fn conn ->
        SQL.exec(
          conn,
          """
          INSERT OR REPLACE INTO pm_runs (id, finding_id, started_at, finished_at, decision_json,
            cost_usd, turns, session_id, sources_json, error)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            id,
            run[:finding_id],
            iso(run[:started_at]),
            iso(run[:finished_at]),
            run[:decision] && encode(Map.from_struct(run[:decision])),
            run[:cost_usd] && run[:cost_usd] * 1.0,
            run[:turns],
            run[:session_id],
            encode(run[:sources] || []),
            run[:error]
          ]
        )
      end)

    {:ok, id}
  end

  @doc "A finding's PM runs, oldest first, with `decision` decoded to `%Decision{}`."
  @spec list_pm_runs(GenServer.server(), String.t()) :: [map()]
  def list_pm_runs(server, finding_id) do
    call(
      server,
      &SQL.fetch_all(&1, "SELECT * FROM pm_runs WHERE finding_id = ? ORDER BY started_at, id", [
        finding_id
      ])
    )
    |> Enum.map(fn r ->
      %{
        id: r["id"],
        finding_id: r["finding_id"],
        started_at: dt(r["started_at"]),
        finished_at: dt(r["finished_at"]),
        decision: decode_decision(r["decision_json"]),
        cost_usd: r["cost_usd"],
        turns: r["turns"],
        session_id: r["session_id"],
        sources: decode(r["sources_json"]) || [],
        error: r["error"]
      }
    end)
  end

  @doc "How many PM runs a finding has had."
  def count_pm_runs(server, finding_id) do
    %{"n" => n} =
      call(
        server,
        &SQL.fetch_one(&1, "SELECT COUNT(*) AS n FROM pm_runs WHERE finding_id = ?", [finding_id])
      )

    n
  end

  @doc """
  Today's PM spend in USD (runs started on `now`'s UTC date), for one project
  root (through its findings) or for the whole fleet (`:fleet`).
  """
  @spec spend_today(GenServer.server(), String.t() | :fleet, DateTime.t()) :: float()
  def spend_today(server, scope, %DateTime{} = now) do
    {from, to} = day_bounds(now)

    {sql, params} =
      case scope do
        :fleet ->
          {"SELECT COALESCE(SUM(cost_usd), 0.0) AS s FROM pm_runs WHERE started_at >= ? AND started_at < ?",
           [from, to]}

        root when is_binary(root) ->
          {"""
           SELECT COALESCE(SUM(r.cost_usd), 0.0) AS s FROM pm_runs r
           JOIN findings f ON f.id = r.finding_id
           WHERE f.project_root = ? AND r.started_at >= ? AND r.started_at < ?
           """, [root, from, to]}
      end

    %{"s" => s} = call(server, &SQL.fetch_one(&1, sql, params))
    s * 1.0
  end

  defp day_bounds(now) do
    date = now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date()
    from = DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
    {iso(from), iso(DateTime.add(from, 86_400))}
  end

  defp decode_decision(nil), do: nil

  defp decode_decision(json) do
    m = json |> decode() |> atomize()

    struct(Decision, m)
    |> Map.update!(:action, &to_atom(&1, ~w(unblock answer reassign resume wait escalate)a, nil))
    |> Map.update!(:confidence, &to_atom(&1, ~w(low medium high)a, :medium))
  end

  # ── nudges ───────────────────────────────────────────────────────────────

  @doc """
  Records a nudge. Keys: `id` (generated when absent), `finding_id`,
  `session_id`, `text`, `adapter`, `state`, `created_at`, `delivered_at`,
  `outcome`, `outcome_at`.
  """
  @spec record_nudge(GenServer.server(), map()) :: {:ok, String.t()}
  def record_nudge(server, %{} = n) do
    id = n[:id] || new_id("n")

    :ok =
      call(server, fn conn ->
        SQL.exec(
          conn,
          """
          INSERT INTO nudges (id, finding_id, session_id, text, adapter, state, created_at,
            delivered_at, outcome, outcome_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            id,
            n[:finding_id],
            n[:session_id],
            n[:text],
            str(n[:adapter]),
            str(n[:state] || :pending),
            iso(n[:created_at]),
            iso(n[:delivered_at]),
            str(n[:outcome]),
            iso(n[:outcome_at])
          ]
        )
      end)

    {:ok, id}
  end

  @nudge_updatable [:state, :adapter, :delivered_at, :outcome, :outcome_at, :text]

  @doc "Updates a nudge's `state`, `adapter`, `text`, `delivered_at`, `outcome`, `outcome_at`."
  @spec update_nudge(GenServer.server(), String.t(), map()) :: :ok
  def update_nudge(server, id, %{} = changes) do
    changes = Map.take(changes, @nudge_updatable)

    if changes == %{} do
      :ok
    else
      {sets, params} =
        changes
        |> Enum.sort()
        |> Enum.map(fn {k, v} -> {"#{k} = ?", db_value(v)} end)
        |> Enum.unzip()

      call(
        server,
        &SQL.exec(&1, "UPDATE nudges SET #{Enum.join(sets, ", ")} WHERE id = ?", params ++ [id])
      )
    end
  end

  @doc "Nudges, oldest first. Options: `session_id:`, `finding_id:`."
  def list_nudges(server, opts \\ []) do
    {where, params} =
      Enum.reduce(opts, {["1 = 1"], []}, fn
        {:session_id, v}, {w, p} -> {["session_id = ?" | w], p ++ [v]}
        {:finding_id, v}, {w, p} -> {["finding_id = ?" | w], p ++ [v]}
        _, acc -> acc
      end)

    call(
      server,
      &SQL.fetch_all(
        &1,
        "SELECT * FROM nudges WHERE #{Enum.join(where, " AND ")} ORDER BY created_at, id",
        params
      )
    )
    |> Enum.map(fn r ->
      %{
        id: r["id"],
        finding_id: r["finding_id"],
        session_id: r["session_id"],
        text: r["text"],
        adapter: r["adapter"],
        state: r["state"],
        created_at: dt(r["created_at"]),
        delivered_at: dt(r["delivered_at"]),
        outcome: r["outcome"],
        outcome_at: dt(r["outcome_at"])
      }
    end)
  end

  @doc """
  The `ledger` `Sprat.PM.Policy.authorize/2` reads, for one finding:
  last delivery and delivered texts per session, the finding's PM run count,
  and the finding ids already given an `answer` that was delivered.
  """
  @spec policy_ledger(GenServer.server(), String.t()) :: map()
  def policy_ledger(server, finding_id) do
    delivered =
      call(
        server,
        &SQL.fetch_all(
          &1,
          "SELECT finding_id, session_id, text, delivered_at FROM nudges WHERE delivered_at IS NOT NULL"
        )
      )

    answered =
      call(
        server,
        &SQL.fetch_all(&1, """
        SELECT DISTINCT r.finding_id FROM pm_runs r
        JOIN nudges n ON n.finding_id = r.finding_id AND n.delivered_at IS NOT NULL
        WHERE json_extract(r.decision_json, '$.action') = 'answer'
        """)
      )

    %{
      last_delivery_at_by_session:
        delivered
        |> Enum.group_by(& &1["session_id"], & &1["delivered_at"])
        |> Map.new(fn {sid, ats} -> {sid, ats |> Enum.max() |> dt()} end),
      sent_texts_by_session: Enum.group_by(delivered, & &1["session_id"], & &1["text"]),
      pm_runs_for_finding: count_pm_runs(server, finding_id),
      answers_given: MapSet.new(answered, & &1["finding_id"])
    }
  end

  # ── roadmap writes ───────────────────────────────────────────────────────

  @doc """
  Records a roadmap write. Keys: `id` (generated when absent), `project_root`,
  `item_id`, `from_state`, `to_state`, `reason`, `pm_run_id`, `at`.
  """
  @spec record_write(GenServer.server(), map()) :: {:ok, String.t()}
  def record_write(server, %{} = w) do
    id = w[:id] || new_id("w")

    :ok =
      call(server, fn conn ->
        SQL.exec(
          conn,
          """
          INSERT INTO roadmap_writes (id, project_root, item_id, from_state, to_state, reason, pm_run_id, at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
          [
            id,
            w[:project_root],
            w[:item_id],
            str(w[:from_state]),
            str(w[:to_state]),
            w[:reason],
            w[:pm_run_id],
            iso(w[:at])
          ]
        )
      end)

    {:ok, id}
  end

  @doc "Marks a roadmap write reverted (`u`). Returns `{:error, :not_found}` for an unknown id."
  @spec mark_reverted(GenServer.server(), String.t(), DateTime.t()) :: :ok | {:error, :not_found}
  def mark_reverted(server, id, %DateTime{} = at) do
    call(server, fn conn ->
      case SQL.fetch_one(conn, "SELECT id FROM roadmap_writes WHERE id = ?", [id]) do
        nil ->
          {:error, :not_found}

        _ ->
          SQL.exec(conn, "UPDATE roadmap_writes SET reverted_at = ? WHERE id = ?", [iso(at), id])
      end
    end)
  end

  @doc "A project's roadmap writes, oldest first."
  def list_writes(server, project_root) do
    call(
      server,
      &SQL.fetch_all(&1, "SELECT * FROM roadmap_writes WHERE project_root = ? ORDER BY at, id", [
        project_root
      ])
    )
    |> Enum.map(fn r ->
      %{
        id: r["id"],
        project_root: r["project_root"],
        item_id: r["item_id"],
        from_state: r["from_state"],
        to_state: r["to_state"],
        reason: r["reason"],
        pm_run_id: r["pm_run_id"],
        at: dt(r["at"]),
        reverted_at: dt(r["reverted_at"])
      }
    end)
  end

  # ── accounts ─────────────────────────────────────────────────────────────

  @doc "Stores an account's limit state and resume queue."
  @spec put_account(GenServer.server(), Account.t()) :: :ok
  def put_account(server, %Account{} = a) do
    call(server, fn conn ->
      SQL.exec(
        conn,
        """
        INSERT OR REPLACE INTO accounts (config_dir, limited_until, limit_kind, limit_text, resume_queue_json, login, limited_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          a.config_dir,
          iso(a.limited_until),
          str(a.limit_kind),
          a.limit_text,
          encode(a.resume_queue || []),
          a.login,
          iso(a.limited_at)
        ]
      )
    end)
  end

  @doc "Every stored account."
  @spec get_accounts(GenServer.server()) :: [Account.t()]
  def get_accounts(server) do
    call(server, &SQL.fetch_all(&1, "SELECT * FROM accounts ORDER BY config_dir"))
    |> Enum.map(fn r ->
      %Account{
        config_dir: r["config_dir"],
        limited_until: dt(r["limited_until"]),
        limit_kind: to_atom(r["limit_kind"], ~w(five_hour session weekly)a, nil),
        limit_text: r["limit_text"],
        resume_queue: decode(r["resume_queue_json"]) || [],
        login: r["login"],
        limited_at: dt(r["limited_at"])
      }
    end)
  end

  # ── served ───────────────────────────────────────────────────────────────

  @doc "Records one served-today line, under the project root it belongs to."
  @spec record_served(GenServer.server(), Served.t(), String.t() | nil) :: {:ok, String.t()}
  def record_served(server, %Served{} = s, project_root \\ nil) do
    id = new_id("sv")

    :ok =
      call(server, fn conn ->
        SQL.exec(
          conn,
          "INSERT INTO served (id, at, project_root, project_name, text, by, ref) VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            id,
            iso(s.at),
            project_root,
            s.project_name,
            s.text,
            str(s.by),
            s.ref && to_string(s.ref)
          ]
        )
      end)

    {:ok, id}
  end

  @doc "Served lines at or after `since`, newest first."
  @spec served_since(GenServer.server(), DateTime.t()) :: [Served.t()]
  def served_since(server, %DateTime{} = since) do
    call(
      server,
      &SQL.fetch_all(&1, "SELECT * FROM served WHERE at >= ? ORDER BY at DESC, id", [iso(since)])
    )
    |> Enum.map(fn r ->
      %Served{
        at: dt(r["at"]),
        project_name: r["project_name"],
        text: r["text"],
        by: to_atom(r["by"], [:sprat, :owner, :you], :sprat),
        ref: r["ref"]
      }
    end)
  end

  # ── settings and events ──────────────────────────────────────────────────

  @doc "Stores a JSON-encodable setting."
  def put_setting(server, key, value) do
    call(server, fn conn ->
      SQL.exec(conn, "INSERT OR REPLACE INTO settings (key, value_json) VALUES (?, ?)", [
        to_string(key),
        encode(value)
      ])
    end)
  end

  @doc "A setting's value (JSON-decoded, string keys), or `default`."
  def get_setting(server, key, default \\ nil) do
    case call(
           server,
           &SQL.fetch_one(&1, "SELECT value_json FROM settings WHERE key = ?", [to_string(key)])
         ) do
      %{"value_json" => json} -> decode(json)
      nil -> default
    end
  end

  @doc "Appends an event to the log. Returns its autoincrement id."
  @spec log_event(GenServer.server(), atom() | String.t(), map(), DateTime.t()) ::
          {:ok, integer()}
  def log_event(server, type, data \\ %{}, at \\ DateTime.utc_now()) do
    call(server, fn conn ->
      :ok =
        SQL.exec(conn, "INSERT INTO events (at, type, data_json) VALUES (?, ?, ?)", [
          iso(at),
          to_string(type),
          encode(data)
        ])

      %{"id" => id} = SQL.fetch_one(conn, "SELECT last_insert_rowid() AS id")
      {:ok, id}
    end)
  end

  @doc "Events in id order. Options: `type:`, `since:` (DateTime)."
  def list_events(server, opts \\ []) do
    {where, params} =
      Enum.reduce(opts, {["1 = 1"], []}, fn
        {:type, v}, {w, p} -> {["type = ?" | w], p ++ [to_string(v)]}
        {:since, v}, {w, p} -> {["at >= ?" | w], p ++ [iso(v)]}
        _, acc -> acc
      end)

    call(
      server,
      &SQL.fetch_all(
        &1,
        "SELECT * FROM events WHERE #{Enum.join(where, " AND ")} ORDER BY id",
        params
      )
    )
    |> Enum.map(fn r ->
      %{id: r["id"], at: dt(r["at"]), type: r["type"], data: decode(r["data_json"])}
    end)
  end

  # ── encoding ─────────────────────────────────────────────────────────────

  @doc false
  def iso(nil), do: nil

  def iso(%DateTime{} = d) do
    d = DateTime.shift_zone!(d, "Etc/UTC")
    {us, _} = d.microsecond
    DateTime.to_iso8601(%{d | microsecond: {us, 6}})
  end

  defp dt(nil), do: nil

  defp dt(s) when is_binary(s) do
    # Whole seconds come back with precision 0 so they equal `~U[... :00Z]`.
    case DateTime.from_iso8601(s) do
      {:ok, %DateTime{microsecond: {0, _}} = d, _} -> %{d | microsecond: {0, 0}}
      {:ok, d, _} -> d
      _ -> nil
    end
  end

  defp bool(true), do: 1
  defp bool(_), do: 0

  defp str(nil), do: nil
  defp str(v), do: to_string(v)

  defp db_value(%DateTime{} = d), do: iso(d)
  defp db_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v), do: to_string(v)
  defp db_value(v), do: v

  defp to_atom(nil, _allowed, default), do: default
  defp to_atom(v, allowed, default) when is_atom(v), do: if(v in allowed, do: v, else: default)

  defp to_atom(v, allowed, default) when is_binary(v),
    do: Enum.find(allowed, default, &(Atom.to_string(&1) == v))

  defp encode(term), do: term |> jsonable() |> JSON.encode!()

  defp decode(nil), do: nil
  defp decode(json), do: JSON.decode!(json)

  defp jsonable(%DateTime{} = d), do: iso(d)
  defp jsonable(%MapSet{} = s), do: s |> MapSet.to_list() |> jsonable()
  defp jsonable(%_{} = s), do: s |> Map.from_struct() |> jsonable()
  defp jsonable(%{} = m), do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  defp jsonable(v), do: v

  @iso_re ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/

  # Decoded JSON back to atom keys (existing atoms only) and DateTimes.
  defp atomize(%{} = m) do
    Map.new(m, fn {k, v} ->
      key =
        try do
          String.to_existing_atom(k)
        rescue
          ArgumentError -> k
        end

      {key, atomize(v)}
    end)
  end

  defp atomize(l) when is_list(l), do: Enum.map(l, &atomize/1)

  defp atomize(s) when is_binary(s) do
    if Regex.match?(@iso_re, s), do: dt(s), else: s
  end

  defp atomize(v), do: v

  defp new_id(prefix),
    do: prefix <> "-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
end
