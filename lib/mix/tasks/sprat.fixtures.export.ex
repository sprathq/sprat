defmodule Mix.Tasks.Sprat.Fixtures.Export do
  @moduledoc """
  Exports one mission's recorded `model.request`/`model.response` event
  pairs from a real Sprat data-dir SQLite database into an ordered replay
  fixture under `test/fixtures/missions/<mission_id>/` — the offline
  replay harness's raw material (see `Sprat.Model.Replay`).

  This ONLY reads the source database (opened read-only) and the blob
  store next to it, and only writes under `--out`; it never touches the
  app's own `Sprat.Store` or data dir, and makes no network call.

      mix sprat.fixtures.export --db "/path/to/sprat.db" --mission mis_abc123
      mix sprat.fixtures.export --db "/path/to/sprat.db" --mission mis_abc123 --out test/fixtures/missions

  Writes two files:

    * `exchanges.json` — an ordered array of `%{request:, response:}`
      pairs, one per model turn, in the exact shape `Sprat.Model.Replay`
      consumes: `request` mirrors what `Sprat.Agent.Loop` sent (for the
      adapter's own divergence check), `response` is what
      `Sprat.Model.stream/2` returned that turn.
    * `meta.json` — the mission's objective and id, for a replay test to
      seed its own `Sprat.Store.Missions.create/3` call with the same
      text a real run used.

  Every string in both files is scrubbed through `Sprat.Store.Redact`
  against every secret this run can find (`Sprat.Secrets.redaction_set/0`,
  plus this process's own `OPENAI_API_KEY`/`.env`/credential-store
  resolution — reading those is a local lookup, never a network call) and,
  as a backstop, any substring matching a live OpenAI-shaped key
  (`sk-...`, 20+ trailing chars) — so a fixture can never carry the
  owner's real key even if it slipped past the live redaction path when
  it was first recorded. `test/sprat/fixtures_export_test.exs` asserts
  this on every exported file.
  """
  @shortdoc "Export a mission's recorded model exchanges as an offline replay fixture"

  use Mix.Task

  alias Exqlite.Sqlite3
  alias Sprat.Store.{Redact, SQL}

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args, strict: [db: :string, mission: :string, out: :string])

    db_path = Keyword.fetch!(opts, :db)
    mission_id = Keyword.fetch!(opts, :mission)
    out_dir = Path.join(Keyword.get(opts, :out, "test/fixtures/missions"), mission_id)

    {:ok, conn} = Sqlite3.open(db_path, mode: :readonly)
    blobs_dir = Path.join(Path.dirname(db_path), "blobs/sha256")

    secrets = redaction_secrets()

    mission = fetch_mission(conn, mission_id)
    exchanges = fetch_exchanges(conn, mission_id, blobs_dir, secrets)

    :ok = Sqlite3.close(conn)

    if exchanges == [] do
      Mix.raise("no model.request/model.response pairs found for mission #{mission_id}")
    end

    File.mkdir_p!(out_dir)
    write_json!(Path.join(out_dir, "exchanges.json"), exchanges)
    write_json!(Path.join(out_dir, "meta.json"), redact(mission, secrets))

    Mix.shell().info("Exported #{length(exchanges)} exchange(s) for #{mission_id} to #{out_dir}")
  end

  # Every source this process can resolve a secret from, without a network
  # call: whatever `Sprat.Secrets.register/1` already put in the runtime
  # redaction set (nothing, in a bare `mix` invocation — this task never
  # boots `Sprat.Application`), plus this task's own local resolution of
  # the owner's actual key (env / .env / OS credential store — all local
  # lookups), so the export is defended even though it doesn't start the
  # app that would normally have called `register/1` at boot.
  defp redaction_secrets do
    resolved =
      case Sprat.Secrets.resolve() do
        {:ok, key, _source} -> [key]
        :error -> []
      end

    Enum.uniq(Sprat.Secrets.redaction_set() ++ resolved)
  end

  defp fetch_mission(conn, mission_id) do
    SQL.fetch_one(conn, "SELECT id, objective, status FROM missions WHERE id = ?1", [mission_id]) ||
      %{"id" => mission_id, "objective" => nil, "status" => nil}
  end

  defp fetch_exchanges(conn, mission_id, blobs_dir, secrets) do
    rows =
      SQL.fetch_all(
        conn,
        """
        SELECT seq, type, correlation_id, payload, payload_ref
        FROM events
        WHERE mission_id = ?1 AND type IN ('model.request', 'model.response')
        ORDER BY seq ASC
        """,
        [mission_id]
      )

    by_correlation =
      rows
      |> Enum.map(&Map.put(&1, "decoded", decode_payload(&1, blobs_dir)))
      |> Enum.group_by(& &1["correlation_id"])

    rows
    |> Enum.filter(&(&1["type"] == "model.response"))
    |> Enum.map(& &1["correlation_id"])
    |> Enum.uniq()
    |> Enum.map(fn correlation_id ->
      pair = Map.fetch!(by_correlation, correlation_id)
      request = Enum.find(pair, &(&1["type"] == "model.request"))
      response = Enum.find(pair, &(&1["type"] == "model.response"))

      %{
        "request" => request && redact(request["decoded"], secrets),
        "response" => redact(response["decoded"], secrets)
      }
    end)
  end

  defp decode_payload(%{"payload_ref" => ref}, blobs_dir) when is_binary(ref) do
    hash = String.replace_prefix(ref, "blob:sha256:", "")
    prefix = binary_part(hash, 0, 2)

    Path.join([blobs_dir, prefix, hash])
    |> File.read!()
    |> JSON.decode!()
  end

  defp decode_payload(%{"payload" => payload}, _blobs_dir) when is_binary(payload),
    do: JSON.decode!(payload)

  defp decode_payload(_row, _blobs_dir), do: nil

  defp redact(nil, _secrets), do: nil

  defp redact(term, secrets) do
    {scrubbed, _redacted?} = Redact.scrub(term, secrets)
    scrub_key_shaped_strings(scrubbed)
  end

  # Backstop beyond `Sprat.Store.Redact.scrub/2`'s exact-string match: a
  # generic OpenAI-shaped secret key pattern, in case the live key this
  # export process resolved differs from whatever key(s) actually recorded
  # the source database (e.g. exporting on a machine/session that rotated
  # keys since). `test/sprat/fixtures_export_test.exs` is the check that
  # this backstop actually holds.
  @key_pattern ~r/\bsk-[A-Za-z0-9_-]{20,}\b/

  defp scrub_key_shaped_strings(value) when is_binary(value),
    do: Regex.replace(@key_pattern, value, "[REDACTED]")

  defp scrub_key_shaped_strings(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, scrub_key_shaped_strings(v)} end)

  defp scrub_key_shaped_strings(value) when is_list(value),
    do: Enum.map(value, &scrub_key_shaped_strings/1)

  defp scrub_key_shaped_strings(value), do: value

  defp write_json!(path, term), do: File.write!(path, JSON.encode!(term))
end
