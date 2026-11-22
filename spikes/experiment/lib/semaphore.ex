defmodule Experiment.Semaphore do
  @moduledoc """
  A tiny global concurrency limiter shared by every codex call in the run,
  team and solo alike, so the whole run never has more than N `codex exec`
  processes in flight at once — not just N per task.

  ponytail: busy-poll every 50ms instead of a proper waiting queue. Fine at
  this scale (a handful of workers); swap for a queueing GenServer if the
  run ever gets wide enough for polling overhead to matter.
  """

  use Agent

  def start_link(permits), do: Agent.start_link(fn -> permits end, name: __MODULE__)

  def acquire do
    if Agent.get_and_update(__MODULE__, fn
         n when n > 0 -> {true, n - 1}
         n -> {false, n}
       end) do
      :ok
    else
      Process.sleep(50)
      acquire()
    end
  end

  def release, do: Agent.update(__MODULE__, &(&1 + 1))

  def with_permit(fun) do
    acquire()

    try do
      fun.()
    after
      release()
    end
  end
end
