defmodule Sprat.Engine.Publisher do
  @moduledoc """
  Publishes the engine's snapshot (spec-v5 §6): to every board subscribed
  over `Sprat.Engine.Socket`, the moment the engine says something changed,
  and to `<data>/v4/snapshot.etf` for boards that read the file.

  The engine casts `dirty/0` after a command, a job's step or outcome, and
  each tick; the publisher builds a snapshot at most every `@min_ms`, and at
  least once a second so a board's clock and ages keep moving. A snapshot
  identical to the last is not pushed again.

  If the engine stops answering for `@stuck_ms`, the publisher exits, which
  ends `sprat serve` so launchd starts a fresh one (the same rule the V4
  publish loop had).
  """

  use GenServer
  require Logger

  @every_ms 1_000
  @min_ms 100
  @stuck_ms 180_000

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Something changed in the engine: publish soon. A no-op without a publisher."
  def dirty(server \\ __MODULE__) do
    if pid = GenServer.whereis(server), do: send(pid, :dirty)
    :ok
  end

  @doc "Sends `{:sprat_snapshot, snapshot}` to `pid` now and on every change, until it exits."
  def subscribe(server \\ __MODULE__, pid), do: GenServer.call(server, {:subscribe, pid})

  @impl true
  def init(opts) do
    state = %{
      engine: Keyword.get(opts, :engine, Sprat.Engine),
      file: Keyword.get(opts, :file),
      snapshot_fun: Keyword.get(opts, :snapshot_fun),
      subscribers: %{},
      last: nil,
      last_snap: nil,
      ok_at: now_ms(),
      published_at: 0,
      pending?: false
    }

    send(self(), :publish)
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    if state.last_snap, do: send(pid, {:sprat_snapshot, state.last_snap})
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
  end

  @impl true
  def handle_info(:dirty, %{pending?: true} = state), do: {:noreply, state}

  def handle_info(:dirty, state) do
    wait = max(@min_ms - (now_ms() - state.published_at), 0)
    Process.send_after(self(), :publish_now, wait)
    {:noreply, %{state | pending?: true}}
  end

  def handle_info(:publish_now, state), do: {:noreply, publish(%{state | pending?: false})}

  def handle_info(:publish, state) do
    Process.send_after(self(), :publish, @every_ms)
    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp publish(state) do
    case snapshot(state) do
      {:ok, snap} ->
        snap = Map.put(snap, :published_at, DateTime.utc_now())
        bin = :erlang.term_to_binary(Map.delete(snap, :published_at))

        if bin != state.last do
          write_file(state.file, snap)
          for pid <- Map.keys(state.subscribers), do: send(pid, {:sprat_snapshot, snap})

          Sprat.Engine.ProcessMap.did(
            case map_size(state.subscribers) do
              0 -> "updated the board file"
              1 -> "pushed a change to 1 board"
              n -> "pushed a change to #{n} boards"
            end
          )
        end

        %{state | last: bin, last_snap: snap, ok_at: now_ms(), published_at: now_ms()}

      {:error, why} ->
        stuck = now_ms() - state.ok_at

        if stuck > @stuck_ms do
          exit({:engine_stuck, "the engine has not answered for #{div(stuck, 1000)}s (#{why})"})
        end

        Logger.warning(
          "sprat serve: the engine is busy (#{why}), #{div(stuck, 1000)}s without a snapshot"
        )

        state
    end
  end

  defp snapshot(%{snapshot_fun: fun}) when is_function(fun, 0), do: safe(fun)
  defp snapshot(state), do: safe(fn -> Sprat.Engine.snapshot(state.engine) end)

  defp safe(fun) do
    {:ok, fun.()}
  catch
    :exit, {:timeout, _} -> {:error, "timeout"}
    :exit, {:noproc, _} -> exit(:engine_not_running)
    :exit, reason -> {:error, inspect(reason, limit: 5)}
  end

  defp write_file(nil, _snap), do: :ok

  defp write_file(path, snap) do
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(snap))
    File.rename!(tmp, path)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
