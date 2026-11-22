defmodule Sprat.Store.MissionStateTest do
  use ExUnit.Case, async: true

  alias Sprat.Store.MissionState

  test "active can move to paused_budget, completed, failed or cancelled" do
    assert MissionState.valid?(:active, :paused_budget)
    assert MissionState.valid?(:active, :completed)
    assert MissionState.valid?(:active, :failed)
    assert MissionState.valid?(:active, :cancelled)
  end

  test "paused_budget can resume to active, or terminate" do
    assert MissionState.valid?(:paused_budget, :active)
    assert MissionState.valid?(:paused_budget, :cancelled)
    assert MissionState.valid?(:paused_budget, :failed)
  end

  test "terminal states have no outgoing transitions" do
    for terminal <- [:completed, :failed, :cancelled] do
      refute MissionState.valid?(terminal, :active)
      refute MissionState.valid?(terminal, :paused_budget)
    end
  end

  test "transition/2 returns the pair the caller expects" do
    assert {:ok, :paused_budget} = MissionState.transition(:active, :paused_budget)
    assert {:error, :invalid_transition} = MissionState.transition(:completed, :active)
  end
end
