defmodule Sprat.Engine.Socket do
  @moduledoc """
  The daemon's door for boards (spec-v5 §6): a Unix socket at
  `<data>/v4/sprat.sock`, readable only by its owner (0600). Not Erlang
  distribution: that would need `epmd` listening on the network and a
  shared cookie; a socket file keeps everything on this machine, for this
  user.

  Frames are 4-byte-length-prefixed Erlang terms. A board sends
  `{:call, ref, request}` and gets `{:reply, ref, result}`; requests are
  `:snapshot`, `{:command, cmd}` and `:subscribe` (then every published
  snapshot arrives as `{:snapshot, snap}`).

  One process per connected board (`Sprat.Engine.Socket.Conn`); each command
  runs in its own task, so a slow one never holds up the board's other
  requests or its pushes.
  """

  use GenServer
  require Logger

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    # Connections are linked to the listener: when it stops, every board's
    # connection closes and the boards notice. One connection crashing
    # stops only that one.
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(opts, :path)
    File.rm(path)
    File.mkdir_p!(Path.dirname(path))

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, String.to_charlist(path)},
        packet: 4,
        active: false,
        reuseaddr: true
      ])

    File.chmod!(path, 0o600)
    server = self()
    acceptor = spawn_link(fn -> accept(listen, server) end)

    {:ok,
     %{
       listen: listen,
       path: path,
       acceptor: acceptor,
       engine: Keyword.get(opts, :engine, Sprat.Engine),
       publisher: Keyword.get(opts, :publisher, Sprat.Engine.Publisher),
       conns: %{}
     }}
  end

  @impl true
  def handle_info({:accepted, sock}, state) do
    {:ok, pid} =
      Sprat.Engine.Socket.Conn.start_link(sock, engine: state.engine, publisher: state.publisher)

    :ok = :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    ref = Process.monitor(pid)
    {:noreply, %{state | conns: Map.put(state.conns, ref, pid)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, state),
    do: {:noreply, %{state | conns: Map.delete(state.conns, ref)}}

  def handle_info({:EXIT, pid, reason}, %{acceptor: pid} = state), do: {:stop, reason, state}
  def handle_info({:EXIT, _conn, _reason}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
    :ok
  end

  defp accept(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        :ok = :gen_tcp.controlling_process(sock, server)
        send(server, {:accepted, sock})
        accept(listen, server)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("sprat socket: accept failed: #{inspect(reason)}")
        Process.sleep(200)
        accept(listen, server)
    end
  end

  defmodule Conn do
    @moduledoc "One connected board: its requests, its subscription, its pushes."
    use GenServer, restart: :temporary

    @command_timeout 35_000

    def start_link(sock, opts), do: GenServer.start_link(__MODULE__, {sock, opts})

    @impl true
    def init({sock, opts}) do
      Sprat.Engine.ProcessMap.label("a board")
      Sprat.Engine.ProcessMap.ref(:board)
      {:ok, %{sock: sock, engine: opts[:engine], publisher: opts[:publisher]}}
    end

    @impl true
    def handle_info(:go, state) do
      :inet.setopts(state.sock, active: :once)
      {:noreply, state}
    end

    def handle_info({:tcp, sock, bin}, state) do
      :inet.setopts(sock, active: :once)

      case decode(bin) do
        {:call, ref, request} -> {:noreply, handle_request(ref, request, state)}
        _ -> {:noreply, state}
      end
    end

    def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
    def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

    def handle_info({:sprat_snapshot, snap}, state) do
      send_frame(state.sock, {:snapshot, snap})
      Sprat.Engine.ProcessMap.did("sent the change to its board")
      {:noreply, state}
    end

    def handle_info({:reply, ref, result}, state) do
      send_frame(state.sock, {:reply, ref, result})
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp handle_request(ref, :subscribe, state) do
      Sprat.Engine.Publisher.subscribe(state.publisher, self())
      send_frame(state.sock, {:reply, ref, :ok})
      state
    end

    defp handle_request(ref, request, state) do
      conn = self()
      engine = state.engine

      Task.start(fn ->
        result =
          try do
            case request do
              :snapshot ->
                Sprat.Engine.snapshot(engine)

              # Read here: the engine is one of the processes being drawn.
              {:command, :process_map} ->
                {:ok, {:process_map, Sprat.Engine.ProcessMap.snapshot()}}

              {:command, cmd} ->
                GenServer.call(engine, {:command, cmd}, @command_timeout)

              _ ->
                {:error, "unknown request"}
            end
          catch
            :exit, {:timeout, _} -> {:error, "Sprat is busy; try again in a moment."}
            :exit, reason -> {:error, "sprat serve: #{inspect(reason, limit: 3)}"}
          end

        send(conn, {:reply, ref, result})
      end)

      state
    end

    defp send_frame(sock, term), do: :gen_tcp.send(sock, :erlang.term_to_binary(term))

    defp decode(bin) do
      :erlang.binary_to_term(bin, [:safe])
    rescue
      _ -> nil
    end
  end
end
