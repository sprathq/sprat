defmodule Sprat.Store.MissionState do
  @moduledoc """
  Pure mission state machine (docs/spec-v1.md §12: "the mission enters
  `paused_budget`"). Mirrors `Sprat.Store.TaskState` exactly — same shape,
  same "no process, no IO" contract, exhaustively unit tested over every
  state pair. `paused_budget` is a real, resumable state: the user can
  raise the cap and the mission returns to `active`, per §12 "the user can
  raise the limit or export what exists."
  """

  @states [:active, :paused_budget, :completed, :failed, :cancelled]

  @transitions %{
    active: [:paused_budget, :completed, :failed, :cancelled],
    paused_budget: [:active, :cancelled, :failed],
    completed: [],
    failed: [],
    cancelled: []
  }

  @doc "Every valid mission state."
  def states, do: @states

  @doc "Whether `from -> to` is a valid transition."
  def valid?(from, to) when from in @states and to in @states do
    to in Map.fetch!(@transitions, from)
  end

  def valid?(_from, _to), do: false

  @doc "`{:ok, to}` if valid, `{:error, :invalid_transition}` otherwise."
  def transition(from, to) do
    if valid?(from, to), do: {:ok, to}, else: {:error, :invalid_transition}
  end
end
