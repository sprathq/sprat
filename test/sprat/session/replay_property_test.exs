defmodule Sprat.Session.ReplayPropertyTest do
  @moduledoc """
  Property test required by the wiring spec: any sequence of user
  submissions and agent-style blocks must replay, after a real process
  restart, to an identical transcript. `Sprat.Session.Block` is a plain
  map (see its moduledoc), so "identical" is exactly `==` on the
  reconstructed `blocks` list.
  """

  use Sprat.StoreCase, async: true
  use ExUnitProperties

  alias Sprat.{Session, SessionSupervisor}
  alias Sprat.Store.Sessions

  defp open(store, session_id), do: SessionSupervisor.open(session_id, store: store)

  defp restart(store, session_id, pid) do
    :ok = DynamicSupervisor.terminate_child(Sprat.SessionSupervisor, pid)
    {:ok, new_pid} = open(store, session_id)
    new_pid
  end

  defp word, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)

  defp op_gen do
    StreamData.one_of([
      StreamData.map(word(), &{:user, &1}),
      StreamData.map({word(), word()}, fn {role, text} -> {:agent, role, text} end),
      StreamData.map({word(), word()}, fn {role, summary} -> {:tool_call, role, summary} end),
      StreamData.map(word(), &{:system, &1})
    ])
  end

  defp apply_op(pid, {:user, text}), do: Session.submit_user_message(pid, text)

  defp apply_op(pid, {:agent, role, markdown}),
    do: Session.add_block(pid, %{kind: :agent_message, role: role, markdown: markdown})

  defp apply_op(pid, {:tool_call, role, summary}),
    do: Session.add_block(pid, %{kind: :tool_call, role: role, summary: summary})

  defp apply_op(pid, {:system, text}), do: Session.add_block(pid, %{kind: :system, text: text})

  property "any sequence of user submissions and agent blocks replays to an identical transcript",
           %{store: store} do
    check all(ops <- StreamData.list_of(op_gen(), max_length: 25)) do
      project_path = "/tmp/proj-prop-#{System.unique_integer([:positive])}"
      {:ok, session} = Sessions.create(store, %{project_path: project_path})
      {:ok, pid} = open(store, session.id)

      Enum.each(ops, &apply_op(pid, &1))

      live_blocks = Session.snapshot(pid).blocks
      assert length(live_blocks) == length(ops)

      new_pid = restart(store, session.id, pid)
      replayed_blocks = Session.snapshot(new_pid).blocks

      assert replayed_blocks == live_blocks
    end
  end
end
