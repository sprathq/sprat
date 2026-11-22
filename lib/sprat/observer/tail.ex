defmodule Sprat.Observer.Tail do
  @moduledoc """
  Follows one session's transcript: reads the lines added since last time,
  folds them into the session's state, keeps its recent events.

  Pure over the file system: the engine calls it inline (tests, one-shot
  commands) and a `Sprat.Observer.SessionServer` calls it on its own timer,
  so a 150 MB transcript is read in that session's process, not the engine's.
  """

  alias Sprat.Observer.{SessionState, Transcript}
  alias Sprat.Observer.Model.SessionState, as: SState

  # Start near the end of big transcripts: the rules only need recent history.
  @tail_bytes 2_000_000
  @events_kept 120

  defstruct [:session_id, :path, :offset, :line, :state, :last_event_at, events: []]

  @type t :: %__MODULE__{}

  @doc "A fresh tail for `session_id`; reading starts on the first `advance/2`."
  def new(session_id),
    do: %__MODULE__{session_id: session_id, state: %SState{session_id: session_id}}

  @doc """
  Reads what was added to `path` since the last call. `{:changed, tail}`
  when there were new bytes, `:unchanged` otherwise (including a missing
  file). A new path starts over.
  """
  def advance(%__MODULE__{} = t, path) do
    cond do
      is_nil(path) or not File.exists?(path) ->
        :unchanged

      true ->
        t = if t.path != path, do: %{t | path: path, offset: nil, line: nil}, else: t
        {offset, line} = if t.offset, do: {t.offset, t.line}, else: initial(path)
        size = file_size(path)

        if size == offset do
          if t.offset, do: :unchanged, else: {:changed, %{t | offset: offset, line: line}}
        else
          {events, new_offset, new_line} = Transcript.read_from(path, offset, line)
          folded = SessionState.fold(t.state, events)

          {:changed,
           %{
             t
             | offset: new_offset,
               line: new_line,
               state: folded,
               events: (t.events ++ events) |> Enum.take(-@events_kept),
               last_event_at: folded.last_event_at || t.last_event_at
           }}
        end
    end
  end

  defp initial(path) do
    size = file_size(path)

    if size <= @tail_bytes do
      {0, 1}
    else
      start = next_line_start(path, size - @tail_bytes)
      {start, count_newlines(path, start) + 1}
    end
  end

  defp next_line_start(path, from) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      {:ok, _} = :file.position(io, from)

      case IO.binread(io, :line) do
        data when is_binary(data) -> from + byte_size(data)
        _ -> from
      end
    after
      File.close(io)
    end
  end

  defp count_newlines(path, upto) do
    {:ok, io} = File.open(path, [:read, :binary, :raw, :read_ahead])

    try do
      count_loop(io, upto, 0)
    after
      File.close(io)
    end
  end

  defp count_loop(_io, remaining, acc) when remaining <= 0, do: acc

  defp count_loop(io, remaining, acc) do
    case :file.read(io, min(remaining, 4_000_000)) do
      {:ok, data} ->
        count_loop(io, remaining - byte_size(data), acc + length(:binary.matches(data, "\n")))

      _ ->
        acc
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end
end
