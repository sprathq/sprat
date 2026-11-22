defmodule Sprat.LogBuffer do
  @moduledoc """
  Bounded ring buffer of Sprat's own operational log lines, for the Debug
  surface's Logs tab. Fed by `Sprat.LogHandler`, a `:logger` handler
  installed in `Sprat.Application.start/2` — every line is redacted
  (`Sprat.Store.Redact.scrub/2` against `Sprat.Secrets.redaction_set/0`)
  before it ever reaches this buffer, so this module itself does no
  further scrubbing; it only bounds memory.

  `ponytail:` an `Agent` over a plain list, not ETS or a ring buffer
  library — 500 lines of text is a few KB, and `Enum.take(list, -500)` on
  every write is not a hot path (it is Sprat's own logging, not a
  request loop). Revisit if log volume ever makes this measurably slow.
  """

  use Agent

  @max_lines 500

  def start_link(opts \\ []) do
    Agent.start_link(fn -> [] end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Appends one already-redacted line. Drops the oldest once over #{@max_lines} lines."
  def add(server \\ __MODULE__, line) when is_binary(line) do
    Agent.update(server, fn lines -> Enum.take(lines ++ [line], -@max_lines) end)
  catch
    # The buffer may not be started yet (e.g. very early boot logs, or a
    # test that never starts it) — a dropped log line is not worth
    # crashing the caller over.
    :exit, _ -> :ok
  end

  @doc "All buffered lines, oldest first. `[]` if nothing has been logged yet, or the buffer isn't running."
  def all(server \\ __MODULE__) do
    Agent.get(server, & &1)
  catch
    :exit, _ -> []
  end
end
