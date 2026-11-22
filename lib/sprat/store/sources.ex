defmodule Sprat.Store.Sources do
  @moduledoc "CRUD for source records (docs/spec-v1.md §6), keyed for de-duplication by `canonical_url`."

  alias Sprat.Store.SQL

  defstruct [
    :id,
    :mission_id,
    :url,
    :canonical_url,
    :title,
    :publisher,
    :published_at,
    :retrieved_at,
    :source_type,
    :content_hash,
    :snapshot_blob_hash,
    :created_at
  ]

  @doc """
  Records a source, or returns the existing one if `mission_id` already has
  a source at this `canonical_url` (`attrs[:canonical_url]`, or `attrs.url`
  verbatim when the caller has no canonicalized form — see `record_source`'s
  moduledoc, which promises this de-duplication but never actually
  triggered it until this exact-match check was wired in). This is an
  exact-string match only: no URL canonicalization (stripping tracking
  params, trailing slash, etc.) happens anywhere yet, so
  `?utm=1`-decorated and bare variants of the same URL still record as two
  sources unless the caller already normalizes `canonical_url` itself.
  """
  def record(store \\ Sprat.Store, mission_id, attrs) do
    Sprat.Store.transact(store, fn conn -> record_in_conn(conn, mission_id, attrs) end)
  end

  def record_in_conn(conn, mission_id, attrs) do
    canonical_url = attrs[:canonical_url] || Map.fetch!(attrs, :url)

    case find_by_canonical_url_in_conn(conn, mission_id, canonical_url) do
      %__MODULE__{} = existing ->
        existing

      nil ->
        insert_in_conn(conn, mission_id, attrs, canonical_url)
    end
  end

  defp insert_in_conn(conn, mission_id, attrs, canonical_url) do
    source = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: mission_id,
      url: Map.fetch!(attrs, :url),
      canonical_url: canonical_url,
      title: attrs[:title],
      publisher: attrs[:publisher],
      published_at: attrs[:published_at],
      retrieved_at: attrs[:retrieved_at] || DateTime.utc_now() |> DateTime.to_iso8601(),
      source_type: Map.fetch!(attrs, :source_type),
      content_hash: attrs[:content_hash],
      snapshot_blob_hash: attrs[:snapshot_blob_hash],
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO sources
        (id, mission_id, url, canonical_url, title, publisher, published_at,
         retrieved_at, source_type, content_hash, snapshot_blob_hash, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
      """,
      [
        source.id,
        source.mission_id,
        source.url,
        source.canonical_url,
        source.title,
        source.publisher,
        source.published_at,
        source.retrieved_at,
        source.source_type,
        source.content_hash,
        source.snapshot_blob_hash,
        source.created_at
      ]
    )

    source
  end

  @doc "Finds an existing source by canonical URL within a mission, for de-duplication."
  def find_by_canonical_url(store \\ Sprat.Store, mission_id, canonical_url),
    do: Sprat.Store.call(store, &find_by_canonical_url_in_conn(&1, mission_id, canonical_url))

  # `record_in_conn/2` calls this directly (same `conn`, same transaction)
  # rather than the `store`-taking `find_by_canonical_url/3` above, which
  # would deadlock: `record/3` already holds `Sprat.Store`'s GenServer
  # mailbox via `transact/2`, and `find_by_canonical_url/3` would try to
  # `GenServer.call` right back into it.
  defp find_by_canonical_url_in_conn(conn, mission_id, canonical_url) do
    case SQL.fetch_one(
           conn,
           "SELECT * FROM sources WHERE mission_id = ?1 AND canonical_url = ?2",
           [mission_id, canonical_url]
         ) do
      nil -> nil
      row -> row_to_source(row)
    end
  end

  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all(
      "SELECT * FROM sources WHERE mission_id = ?1 ORDER BY created_at ASC",
      [mission_id]
    )
    |> Enum.map(&row_to_source/1)
  end

  defp row_to_source(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      url: row["url"],
      canonical_url: row["canonical_url"],
      title: row["title"],
      publisher: row["publisher"],
      published_at: row["published_at"],
      retrieved_at: row["retrieved_at"],
      source_type: row["source_type"],
      content_hash: row["content_hash"],
      snapshot_blob_hash: row["snapshot_blob_hash"],
      created_at: row["created_at"]
    }
  end

  defp generate_id,
    do: "src_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
