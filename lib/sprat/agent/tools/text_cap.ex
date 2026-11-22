defmodule Sprat.Agent.Tools.TextCap do
  @moduledoc """
  Shared token-budget capping (docs/spec-v1.md §9): truncate at a line
  boundary with an explicit "N characters dropped" notice, never a silent
  cut. Pulled out of `Sprat.Agent.Tools.WebFetch` so file attachments
  (`Sprat.Attachments`) apply the exact same cap/truncation-notice
  behaviour the spec calls out ("Apply the same size cap and truncation
  notice `web_fetch` uses") instead of a second, drifting copy.
  """

  # ~4 chars/token, matching Sprat.Agent.Loop's own local estimate — good
  # enough for a budget cap, never claimed as a real token count.
  @chars_per_token 4

  @doc "Caps `text` at `max_tokens` (~#{@chars_per_token} chars/token), truncating at the last newline at or before the limit. Returns `{text, truncated?, dropped_chars}`."
  def cap(text, max_tokens) do
    limit = max_tokens * @chars_per_token

    if byte_size(text) <= limit do
      {text, false, 0}
    else
      cut = boundary_before(text, limit)
      {String.slice(text, 0, cut), true, byte_size(text) - cut}
    end
  end

  # Falls back to the hard limit if there's no earlier newline (e.g. one
  # giant unbroken line).
  defp boundary_before(text, limit) do
    head = String.slice(text, 0, limit)

    case :binary.matches(head, "\n") do
      [] -> limit
      matches -> matches |> List.last() |> elem(0)
    end
  end

  @doc "The explicit truncation notice appended when `cap/2` cuts, naming `subject` (default \"extract\") and where the rest still lives."
  def truncation_notice(dropped_chars, max_tokens, opts \\ []) do
    subject = Keyword.get(opts, :subject, "extract")
    kept_note = Keyword.get(opts, :kept_note, "The full content is stored as evidence, not lost.")

    "\n\n[…truncated: #{subject} exceeds the #{max_tokens}-token cap for this tool; " <>
      "#{dropped_chars} characters dropped. #{kept_note}]"
  end
end
