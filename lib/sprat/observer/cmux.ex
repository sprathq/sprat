defmodule Sprat.Observer.Cmux do
  @moduledoc """
  Maps live Claude processes to their cmux surfaces (`cmux top`) every 15
  seconds, in its own process, borrowing cmux access when refused (see
  `Sprat.Observer.Surfaces`). Publishes `{surfaces, status}` to
  `Sprat.Observer.Live` (`:cmux`); a failed scan keeps the surfaces already
  known. Status: `:ok`, `:absent` (no cmux), `:denied`, `:failed`.
  """

  use GenServer
  require Logger

  alias Sprat.Observer.{Live, Surfaces}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last `{surfaces, status}`, or nil before the first scan."
  def latest, do: Live.get(:cmux, :latest)

  @impl true
  def init(opts) do
    send(self(), :scan)
    {:ok, %{opts: opts, surfaces: %{}, status: nil}}
  end

  @impl true
  def handle_info(:scan, state) do
    pids = Live.get(:sessions, :pids)

    # cmux answers only processes it started; Sprat borrows the access of a
    # live Claude session (`Surfaces.scan/1`), so it waits for the session
    # scan's first pids rather than report "refused" on start.
    if is_nil(pids) and state.status == nil and not Keyword.has_key?(state.opts, :surfaces_fun) do
      Process.send_after(self(), :scan, 500)
      {:noreply, state}
    else
      Process.send_after(self(), :scan, Keyword.get(state.opts, :cmux_ms, 15_000))
      scan(state, pids || [])
    end
  end

  defp scan(state, pids) do
    scan =
      Keyword.get(state.opts, :surfaces_fun, fn -> Surfaces.scan(pids: pids) end)

    {surfaces, status} =
      case scan.() do
        {:ok, m} -> {m, :ok}
        {:error, :no_cmux} -> {%{}, :absent}
        {:error, reason} -> {state.surfaces, reason}
        m when is_map(m) -> {m, :ok}
      end

    Live.put(:cmux, :latest, {surfaces, status})

    if state.status && status != state.status do
      Sprat.Activity.emit(:observer,
        text: "cmux: " <> describe(status),
        status: if(status == :ok, do: :ok, else: :failed)
      )
    end

    {:noreply, %{state | surfaces: surfaces, status: status}}
  rescue
    e ->
      Logger.error("sprat cmux: " <> Exception.message(e))
      {:noreply, state}
  end

  defp describe(:ok), do: "answering again"
  defp describe(:absent), do: "not installed"
  defp describe(:denied), do: "refused sprat (no access)"
  defp describe(other), do: "not answering (#{inspect(other)})"
end
