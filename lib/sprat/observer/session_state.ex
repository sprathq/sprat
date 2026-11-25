defmodule Sprat.Observer.SessionState do
  @moduledoc """
  The pure fold of a session's transcript events into
  `%Sprat.Observer.Model.SessionState{}` (spec §6): what the detector reads.

  Folding is incremental: `fold(fold(s, a), b) == fold(s, a ++ b)`.

  Sidechain (subagent) events count as work done (tool results, edits, tests,
  commits) but never as the main conversation's last words, questions or
  limits.
  """

  alias Sprat.Observer.Model.{Event, SessionState}

  @max_results 50
  @max_edits 100
  @max_api_errors 20
  @edit_tools ~w(Edit Write MultiEdit NotebookEdit)

  @test_re ~r/(?:^|[\s;&|(])(?:mix\s+test|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test|pytest|python3?\s+-m\s+pytest|flutter\s+test|xcodebuild\b[^;&|]*\btest\b|cargo\s+test|go\s+test|(?:bundle\s+exec\s+)?rspec|jest|vitest)(?=$|[\s:;&|)])/

  @commit_re ~r/(?:^|[\s;&|(])git\s+(?:-C\s+\S+\s+)?commit(?:\s|$)/

  @error_line_re ~r/error|fail|exception|cannot|can't|couldn.t|not found|no such|denied|fatal|panic|undefined|invalid|refused|timed? ?out|traceback|\*\*\s*\(/i

  @doc "Folds events (oldest first) into a state."
  @spec fold(SessionState.t(), [Event.t()]) :: SessionState.t()
  def fold(state \\ %SessionState{}, events) do
    events
    |> Enum.reduce(state, &step/2)
    |> apply_pending_question()
  end

  defp step(%Event{} = e, s) do
    s = if e.at, do: %{s | last_event_at: e.at}, else: s
    s = %{s | last_event_line: e.line}
    s = track_assistant_line(e, s)
    s = track_action(e, s)
    apply_event(e, s)
  end

  # The main thread's newest action, for "last: ran mix test 12m ago". A
  # tool result is the end of an action, not one.
  defp track_action(%Event{sidechain?: false, at: %DateTime{} = at} = e, s) do
    case Sprat.Engine.Beats.kind(e) do
      {kind, label} when kind not in [:done] -> %{s | last_action: {at, kind, label}}
      _ -> s
    end
  end

  defp track_action(_e, s), do: s

  # Evidence ids for the detector: the newest assistant-side line, and the
  # last 10 assistant-side lines (W3's window counts api errors among them).
  @assistant_kinds [:assistant_text, :tool_use, :api_error]

  defp track_assistant_line(%Event{kind: kind, sidechain?: false, line: line}, s)
       when kind in @assistant_kinds do
    recent = [line | List.delete(s.recent_assistant_lines, line)] |> Enum.take(10)
    %{s | last_assistant_line: line, recent_assistant_lines: recent}
  end

  defp track_assistant_line(_e, s), do: s

  defp apply_event(%Event{kind: :user_text, sidechain?: false} = e, s) do
    %{
      s
      | last_user_text: e.data[:text],
        last_user_at: e.at,
        asks_user?: false,
        pending_question: nil
    }
  end

  defp apply_event(%Event{kind: :assistant_text, sidechain?: false} = e, s) do
    text = e.data[:text] || ""
    question = question_in(text)

    %{
      s
      | last_assistant_text: text,
        last_assistant_at: e.at,
        usage_limit: nil,
        asks_user?: question != nil,
        pending_question: question
    }
  end

  defp apply_event(%Event{kind: :tool_use} = e, s) do
    s = %{s | pending_tool_uses: Map.put(s.pending_tool_uses, e.data[:id], e)}

    if e.sidechain?,
      do: s,
      else: %{s | usage_limit: nil, asks_user?: false, pending_question: nil}
  end

  defp apply_event(%Event{kind: :tool_result} = e, s) do
    id = e.data[:tool_use_id]
    {use, pending} = Map.pop(s.pending_tool_uses, id)
    name = use && use.data[:name]
    input = (use && use.data[:input]) || %{}
    command = if name == "Bash", do: str(input["command"])
    is_error = e.data[:is_error] == true
    text = e.data[:text] || ""

    result = %{
      line: e.line,
      at: e.at,
      tool_use_id: id,
      name: name,
      command: command,
      is_error: is_error,
      signature: if(is_error, do: signature(name, command, text)),
      text: text
    }

    s = %{
      s
      | pending_tool_uses: pending,
        recent_results: Enum.take([result | s.recent_results], @max_results)
    }

    s =
      if name == "AskUserQuestion" and not e.sidechain?,
        do: %{s | asks_user?: false, pending_question: nil},
        else: s

    s
    |> track_edit(name, input, is_error, e)
    |> track_test(command, is_error)
    |> track_commit(command, is_error, e)
  end

  defp apply_event(%Event{kind: :api_error} = e, s) do
    err = %{
      line: e.line,
      at: e.at,
      status: e.data[:status],
      error: e.data[:error],
      text: e.data[:text],
      limit?: e.data[:limit?] == true
    }

    s = %{s | api_errors: Enum.take([err | s.api_errors], @max_api_errors)}

    cond do
      e.sidechain? ->
        s

      is_map(e.data[:limit]) ->
        l = e.data[:limit]

        %{
          s
          | usage_limit: %{
              line: e.line,
              at: e.at,
              kind: l.kind,
              reset_at: l.reset_at,
              text: l.text
            }
        }

      true ->
        %{s | usage_limit: nil}
    end
  end

  defp apply_event(%Event{kind: :agent_limit} = e, s) do
    l = e.data[:limit]

    %{
      s
      | agent_limit: %{line: e.line, at: e.at, kind: l.kind, reset_at: l.reset_at, text: l.text}
    }
  end

  defp apply_event(%Event{kind: :agent_ok}, s), do: %{s | agent_limit: nil}

  defp apply_event(%Event{kind: :title} = e, s), do: %{s | title: e.data[:title]}
  defp apply_event(%Event{kind: :cost} = e, s), do: %{s | cost_usd: e.data[:total_usd]}
  defp apply_event(_e, s), do: s

  # A pending AskUserQuestion always means the session is asking.
  defp apply_pending_question(s) do
    asks =
      s.pending_tool_uses
      |> Map.values()
      |> Enum.filter(&(&1.data[:name] == "AskUserQuestion" and not &1.sidechain?))
      |> Enum.max_by(& &1.line, fn -> nil end)

    case asks do
      nil -> s
      e -> %{s | asks_user?: true, pending_question: ask_question(e.data[:input])}
    end
  end

  defp ask_question(%{"questions" => [%{"question" => q} | _]}) when is_binary(q), do: q
  defp ask_question(%{"question" => q}) when is_binary(q), do: q
  defp ask_question(_), do: nil

  defp track_edit(s, name, input, false, e) when name in @edit_tools do
    case str(input["file_path"]) || str(input["notebook_path"]) do
      nil ->
        s

      path ->
        %{
          s
          | recent_edits:
              Enum.take([%{line: e.line, at: e.at, path: path} | s.recent_edits], @max_edits)
        }
    end
  end

  defp track_edit(s, _, _, _, _), do: s

  defp track_test(s, nil, _), do: s

  defp track_test(s, command, is_error) do
    if test_command?(command), do: %{s | last_test_failed?: is_error}, else: s
  end

  defp track_commit(s, command, false, e) when is_binary(command) do
    if Regex.match?(@commit_re, command),
      do: %{s | last_commit_at: e.at || s.last_commit_at},
      else: s
  end

  defp track_commit(s, _, _, _), do: s

  @doc "True for commands that run a test suite."
  @spec test_command?(String.t()) :: boolean()
  def test_command?(command) when is_binary(command), do: Regex.match?(@test_re, command)
  def test_command?(_), do: false

  @doc """
  The question an assistant text ends with, or nil. The text asks when its
  last non-empty line ends in `?`; the question is that line's last sentence.
  """
  @spec question_in(String.t()) :: String.t() | nil
  def question_in(text) when is_binary(text) do
    last =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last()

    last = last && last |> String.trim_trailing("*") |> String.trim_trailing("_") |> String.trim()

    if last && String.ends_with?(last, "?") do
      sentences = Regex.split(~r/(?<=[.!?])\s+/, last)
      sentences |> List.last() |> String.trim_leading("*") |> String.trim()
    end
  end

  def question_in(_), do: nil

  @doc """
  A stable signature for a failed tool result: the command head plus the
  first error-ish line, with quoted values, absolute paths, hex ids and digits
  normalised.
  """
  @spec signature(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def signature(name, command, text) do
    head = if command, do: command_head(command), else: name || "?"
    head <> " | " <> normalise(error_line(text))
  end

  defp command_head(command) do
    tokens =
      command
      |> String.split("\n")
      |> List.first()
      |> String.split(~r/\s*(?:&&|;|\|\|)\s*/)
      |> Enum.reject(&Regex.match?(~r/^\s*cd\s/, &1))
      |> List.first("")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.drop_while(&Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, &1))

    tokens
    |> Enum.take(2)
    |> Enum.map(&normalise/1)
    |> Enum.join(" ")
  end

  defp error_line(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    useful = Enum.reject(lines, &Regex.match?(~r/^Exit code \d+$/, &1))

    Enum.find(useful, &Regex.match?(@error_line_re, &1)) || List.first(useful) ||
      List.first(lines) || ""
  end

  @doc false
  def normalise(line) do
    line
    |> String.replace(~r/"[^"]*"|'[^']*'|`[^`]*`|‘[^’]*’|“[^”]*”/u, "<q>")
    |> String.replace(~r{(?<![\w.])~?/[^\s:,;)\]]+}, "<path>")
    |> String.replace(~r/\b0x[0-9a-fA-F]+\b/, "<hex>")
    |> String.replace(
      ~r/\b(?=[0-9a-fA-F-]*[a-fA-F])(?=[0-9a-fA-F-]*\d)[0-9a-fA-F][0-9a-fA-F-]{5,}\b/,
      "<hex>"
    )
    |> String.replace(~r/\d+/, "N")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
  end

  defp str(s) when is_binary(s), do: s
  defp str(_), do: nil
end
