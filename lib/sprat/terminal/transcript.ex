defmodule Sprat.Terminal.Transcript do
  @moduledoc """
  Formatters for already-committed transcript blocks (spec §10 "Transcript
  blocks" table): user message, agent message, tool call/result, stage
  change, artifact written, error, gate result. Each returns already-wrapped
  lines ready to `commit/1` on the renderer. A verbose flag shows full
  untruncated tool output instead of the default 3-5 line truncation.
  """

  alias IO.ANSI
  alias Sprat.Terminal.{Glyphs, Markdown, Sanitize, Width}

  @truncate_lines 4

  @doc "User message, `> ` prefix. `dim?: true` renders it dimmed (already submitted, scrolled)."
  def user_message(text, opts \\ []) do
    dim = if Keyword.get(opts, :dim?, false), do: ANSI.faint(), else: ""
    reset = if dim == "", do: "", else: ANSI.reset()

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> dim <> "> " <> line <> reset
      {line, _} -> dim <> "  " <> line <> reset
    end)
  end

  @doc "Agent message: `⏺ <Role>` header, Markdown rendered to styled/wrapped lines."
  def agent_message(role, markdown, width, opts \\ []) do
    marker = Glyphs.block_marker(Glyphs.ascii?(opts))
    header = style(opts, ANSI.cyan(), "#{marker} #{role}")
    body = Markdown.to_lines(markdown, width - 2, opts)
    [header | Enum.map(body, &("  " <> &1))]
  end

  @doc "Tool call: `⏺ <Role>  tool(summary)`."
  def tool_call(role, summary, opts \\ []) do
    marker = Glyphs.block_marker(Glyphs.ascii?(opts))
    [style(opts, ANSI.cyan(), "#{marker} #{role}") <> "  " <> Sanitize.strip(summary)]
  end

  @doc """
  Tool result: `⎿ ` indented summary, truncated to #{@truncate_lines} lines
  with `… +N lines (ctrl+o to expand)` unless `verbose?: true`.
  """
  def tool_result(text, width, opts \\ []) do
    result_marker = Glyphs.result_marker(Glyphs.ascii?(opts))
    verbose? = Keyword.get(opts, :verbose?, false)

    lines =
      text
      |> Sanitize.strip()
      |> String.split("\n")
      |> Enum.flat_map(&Width.wrap(&1, width - 4))

    {shown, hidden} =
      if verbose? or length(lines) <= @truncate_lines do
        {lines, 0}
      else
        {Enum.take(lines, @truncate_lines), length(lines) - @truncate_lines}
      end

    body =
      shown
      |> Enum.with_index()
      |> Enum.map(fn
        {line, 0} -> "  #{result_marker}  " <> line
        {line, _} -> "     " <> line
      end)

    if hidden > 0 do
      body ++ ["     " <> style(opts, ANSI.faint(), "… +#{hidden} lines (ctrl+o to expand)")]
    else
      body
    end
  end

  @doc "Stage change: `⏺ Stage: <name>` plus a one-line reason."
  def stage_change(name, reason, opts \\ []) do
    marker = Glyphs.block_marker(Glyphs.ascii?(opts))
    header = style(opts, ANSI.magenta(), "#{marker} Stage: #{name}")
    if reason, do: [header, "  " <> reason], else: [header]
  end

  @doc "Artifact written: `⏺ <Role>  wrote <artifact> v<n>`."
  def artifact_written(role, artifact, version, path, opts \\ []) do
    marker = Glyphs.block_marker(Glyphs.ascii?(opts))

    [
      style(opts, ANSI.cyan(), "#{marker} #{role}") <> "  wrote #{artifact} v#{version}",
      "  #{path}"
    ]
  end

  @doc "Error block: red `⏺`, message and suggested action — never a bare stack trace."
  def error_block(message, suggestion, opts \\ []) do
    marker = Glyphs.block_marker(Glyphs.ascii?(opts))
    header = style(opts, ANSI.red(), marker) <> " " <> Sanitize.strip(message)
    if suggestion, do: [header, "  " <> Sanitize.strip(suggestion)], else: [header]
  end

  @doc "Gate result: check/cross with the specific missing item."
  def gate_result(true, _detail, opts) do
    mark = if Glyphs.ascii?(opts), do: "[ok]", else: "✓"
    [style(opts, ANSI.green(), mark)]
  end

  def gate_result(false, detail, opts) do
    mark = if Glyphs.ascii?(opts), do: "[fail]", else: "✗"
    [style(opts, ANSI.red(), mark) <> " " <> detail]
  end

  defp style(opts, code, text) do
    if Glyphs.color?(opts), do: code <> text <> ANSI.reset(), else: text
  end
end
