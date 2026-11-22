defmodule Sprat.Observer.SessionServer do
  @moduledoc """
  One process per Claude session (spec-v5 §3): follows that session's
  transcript on its own timer (every 2 s while the session lives, every 30 s
  after) and publishes its `Sprat.Observer.Tail` to `Sprat.Observer.Live`
  (`:tails`). Reading a large transcript for the first time takes seconds;
  here it holds up only this session.

  Started and kept current by `Sprat.Observer.Sessions`; registered by
  session id in `Sprat.Observer.SessionRegistry`.
  """

  use GenServer, restart: :transient
  require Logger

  alias Sprat.Observer.{Live, Tail}

  @registry Sprat.Observer.SessionRegistry
  @supervisor Sprat.Observer.SessionSupervisor

  @doc "Starts the session's process, or tells the running one its path and liveness."
  def ensure(sid, path, live?, opts \\ []) do
    case Registry.lookup(@registry, sid) do
      [{pid, _}] ->
        GenServer.cast(pid, {:update, path, live?})

      [] ->
        DynamicSupervisor.start_child(
          @supervisor,
          {__MODULE__, sid: sid, path: path, live?: live?, opts: opts}
        )
    end

    :ok
  end

  @doc "Whether the session's process runs."
  def running?(sid), do: Registry.lookup(@registry, sid) != []

  @doc "How many session processes run."
  def count do
    case Process.whereis(@supervisor) do
      nil -> 0
      sup -> DynamicSupervisor.count_children(sup).active
    end
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, args[:sid]}})
  end

  @impl true
  def init(args) do
    Sprat.Engine.ProcessMap.label("session " <> String.slice(to_string(args[:sid]), 0, 8))
    Sprat.Engine.ProcessMap.ref({:session, args[:sid]})

    state = %{
      sid: args[:sid],
      path: args[:path],
      live?: args[:live?],
      opts: args[:opts] || [],
      tail: Live.get(:tails, args[:sid]) || Tail.new(args[:sid])
    }

    Sprat.Engine.ProcessMap.beats(Sprat.Engine.Beats.from_events(state.tail.events))
    send(self(), :read)
    {:ok, state}
  end

  @impl true
  def handle_cast({:update, path, live?}, state) do
    if path != state.path, do: send(self(), :read)
    {:noreply, %{state | path: path, live?: live?}}
  end

  @impl true
  def handle_info(:read, state) do
    first? = is_nil(state.tail.offset)
    started = System.monotonic_time(:millisecond)

    tail =
      case Tail.advance(state.tail, state.path) do
        :unchanged ->
          state.tail

        {:changed, tail} ->
          Live.put(:tails, state.sid, tail)
          Sprat.Engine.ProcessMap.did(read_words(state.tail, tail))
          Sprat.Engine.ProcessMap.beats(Sprat.Engine.Beats.from_events(tail.events))
          tail
      end

    ms = System.monotonic_time(:millisecond) - started

    if first? and ms > 1_000 do
      Sprat.Activity.emit(:observer,
        text:
          "read session #{String.slice(state.sid, 0, 8)}'s transcript in #{Float.round(ms / 1000, 1)}s",
        status: :info
      )
    end

    every =
      if state.live?,
        do: Keyword.get(state.opts, :tail_ms, 2_000),
        else: Keyword.get(state.opts, :ended_tail_ms, 30_000)

    Process.send_after(self(), :read, every)
    {:noreply, %{state | tail: tail}}
  rescue
    e ->
      Logger.error("sprat session #{state.sid}: " <> Exception.message(e))
      Process.send_after(self(), :read, 30_000)
      {:noreply, state}
  end

  # What a read found, for the processes screen.
  defp read_words(%Tail{line: before}, %Tail{line: now})
       when is_integer(before) and is_integer(now) and now > before,
       do: "read #{now - before} new #{if now - before == 1, do: "line", else: "lines"}"

  defp read_words(_before, _now), do: "read the transcript"
end
