defmodule Sprat.SessionSupervisor do
  @moduledoc """
  `DynamicSupervisor` for `Sprat.Session` processes (docs/spec-v1.md §13
  supervision tree) — one child per open session id, started on demand by
  `open/2` rather than all at boot (V1 is one user, one session at a
  time, per project — §2 — but nothing here assumes only one is ever
  running, e.g. under `mix test`).
  """

  use DynamicSupervisor

  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Returns the already-running `Sprat.Session` for `session_id`, or starts
  one (passing `opts` through to `Sprat.Session.start_link/1`, e.g.
  `:store` for tests). Idempotent: safe to call whether or not the
  session is already open.
  """
  def open(session_id, opts \\ []), do: open(session_id, opts, 5)

  # `:via`-named `Sprat.Session.start_link/1` registers atomically through
  # `Registry.register/3`, so `{:error, {:already_started, pid}}` here is
  # authoritative — but `Registry` learns of a *dead* registrant only when
  # its own monitor delivers the `:DOWN` message, a moment after the
  # process actually exits (ponytail: a genuine but tiny lag, not a design
  # flaw — matters right after `DynamicSupervisor.terminate_child/2`, the
  # pattern a real crash-and-restart or these tests use). Retrying a
  # handful of times at 1ms rides out that lag without a synchronous
  # unregister handshake.
  defp open(session_id, opts, retries) do
    case DynamicSupervisor.start_child(
           __MODULE__,
           {Sprat.Session, Keyword.put(opts, :session_id, session_id)}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        cond do
          Process.alive?(pid) ->
            {:ok, pid}

          retries > 0 ->
            Process.sleep(1)
            open(session_id, opts, retries - 1)

          true ->
            {:error, :registry_stale}
        end
    end
  end
end
