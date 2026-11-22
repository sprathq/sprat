defmodule Sprat.Engine.Tracer do
  @moduledoc """
  Who sent messages to whom inside `sprat serve`, for the board's processes
  screen (`Sprat.Engine.ProcessMap`).

  Lazy: it traces only while someone is looking. Each `flows/2` asks for
  the next few seconds of samples; while asked, with a pause of `@every_ms` between samples, it traces
  the `send`s of Sprat's own processes for `@window_ms` through its own
  trace session (`:trace.session_create/3`, so it never disturbs another
  tracer), counts them per sender and receiver, and stops. Nobody looking:
  no tracing at all.
  """

  use GenServer

  @window_ms 400
  @every_ms 100
  @keep_alive_ms 3_000
  # A burst bigger than this is counted as this; the screen says "many".
  @max_events 5_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The messages counted in the last sample between `pids` (`ProcessMap`
  ids), and a request to keep sampling them. `[]` without a tracer.
  """
  def flows(server \\ __MODULE__, pids) do
    if GenServer.whereis(server), do: GenServer.call(server, {:flows, pids}, 2_000), else: []
  catch
    :exit, _ -> []
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       pids: [],
       until: 0,
       scheduled?: false,
       flows: [],
       window_ms: Keyword.get(opts, :window_ms, @window_ms),
       every_ms: Keyword.get(opts, :every_ms, @every_ms)
     }}
  end

  @impl true
  def handle_call({:flows, pids}, _from, state) do
    state = %{state | pids: pids -- [self()], until: now() + @keep_alive_ms}
    state = if state.scheduled?, do: state, else: schedule(state, 0)
    {:reply, state.flows, state}
  end

  @impl true
  def handle_info(:sample, state) do
    state = %{state | scheduled?: false}

    if now() > state.until do
      {:noreply, %{state | flows: []}}
    else
      flows = sample(state.pids, state.window_ms)
      {:noreply, schedule(%{state | flows: flows}, state.every_ms)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule(state, ms) do
    Process.send_after(self(), :sample, ms)
    %{state | scheduled?: true}
  end

  # One window: trace the sends, count them, stop.
  defp sample([], _window), do: []

  defp sample(pids, window) do
    session = :trace.session_create(:sprat_process_map, self(), [])

    counts =
      try do
        for pid <- pids, Process.alive?(pid) do
          try do
            :trace.process(session, pid, true, [:send])
          catch
            _, _ -> :ok
          end
        end

        collect(now() + window, %{}, 0)
      after
        :trace.session_destroy(session)
      end

    flush()

    Enum.map(counts, fn {{from, to}, tags} ->
      {tag, _} = Enum.max_by(tags, &elem(&1, 1))

      %{
        from: Sprat.Engine.ProcessMap.id(from),
        to: Sprat.Engine.ProcessMap.id(to),
        count: tags |> Map.values() |> Enum.sum(),
        tag: tag
      }
    end)
  end

  defp collect(_deadline, counts, n) when n >= @max_events, do: counts

  defp collect(deadline, counts, n) do
    wait = max(deadline - now(), 0)

    receive do
      {:trace, from, :send, msg, to} ->
        to = resolve(to)

        counts =
          if is_pid(to) and to != from,
            do:
              Map.update(
                counts,
                {from, to},
                %{tag(msg) => 1},
                &Map.update(&1, tag(msg), 1, fn c -> c + 1 end)
              ),
            else: counts

        collect(deadline, counts, n + 1)
    after
      wait -> counts
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: Process.whereis(name)
  defp resolve({name, node}) when is_atom(name) and node == node(), do: Process.whereis(name)
  defp resolve(_), do: nil

  # A word for what kind of message it was.
  @doc false
  def tag({:"$gen_call", _from, req}), do: prefixed("call", tag_of(req))
  def tag({:"$gen_cast", req}), do: prefixed("cast", tag_of(req))
  def tag({ref, _reply}) when is_reference(ref), do: "reply"
  def tag({:DOWN, _, _, _, _}), do: "down"
  def tag({:EXIT, _, _}), do: "exit"
  def tag(msg), do: tag_of(msg)

  defp prefixed(kind, kind), do: kind
  defp prefixed(kind, "message"), do: kind
  defp prefixed(kind, what), do: kind <> " " <> what

  defp tag_of(a) when is_atom(a), do: a |> Atom.to_string() |> String.trim_leading("sprat_")

  defp tag_of(t) when is_tuple(t) and tuple_size(t) > 0 and is_atom(elem(t, 0)),
    do: tag_of(elem(t, 0))

  defp tag_of(_), do: "message"

  defp flush do
    receive do
      {:trace, _, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
