defmodule Sprat.Engine.Remote do
  @moduledoc """
  The board's line to `sprat serve` (spec-v5 §6): connects to its Unix
  socket, subscribes, and keeps the latest snapshot it pushed. Each push
  wakes the board (`{:sprat_update}` to the listener) so a change shows the
  moment the daemon publishes it, not on the next poll.

  Commands go over the same socket and wait for their reply in the caller,
  not in this process, so pushes keep arriving while a command runs.

  If the socket closes (the daemon restarts), `snapshot/1` answers with the
  last snapshot marked stale (`:daemon_warning`), and the client reconnects
  every second.
  """

  use GenServer
  require Logger

  @reconnect_ms 1_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Connects now; `{:error, reason}` when no daemon listens on `path`."
  def start(opts) do
    case connect(Keyword.fetch!(opts, :path)) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        start_link(opts)

      error ->
        error
    end
  end

  @doc "The latest snapshot (nil before the first)."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot, 5_000)

  @doc "Runs a board command in the daemon and waits for its reply."
  def command(server \\ __MODULE__, cmd, timeout \\ 36_000) do
    case GenServer.call(server, {:send, {:command, cmd}}, 5_000) do
      {:ok, ref} ->
        receive do
          {:sprat_reply, ^ref, result} -> result
        after
          timeout -> {:error, "sprat serve did not answer in #{div(timeout, 1000)}s."}
        end

      {:error, why} ->
        {:error, why}
    end
  end

  @doc "`pid` gets `{:sprat_update}` whenever a new snapshot arrives."
  def listen(server \\ __MODULE__, pid), do: GenServer.cast(server, {:listen, pid})

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.fetch!(opts, :path),
      sock: nil,
      snap: nil,
      listeners: [],
      waiting: %{},
      connected?: false,
      lost_at: nil
    }

    {:ok, open(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, with_warning(state), state}

  def handle_call({:send, request}, {pid, _}, %{sock: sock} = state) when sock != nil do
    ref = make_ref()

    case :gen_tcp.send(sock, :erlang.term_to_binary({:call, ref, request})) do
      :ok -> {:reply, {:ok, ref}, %{state | waiting: Map.put(state.waiting, ref, pid)}}
      {:error, why} -> {:reply, {:error, "sprat serve is not reachable (#{inspect(why)})"}, state}
    end
  end

  def handle_call({:send, _request}, _from, state),
    do: {:reply, {:error, "sprat serve is restarting; try again in a moment."}, state}

  @impl true
  def handle_cast({:listen, pid}, state),
    do: {:noreply, %{state | listeners: [pid | state.listeners]}}

  @impl true
  def handle_info({:tcp, sock, bin}, state) do
    :inet.setopts(sock, active: :once)

    state =
      case decode(bin) do
        {:snapshot, snap} ->
          for pid <- state.listeners, do: send(pid, {:sprat_update})
          %{state | snap: snap}

        {:reply, ref, result} ->
          {pid, waiting} = Map.pop(state.waiting, ref)
          if pid, do: send(pid, {:sprat_reply, ref, result})
          %{state | waiting: waiting}

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _}, state), do: {:noreply, lost(state)}
  def handle_info({:tcp_error, _, _}, state), do: {:noreply, lost(state)}
  def handle_info(:reconnect, state), do: {:noreply, open(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  defp open(state) do
    case connect(state.path) do
      {:ok, sock} ->
        :gen_tcp.send(sock, :erlang.term_to_binary({:call, make_ref(), :subscribe}))
        :inet.setopts(sock, active: :once)
        %{state | sock: sock, connected?: true, lost_at: nil}

      {:error, _} ->
        Process.send_after(self(), :reconnect, @reconnect_ms)
        %{state | sock: nil, connected?: false, lost_at: state.lost_at || DateTime.utc_now()}
    end
  end

  # Commands in flight will not be answered: say so rather than leave the
  # board waiting out its timeout.
  defp lost(state) do
    for {ref, pid} <- state.waiting,
        do: send(pid, {:sprat_reply, ref, {:error, "sprat serve restarted; try again."}})

    for pid <- state.listeners, do: send(pid, {:sprat_update})
    Process.send_after(self(), :reconnect, @reconnect_ms)
    %{state | sock: nil, waiting: %{}, connected?: false, lost_at: DateTime.utc_now()}
  end

  defp with_warning(%{snap: nil}), do: nil
  defp with_warning(%{connected?: true, snap: snap}), do: Map.put(snap, :daemon_warning, nil)

  defp with_warning(%{snap: snap, lost_at: at}) do
    Map.put(
      snap,
      :daemon_warning,
      "lost sprat serve at #{Calendar.strftime(at, "%H:%M:%S")} UTC; reconnecting (see serve.log)"
    )
  end

  defp connect(path) do
    :gen_tcp.connect(
      {:local, String.to_charlist(path)},
      0,
      [:binary, packet: 4, active: false],
      2_000
    )
  end

  # The daemon is this user's own process behind a 0600 socket; snapshots
  # carry atoms `:safe` would refuse to create.
  defp decode(bin) do
    :erlang.binary_to_term(bin)
  rescue
    _ -> nil
  end
end
