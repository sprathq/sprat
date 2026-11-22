defmodule Sprat.Session.ExitSummary do
  @moduledoc """
  The short summary printed to normal scrollback on exit
  (`docs/design/tui-zones.md`: "On exit, print a short summary (objective,
  artifacts, cost, export path)" — the alternate screen's mitigation for
  losing the terminal's own scrollback). `Sprat.Session.Shell` calls
  `print/1` after `UISupervisor` has already stopped (alt screen left,
  cooked mode restored), so this really lands on the terminal's visible,
  persistent scrollback, not the vanishing alternate screen.

  Every field here comes from what the store already has — no cost or
  count is invented when the data isn't there; a mission with nothing
  recorded yet just prints "no mission started".
  """

  alias Sprat.Store.{Missions, Sessions, Tasks, Usage}
  alias Sprat.Terminal.Zones.Mission

  @doc "Prints the summary for `session_id` to stdout (normal scrollback, cooked mode)."
  def print(session_id) do
    Enum.each(lines(session_id), &IO.puts/1)
  end

  @doc """
  The summary as a list of plain lines (no ANSI — normal scrollback, not
  the live region). `store` defaults to the real `Sprat.Store` singleton
  (what `print/1` always uses); overridable so tests can point this at an
  isolated store instead of the app-wide one, same as every other
  store-touching function in this codebase.
  """
  def lines(session_id, store \\ Sprat.Store) do
    missions = Missions.by_session(store, session_id)

    ["", "── sprat session summary ──" | mission_lines(missions, store)] ++
      export_hint(session_id, store)
  end

  defp mission_lines([], _store), do: ["  no mission started"]

  defp mission_lines(missions, store) do
    Enum.flat_map(missions, fn mission ->
      tasks = Tasks.by_mission(store, mission.id)
      # "completed" is the real terminal status (docs/spec-v1.md §8 task
      # state machine, `Sprat.Store.TaskState`) — this compared against
      # "done" until `Sprat.Mission` started creating real tasks, which is
      # what first exercised this path with a task that could ever match.
      done = Enum.count(tasks, &(&1.status == "completed"))
      cost = mission_cost(mission.id, store)

      [
        "  objective: #{mission.objective}",
        "  tasks: #{done}/#{length(tasks)} done",
        "  cost: #{cost}"
      ]
    end)
  end

  # Shares `Zones.Mission.dollars/1` with the Mission zone and footer
  # (docs/spec-v1.md §12: one source of truth for money formatting) rather
  # than rounding to 2 decimals here directly — that used to show a real
  # sub-cent cost as the misleading "$0.00".
  defp mission_cost(mission_id, store) do
    case Usage.totals(Usage.by_mission(store, mission_id)) do
      %{cost: nil} -> "unknown"
      %{cost: cost} -> Mission.dollars(cost)
    end
  end

  defp export_hint(session_id, store) do
    case Sessions.get(store, session_id) do
      nil ->
        []

      _session ->
        ["  export: " <> export_line(session_id, store)]
    end
  end

  # Honest either way (docs/spec-v1.md §19 "print where the export is or
  # how to make one"): `Sprat.Export.run/3` is side-effect-free to *call*
  # here (it only writes files on an actual `/export`, never as a side
  # effect of printing this hint) — this just asks it what it would say,
  # via the same classification `/export` itself uses, so the hint never
  # promises a bundle that `/export` would then refuse to write.
  defp export_line(session_id, store) do
    case Sprat.Export.preview(store, session_id) do
      {:ok, mission_id} ->
        "/export writes README.md + brief/validation-plan/research/sources/usage/events " <>
          "to sprat-export/#{mission_id}/"

      {:error, message} ->
        message
    end
  end
end
