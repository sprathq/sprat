defmodule Sprat.Engine.Beats do
  @moduledoc """
  A Claude session's last few minutes as beats, for the processes screen's
  pulse: each thing it did (edited a file, ran a command, read, wrote to
  you, asked you, failed) with when, as `{unix_ms, kind, label}`.

  A session's watcher (`Sprat.Observer.SessionServer`) keeps them current
  from the transcript events it reads, and `Sprat.Engine.ProcessMap` hands
  them to the board. Pure.
  """

  alias Sprat.Observer.Model.Event

  @window_ms 180_000
  @max 160

  @type kind :: :edit | :run | :read | :web | :agent | :ask | :tool | :say | :you | :fail | :done
  @type beat :: {integer(), kind(), String.t() | nil}

  @doc "The beats in `events` from the last three minutes before `now_ms`, oldest first."
  def from_events(events, now_ms \\ System.os_time(:millisecond)) do
    events
    |> Enum.flat_map(&beat/1)
    |> Enum.filter(fn {at, _, _} -> now_ms - at <= @window_ms end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(-@max)
  end

  defp beat(%Event{at: %DateTime{} = at, sidechain?: false} = e) do
    case kind(e) do
      nil -> []
      {kind, label} -> [{DateTime.to_unix(at, :millisecond), kind, label}]
    end
  end

  defp beat(_), do: []

  @edits ~w(Edit Write MultiEdit NotebookEdit)
  @reads ~w(Read Grep Glob LS)
  @web ~w(WebFetch WebSearch)
  @agents ~w(Task Agent)

  @doc false
  def kind(%Event{kind: :tool_use, data: %{name: name} = d}) do
    input = Map.get(d, :input) || %{}

    cond do
      name in @edits -> {:edit, file(input)}
      name == "Bash" -> {:run, command(input)}
      name in @reads -> {:read, file(input) || pattern(input)}
      name in @web -> {:web, input["url"] || input["query"]}
      name in @agents -> {:agent, input["description"]}
      name == "AskUserQuestion" -> {:ask, nil}
      true -> {:tool, tool_name(name)}
    end
  end

  def kind(%Event{kind: :tool_result, data: %{is_error: true}}), do: {:fail, nil}
  def kind(%Event{kind: :tool_result}), do: {:done, nil}
  def kind(%Event{kind: :assistant_text}), do: {:say, nil}
  def kind(%Event{kind: :user_text}), do: {:you, nil}
  def kind(%Event{kind: :api_error}), do: {:fail, "api error"}
  def kind(_), do: nil

  # An MCP tool by its own name: "mcp__plugin_x__browser_click" → "browser_click".
  defp tool_name("mcp__" <> rest), do: rest |> String.split("__") |> List.last()
  defp tool_name(name), do: name

  defp file(input) do
    case input["file_path"] || input["notebook_path"] || input["path"] do
      p when is_binary(p) -> Path.basename(p)
      _ -> nil
    end
  end

  defp pattern(input), do: input["pattern"]

  # The command's first line, without a leading `cd …&&`.
  defp command(%{"command" => cmd}) when is_binary(cmd) do
    cmd
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.replace(~r/^cd\s+\S+\s*&&\s*/, "")
    |> String.slice(0, 60)
  end

  defp command(_), do: nil
end
