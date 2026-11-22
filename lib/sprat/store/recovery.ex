defmodule Sprat.Store.Recovery do
  @moduledoc """
  Startup recovery (docs/spec-v1.md §13): any task left `running` when the
  process last died is marked `interrupted`. Never touches a `completed`
  task. `decide/1` is the pure classification function (unit-testable
  without a database); `scan/2` is the thin DB wrapper that fetches
  `running` tasks **for this session only** (`Tasks.running_for_session/2`),
  applies it, and writes each transition transactionally (status change +
  event, via `Sprat.Store.Tasks.transition/4`).

  Scoped to `session_id` on purpose: a real production bug had a second
  `sprat` process (its own session id) boot while a first session's task
  was still genuinely mid-flight (its unlinked `Sprat.Mission` task, by
  design, isn't killed by anything short of the whole node exiting) — an
  unscoped `Tasks.running/1` scan interrupted that live task out from
  under it, and the original process then crashed trying to complete a
  task that was no longer `running` (`Sprat.Mission.finish_ok/4`). Only a
  session recovering *itself* may ever reclassify its own tasks.
  """

  alias Sprat.Store.Tasks

  @doc """
  Given a list of task structs/maps with `:status`, returns the list of
  those that must be reclassified as `interrupted` (currently just
  `running` ones — `queued`, `review_pending`, `changes_requested` etc.
  are left alone; they are not mid-execution, and `completed`/`failed`/
  `cancelled` are terminal and never revisited).
  """
  def decide(tasks) do
    Enum.filter(tasks, fn task -> status_of(task) == "running" end)
  end

  @doc """
  Runs recovery against `store`: finds every `running` task, transitions
  each to `interrupted` (state change + event in one transaction, via
  `Sprat.Store.Tasks.transition/4`), and returns the list of task ids it
  reclassified.
  """
  def scan(store \\ Sprat.Store, session_id) do
    store
    |> Tasks.running_for_session(session_id)
    |> decide()
    |> Enum.map(fn task ->
      {:ok, _} =
        Tasks.transition(store, task.id, :interrupted, %{
          session_id: session_id,
          reason: "process restarted while running"
        })

      task.id
    end)
  end

  defp status_of(%{status: status}), do: to_string(status)
  defp status_of(%{"status" => status}), do: to_string(status)
end
