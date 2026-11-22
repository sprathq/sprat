defmodule Sprat.Terminal.MessageFlowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.MessageFlow

  @types ~w(assignment clarification evidence handoff review decision status cancel error)a

  defp message_gen do
    gen all(
          from <- member_of([:a, :b, :c]),
          to <- member_of([:a, :b, :c]),
          type <- member_of(@types),
          frame <- integer(0..200)
        ) do
      %{from: from, to: to, type: type, frame: frame}
    end
  end

  property "coalescing never loses a message: coalesced counts always sum back to the real count" do
    check all(messages <- list_of(message_gen(), max_length: 50)) do
      # Sort by frame first — coalesce/1 assumes chronological input, same
      # as gutter/4's real caller.
      sorted = Enum.sort_by(messages, & &1.frame)
      bursts = MessageFlow.coalesce(sorted)
      assert Enum.sum(Enum.map(bursts, & &1.count)) == length(sorted)
    end
  end

  property "gutter/4 never produces a frame outside the agent_order bounds" do
    check all(
            agent_count <- integer(1..5),
            messages <- list_of(message_gen(), max_length: 30),
            frame <- integer(0..250),
            animated? <- boolean()
          ) do
      agent_order = Enum.take([:a, :b, :c, :d, :e], agent_count)
      sorted = Enum.sort_by(messages, & &1.frame)
      n = length(agent_order)

      case MessageFlow.gutter(sorted, agent_order, frame, animated?) do
        nil ->
          :ok

        %{sender: sender, recipient: recipient, rows: rows} ->
          assert sender in 0..(n - 1)
          assert recipient in 0..(n - 1)
          assert rows.first in 0..(n - 1)
          assert rows.last in 0..(n - 1)
      end
    end
  end

  test "the animation-disabled path holds the last message as a static arrow for ~2s (frame-count, not a sleep)" do
    messages = [%{from: :a, to: :b, type: :assignment, frame: 10}]

    assert %{phase: :static} = MessageFlow.gutter(messages, [:a, :b], 10, false)
    assert %{phase: :static} = MessageFlow.gutter(messages, [:a, :b], 29, false)
    assert MessageFlow.gutter(messages, [:a, :b], 31, false) == nil
  end

  test "the animated path is :travel then :flash then gone" do
    messages = [%{from: :a, to: :b, type: :assignment, frame: 10}]

    assert %{phase: :travel} = MessageFlow.gutter(messages, [:a, :b], 12, true)
    assert %{phase: :flash} = MessageFlow.gutter(messages, [:a, :b], 15, true)
    assert MessageFlow.gutter(messages, [:a, :b], 17, true) == nil
  end

  test "a burst of the same from/to/type coalesces into one labelled entry" do
    messages = [
      %{from: :a, to: :b, type: :assignment, frame: 1},
      %{from: :a, to: :b, type: :assignment, frame: 2},
      %{from: :a, to: :b, type: :assignment, frame: 3}
    ]

    assert [%{count: 3}] = MessageFlow.coalesce(messages)
    assert MessageFlow.gutter(messages, [:a, :b], 3, true).label == "✉×3"
  end

  test "a message to/from an agent not in agent_order yields no gutter frame rather than an invalid index" do
    messages = [%{from: :a, to: :ghost, type: :assignment, frame: 1}]
    assert MessageFlow.gutter(messages, [:a, :b], 1, true) == nil
  end
end
