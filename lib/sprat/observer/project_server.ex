defmodule Sprat.Observer.ProjectServer do
  @moduledoc """
  One process per project (spec-v5 §3): keeps the project's roadmap and git
  progress current (`Sprat.Observer.RoadmapCache`: reloaded when its sources
  change or every ten minutes) on its own timer, and publishes the entry to
  `Sprat.Observer.Live` (`:roadmaps`). A slow `git log` holds up only this
  project.

  The engine starts one for every project it knows (`ensure/2`) and asks for
  a reload when the owner changed the roadmap (`reload/1`).
  """

  use GenServer, restart: :transient
  require Logger

  alias Sprat.Observer.{Live, RoadmapCache}

  @registry Sprat.Observer.ProjectRegistry
  @supervisor Sprat.Observer.ProjectSupervisor

  @doc "Starts the project's process if it isn't running."
  def ensure(root, opts \\ []) do
    if Registry.lookup(@registry, root) == [] and Process.whereis(@supervisor) do
      DynamicSupervisor.start_child(@supervisor, {__MODULE__, root: root, opts: opts})
    end

    :ok
  end

  @doc "Reloads the project's roadmap now (the owner wrote or edited it)."
  def reload(root) do
    case Registry.lookup(@registry, root) do
      [{pid, _}] -> send(pid, :reload)
      [] -> :ok
    end

    :ok
  end

  @doc "The published entry for `root`, or nil."
  def entry(root), do: Live.get(:roadmaps, root)

  @doc "How many project processes run."
  def count do
    case Process.whereis(@supervisor) do
      nil -> 0
      sup -> DynamicSupervisor.count_children(sup).active
    end
  end

  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: {:via, Registry, {@registry, args[:root]}})

  @impl true
  def init(args) do
    Sprat.Engine.ProcessMap.label(Path.basename(to_string(args[:root])))
    Sprat.Engine.ProcessMap.ref({:project, args[:root]})
    send(self(), :check)
    {:ok, %{root: args[:root], opts: args[:opts] || [], entry: Live.get(:roadmaps, args[:root])}}
  end

  @impl true
  def handle_info(:reload, state), do: check(%{state | entry: nil})
  def handle_info(:check, state), do: check(state) |> tap(fn _ -> schedule(state) end)

  defp schedule(state),
    do: Process.send_after(self(), :check, Keyword.get(state.opts, :project_ms, 60_000))

  defp check(state) do
    now = Keyword.get(state.opts, :now_fun, &DateTime.utc_now/0).()
    started = System.monotonic_time(:millisecond)
    entry = RoadmapCache.current(state.entry, state.root, now)
    ms = System.monotonic_time(:millisecond) - started

    if entry != state.entry do
      Live.put(:roadmaps, state.root, entry)
      Sprat.Engine.ProcessMap.did("re-read the roadmap and git history")

      if ms > 2_000 do
        Sprat.Activity.emit(:observer,
          project_root: state.root,
          text: "re-read the roadmap and git history in #{Float.round(ms / 1000, 1)}s",
          status: :info
        )
      end
    end

    {:noreply, %{state | entry: entry}}
  rescue
    e ->
      Logger.error("sprat project #{state.root}: " <> Exception.message(e))
      {:noreply, state}
  end
end
