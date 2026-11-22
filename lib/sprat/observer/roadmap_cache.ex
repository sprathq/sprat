defmodule Sprat.Observer.RoadmapCache do
  @moduledoc """
  A project's roadmap and git progress, reloaded only when its sources
  changed or ten minutes passed. Loading runs `git log` and parses every
  roadmap source, the slowest thing Sprat does per project; the engine
  calls it inline, a `Sprat.Observer.ProjectServer` on its own timer.

  An entry: `%{sig, roadmap, events, at}`.
  """

  alias Sprat.Roadmap
  alias Sprat.Roadmap.Progress

  @max_age_s 600

  @doc "The entry for `root`: `cached` when still current, else freshly loaded."
  def current(cached, root, now) do
    sig = signature(root)

    case cached do
      %{sig: ^sig, at: %DateTime{} = at} = entry ->
        if DateTime.diff(now, at) < @max_age_s, do: entry, else: reload(entry, sig, root, now)

      _ ->
        reload(cached, sig, root, now)
    end
  end

  # `at` is when it was loaded. (V4 kept the first load's time while nothing
  # changed, so after ten minutes every slow tick reloaded every project from
  # git: a large part of the 60-second slow ticks in serve.log.)
  defp reload(_cached, sig, root, now) do
    {roadmap, events} = load(root, now)
    %{sig: sig, roadmap: roadmap, events: events, at: now}
  end

  @doc "A hash of the roadmap sources' paths and modification times."
  def signature(root) do
    root
    |> Roadmap.Sources.discover([])
    |> Enum.map(&{&1.path, &1.mtime})
    |> :erlang.phash2()
  end

  @doc "Loads the roadmap and its progress events from git."
  def load(root, now) do
    {roadmap, commits} = Roadmap.load(root, now: now)

    done_ids =
      roadmap.phases
      |> Enum.flat_map(& &1.items)
      |> Enum.filter(&(&1.state == :done))
      |> MapSet.new(& &1.id)

    events =
      commits
      |> Progress.from_git(roadmap)
      |> Enum.map(fn e ->
        if e[:item_id] && MapSet.member?(done_ids, e.item_id), do: %{e | kind: :done}, else: e
      end)

    {roadmap, events}
  end
end
