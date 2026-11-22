defmodule Sprat.Store.TaskState do
  @moduledoc """
  Pure task state machine (docs/spec-v1.md §8):

      queued → running → review_pending → completed
                  ├─ needs_input
                  ├─ failed
                  ├─ cancelled
                  └─ interrupted   (process died; resumable by user choice)
      review_pending → changes_requested → queued (attempt + 1)

  "Cancelled is never completed": there is no transition back out of
  `cancelled`. No process, no IO — `valid?/2` and `transition/2` are unit
  tested exhaustively over every state pair.
  """

  @states [
    :queued,
    :running,
    :review_pending,
    :completed,
    :needs_input,
    :failed,
    :cancelled,
    :interrupted,
    :changes_requested
  ]

  @transitions %{
    queued: [:running, :cancelled],
    running: [:review_pending, :needs_input, :failed, :cancelled, :interrupted],
    review_pending: [:completed, :changes_requested, :cancelled],
    needs_input: [:running, :cancelled],
    interrupted: [:queued, :cancelled],
    changes_requested: [:queued],
    completed: [],
    failed: [],
    cancelled: []
  }

  @doc "Every valid task state."
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
