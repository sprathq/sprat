defmodule Sprat.Store.Runs do
  @moduledoc """
  Run evidence (docs/spec-v2.md §10, migration 5): every execution
  `Sprat.Agent.Tools.Shell` (or another build-phase tool) performs is
  recorded here — command, args, cwd, exit code, duration, where its
  captured output lives in the blob store, whether it was truncated,
  whether it ran with network enabled, the sandbox strength actually
  achieved, and its `purpose`. This is the evidence the build gates check
  (§10 "Verification is the product"); treat it with the same care
  `Sprat.Store.Sources` gets for research.
  """

  alias Sprat.Store.{Blob, SQL}

  @purposes ~w(install test run health_check lint other)
  @sandbox_strengths ~w(enforced partial none)

  defstruct [
    :id,
    :mission_id,
    :task_id,
    :command,
    :args,
    :cwd,
    :exit_code,
    :duration_ms,
    :output_blob_hash,
    :truncated,
    :network,
    :sandbox_strength,
    :purpose,
    :created_at
  ]

  @doc "Valid `purpose` values."
  def purposes, do: @purposes

  @doc "Valid `sandbox_strength` values."
  def sandbox_strengths, do: @sandbox_strengths

  @doc """
  Records one run. `attrs` requires `:mission_id`, `:command`, `:args`
  (a list of strings), `:cwd`, `:duration_ms`, `:sandbox_strength`
  (`"enforced" | "partial" | "none"`) and `:purpose` (one of
  #{inspect(@purposes)}). Optional: `:task_id`, `:exit_code`,
  `:output_blob_hash`, `:truncated`, `:network`.
  """
  def record(store \\ Sprat.Store, attrs) do
    validate!(attrs)
    {:ok, run} = Sprat.Store.transact(store, fn conn -> record_in_conn(conn, attrs) end)
    run
  end

  defp validate!(attrs) do
    sandbox_strength = Map.fetch!(attrs, :sandbox_strength)
    purpose = Map.fetch!(attrs, :purpose)

    unless sandbox_strength in @sandbox_strengths do
      raise ArgumentError, "invalid sandbox_strength: #{inspect(sandbox_strength)}"
    end

    unless purpose in @purposes do
      raise ArgumentError, "invalid purpose: #{inspect(purpose)}"
    end

    :ok
  end

  def record_in_conn(conn, attrs) do
    :ok = validate!(attrs)

    run = %__MODULE__{
      id: attrs[:id] || generate_id(),
      mission_id: Map.fetch!(attrs, :mission_id),
      task_id: attrs[:task_id],
      command: Map.fetch!(attrs, :command),
      args: Map.fetch!(attrs, :args),
      cwd: Map.fetch!(attrs, :cwd),
      exit_code: attrs[:exit_code],
      duration_ms: Map.fetch!(attrs, :duration_ms),
      output_blob_hash: attrs[:output_blob_hash],
      truncated: attrs[:truncated] || false,
      network: attrs[:network] || false,
      sandbox_strength: Map.fetch!(attrs, :sandbox_strength),
      purpose: Map.fetch!(attrs, :purpose),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    SQL.exec(
      conn,
      """
      INSERT INTO runs
        (id, mission_id, task_id, command, args, cwd, exit_code, duration_ms,
         output_blob_hash, truncated, network, sandbox_strength, purpose, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
      """,
      [
        run.id,
        run.mission_id,
        run.task_id,
        run.command,
        JSON.encode!(run.args),
        run.cwd,
        run.exit_code,
        run.duration_ms,
        run.output_blob_hash,
        bool_to_int(run.truncated),
        bool_to_int(run.network),
        run.sandbox_strength,
        run.purpose,
        run.created_at
      ]
    )

    run
  end

  @doc "All runs for a mission, oldest first."
  def by_mission(store \\ Sprat.Store, mission_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM runs WHERE mission_id = ?1 ORDER BY created_at ASC", [
      mission_id
    ])
    |> Enum.map(&row_to_run/1)
  end

  @doc "All runs for a task, oldest first."
  def by_task(store \\ Sprat.Store, task_id) do
    store
    |> Sprat.Store.fetch_all("SELECT * FROM runs WHERE task_id = ?1 ORDER BY created_at ASC", [
      task_id
    ])
    |> Enum.map(&row_to_run/1)
  end

  @doc """
  `by_mission/2`, with each run's captured output resolved from the blob
  store and attached as `:output` — the Inspector's Runs tab needs the
  full command/args/cwd/exit/duration up front (`by_mission/2` already has
  those) but the Detail card additionally needs the captured output text,
  same split `Sprat.Store.Artifacts.by_mission_with_content/2` has for
  artifacts. A run with no `output_blob_hash` (nothing captured) or a
  blob that's gone missing gets `output: nil` rather than raising — the
  caller renders that as "output not available", never a crash.
  """
  def by_mission_with_output(store \\ Sprat.Store, mission_id) do
    store
    |> by_mission(mission_id)
    |> Enum.map(fn run ->
      run
      |> Map.from_struct()
      |> Map.put(:output, resolve_output(run.output_blob_hash))
    end)
  end

  defp resolve_output(nil), do: nil

  defp resolve_output(hash) do
    case Blob.get(hash) do
      {:ok, bytes} -> bytes
      {:error, :not_found} -> nil
    end
  end

  defp row_to_run(row) do
    %__MODULE__{
      id: row["id"],
      mission_id: row["mission_id"],
      task_id: row["task_id"],
      command: row["command"],
      args: JSON.decode!(row["args"]),
      cwd: row["cwd"],
      exit_code: row["exit_code"],
      duration_ms: row["duration_ms"],
      output_blob_hash: row["output_blob_hash"],
      truncated: row["truncated"] == 1,
      network: row["network"] == 1,
      sandbox_strength: row["sandbox_strength"],
      purpose: row["purpose"],
      created_at: row["created_at"]
    }
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp generate_id,
    do: "run_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
end
