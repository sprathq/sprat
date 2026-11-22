defmodule Sprat.Store.Grants do
  @moduledoc """
  User grants (docs/spec-v1.md §9): "User grants specify action, resources,
  lifetime, and applicable mission. Reuse valid grants without repetitive
  prompts." `record/2` persists an approval decision from the fetch
  prompt; `valid?/3` is what `Sprat.Mission` consults before ever showing
  that prompt again.

  A grant's `resource_scope` is either `"url"` (exact URL only) or
  `"domain"` (exact host only — never a suffix/subdomain match: approving
  `example.com` never approves `sub.example.com`, matching the owner's
  explicit "must never widen silently" requirement).

  `lifetime` is `"session"` in this V1 build: every submission creates its
  own mission (`Sprat.Mission.start/3`), so a grant scoped to a single
  mission would be asked again on the very next message — useless in
  practice. `mission_id` is still recorded (which mission the grant was
  made in, for the audit trail / a future multi-mission product), but
  validity here is checked at the session level. `ponytail:` a real
  per-mission lifetime can be added later if V1 ever runs more than one
  mission concurrently per session.
  """

  alias Sprat.Store.SQL

  defstruct [
    :id,
    :session_id,
    :mission_id,
    :action,
    :resource,
    :resource_scope,
    :lifetime,
    :decision,
    :created_at
  ]

  @doc "Records a grant decision. `attrs`: :action, :resource, :resource_scope (\"url\"|\"domain\"), :lifetime (\"session\"), :decision (\"approved\"|\"denied\"), :mission_id."
  def record(store \\ Sprat.Store, session_id, attrs) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, session_id, attrs) end)
  end

  def record_in_conn(conn, session_id, attrs) do
    grant = %__MODULE__{
      id: attrs[:id] || generate_id(),
      session_id: session_id,
      mission_id: attrs[:mission_id],
      action: Map.fetch!(attrs, :action),
      resource: Map.fetch!(attrs, :resource),
      resource_scope: Map.fetch!(attrs, :resource_scope),
      lifetime: attrs[:lifetime] || "session",
      decision: Map.fetch!(attrs, :decision),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO grants
        (id, session_id, mission_id, tool, action, resource, resource_scope, scope, lifetime, decision, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """,
      [
        grant.id,
        grant.session_id,
        grant.mission_id,
        grant.action,
        grant.action,
        grant.resource,
        grant.resource_scope,
        grant.resource,
        grant.lifetime,
        grant.decision,
        grant.created_at
      ]
    )

    grant
  end

  @doc "All grants recorded for a session, newest first."
  def by_session(store \\ Sprat.Store, session_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM grants WHERE session_id = ?1 ORDER BY created_at DESC",
      [session_id]
    )
    |> Enum.map(&row_to_grant/1)
  end

  @doc """
  Whether `action` on exact `resource` (a URL when `resource_scope:
  "url"`, a host when `resource_scope: "domain"`) is already approved for
  `session_id` — an exact match only, never a substring/suffix match.
  """
  def approved?(store \\ Sprat.Store, session_id, action, resource_scope, resource) do
    store
    |> by_session(session_id)
    |> Enum.any?(fn g ->
      g.action == action and g.resource_scope == resource_scope and g.resource == resource and
        g.decision == "approved"
    end)
  end

  defp row_to_grant(row) do
    %__MODULE__{
      id: row["id"],
      session_id: row["session_id"],
      mission_id: row["mission_id"],
      action: row["action"],
      resource: row["resource"],
      resource_scope: row["resource_scope"],
      lifetime: row["lifetime"],
      decision: row["decision"],
      created_at: row["created_at"]
    }
  end

  defp generate_id,
    do: "grt_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
