defmodule Sprat.Terminal.Plain do
  @moduledoc """
  `--plain` mode: the same view models rendered as plain, line-oriented
  output — no redraws, no cursor movement, no spinner animation. Suitable
  for CI, piped output, screen readers, and `script` capture. Prompts
  become numbered line prompts printed once, not redrawn in place.
  """

  alias Sprat.Terminal.{Markdown, Sanitize}

  @doc "Render committed transcript blocks (already-formatted lines) as plain text lines."
  def commit(lines) when is_list(lines), do: lines

  @doc "One line reporting a stage/activity change, no spinner."
  def activity_line(%{verb: verb}), do: ["#{verb}…"]

  @doc "Checklist as plain numbered/marked lines, one per stage."
  def checklist_lines(%{stages: stages}) do
    Enum.map(stages, fn {label, status} -> "[#{status_word(status)}] #{label}" end)
  end

  defp status_word(:done), do: "done"
  defp status_word(:active), do: "active"
  defp status_word(:pending), do: "pending"

  @doc "A permission/question prompt as a numbered line prompt (no live redraw)."
  def prompt_lines(prompt) do
    header = ["#{prompt.title}:" | prompt.lines]
    options = Enum.with_index(prompt.options, 1) |> Enum.map(fn {opt, i} -> "  #{i}) #{opt}" end)
    header ++ options ++ ["Enter a number:"]
  end

  @doc "Markdown rendered without ANSI styling, for plain-mode agent messages."
  def markdown_lines(markdown, width) do
    Markdown.to_lines(markdown, width, color: false, ascii: true)
  end

  @doc "Sanitized plain text of untrusted content."
  def sanitize(text), do: Sanitize.strip(text)
end
