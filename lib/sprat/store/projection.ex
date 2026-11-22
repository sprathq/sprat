defmodule Sprat.Store.Projection do
  @moduledoc """
  Read-model queries the TUI will use later (docs/spec-v1.md §13: "The UI
  subscribes to the Projection... rebuilt from events"). Not wired to the
  terminal layer yet — just the queries and structs. Everything here is
  derived straight from the tables `Sprat.Store` already writes, so it is
  trivially rebuildable: there is no separate projection state to get out
  of sync.
  """

  alias Sprat.Store.{Events, Messages, Sources, Tasks, Usage}

  defmodule TranscriptEntry do
    @moduledoc "One message in a session transcript."
    defstruct [:role, :agent_id, :content, :occurred_at]
  end

  defmodule TaskNode do
    @moduledoc "One node in a mission's task tree."
    defstruct [:task, :children]
  end

  @doc "The session transcript (the `messages` table), oldest first."
  def session_transcript(store \\ Sprat.Store, session_id) do
    store
    |> Messages.by_session(session_id)
    |> Enum.map(fn message ->
      %TranscriptEntry{
        role: message.role,
        agent_id: message.agent_id,
        content: message.content,
        occurred_at: message.occurred_at
      }
    end)
  end

  @doc "A resumed session's transcript re-rendered from stored blocks, per §13 Recovery."
  def rerender_transcript(store \\ Sprat.Store, session_id),
    do: session_transcript(store, session_id)

  @doc "The full event log for a session, in order — for `/export` and debugging."
  def session_events(store \\ Sprat.Store, session_id),
    do: Events.by_session(store, session_id, limit: 100_000)

  @doc "A mission's tasks arranged into a parent/child tree, root tasks first."
  def task_tree(store \\ Sprat.Store, mission_id) do
    tasks = Tasks.by_mission(store, mission_id)
    by_parent = Enum.group_by(tasks, & &1.parent_task_id)

    tasks
    |> Enum.filter(&is_nil(&1.parent_task_id))
    |> Enum.map(&build_node(&1, by_parent))
  end

  defp build_node(task, by_parent) do
    children = by_parent |> Map.get(task.id, []) |> Enum.map(&build_node(&1, by_parent))
    %TaskNode{task: task, children: children}
  end

  @doc "Usage totals for a mission (sum of leaf usage_records, never sums of sums — see `Sprat.Store.Usage.totals/1`)."
  def usage_totals(store \\ Sprat.Store, mission_id) do
    store |> Usage.by_mission(mission_id) |> Usage.totals()
  end

  @doc "Usage totals for one task."
  def task_usage_totals(store \\ Sprat.Store, task_id) do
    store |> Usage.by_task(task_id) |> Usage.totals()
  end

  @doc "The source register for a mission (§6), most recently recorded first."
  def source_register(store \\ Sprat.Store, mission_id) do
    store |> Sources.by_mission(mission_id) |> Enum.reverse()
  end
end
