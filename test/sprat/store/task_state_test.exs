defmodule Sprat.Store.TaskStateTest do
  use ExUnit.Case, async: true

  alias Sprat.Store.TaskState

  @valid_pairs [
    {:queued, :running},
    {:queued, :cancelled},
    {:running, :review_pending},
    {:running, :needs_input},
    {:running, :failed},
    {:running, :cancelled},
    {:running, :interrupted},
    {:review_pending, :completed},
    {:review_pending, :changes_requested},
    {:review_pending, :cancelled},
    {:needs_input, :running},
    {:needs_input, :cancelled},
    {:interrupted, :queued},
    {:interrupted, :cancelled},
    {:changes_requested, :queued}
  ]

  describe "valid?/2" do
    test "every documented transition is valid" do
      for {from, to} <- @valid_pairs do
        assert TaskState.valid?(from, to), "expected #{from} -> #{to} to be valid"
      end
    end

    test "exhaustively: every pair not in the valid set is invalid" do
      all_pairs = for from <- TaskState.states(), to <- TaskState.states(), do: {from, to}
      valid_set = MapSet.new(@valid_pairs)

      for pair <- all_pairs do
        expected = MapSet.member?(valid_set, pair)

        assert TaskState.valid?(elem(pair, 0), elem(pair, 1)) == expected,
               "mismatch for #{inspect(pair)}"
      end
    end

    test "cancelled is terminal: no transition ever leaves it" do
      for to <- TaskState.states() do
        refute TaskState.valid?(:cancelled, to)
      end
    end

    test "completed and failed are terminal" do
      for terminal <- [:completed, :failed], to <- TaskState.states() do
        refute TaskState.valid?(terminal, to)
      end
    end

    test "no self-transitions are valid" do
      for state <- TaskState.states() do
        refute TaskState.valid?(state, state)
      end
    end
  end

  describe "transition/2" do
    test "returns {:ok, to} for a valid transition" do
      assert TaskState.transition(:queued, :running) == {:ok, :running}
    end

    test "returns {:error, :invalid_transition} for an invalid transition" do
      assert TaskState.transition(:completed, :running) == {:error, :invalid_transition}
    end

    test "cancelled can never become completed directly" do
      assert TaskState.transition(:cancelled, :completed) == {:error, :invalid_transition}
    end
  end
end
