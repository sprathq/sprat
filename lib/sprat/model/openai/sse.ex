defmodule Sprat.Model.OpenAI.SSE do
  @moduledoc """
  Pure SSE frame assembly for OpenAI's `text/event-stream` chat completion
  chunks. Handles frames arriving split across network chunks (a `data:
  ...` line, or even the trailing `\\n\\n`, can land in a separate TCP
  read) by keeping the unparsed remainder in a buffer between calls.
  """

  @doc """
  Feeds `chunk` (raw bytes) into `buffer` (the unconsumed remainder from
  the previous call, `""` to start). Returns `{events, new_buffer}` where
  `events` is a list of decoded JSON maps for every complete `data: ...`
  frame found, in order, with `[DONE]` represented as `:done`. Malformed
  JSON in a frame is skipped (never raises) but still consumes the frame.
  """
  def feed(buffer, chunk) do
    (buffer <> chunk)
    |> String.split("\n\n")
    |> case do
      [incomplete] ->
        {[], incomplete}

      parts ->
        {complete, [remainder]} = Enum.split(parts, -1)
        {complete |> Enum.flat_map(&parse_frame/1), remainder}
    end
  end

  defp parse_frame(frame) do
    frame
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.trim_leading("data:") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&decode/1)
  end

  defp decode("[DONE]"), do: :done

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _} -> :malformed
    end
  end
end
