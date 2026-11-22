defmodule Sprat.Spike.Demo do
  @moduledoc """
  Point 4: a simulated 200 tokens/sec Markdown stream that commits
  paragraph-by-paragraph, interleaved with ⏺/⎿ tool blocks and checklist
  updates, while the composer keeps accepting keystrokes — this is what we
  measure keypress-to-echo latency against.
  """

  alias Sprat.Spike.{Markdown, Renderer}
  alias IO.ANSI

  @tokens_per_sec 200
  @token_interval_ms round(1000 / @tokens_per_sec)

  @paragraphs [
    "# Researching independent gym software\n",
    "Owner-operated gyms in the UK typically juggle **three** systems: booking, payments and access control. Most complaints on forums point at *fragmentation*, not any single missing feature.\n",
    "- Booking friction is the most cited pain point\n- Payment reconciliation eats several hours a week\n- Access control integration is a common deal-breaker\n",
    "```\nsource: reddit.com/r/gymowners\nclaims: 3\n```\n",
    "## Competitor notes\n",
    "Glofox and TeamUp dominate mid-market UK gyms, but reviewers frequently mention `onboarding` friction and slow support responses during the first month of use.\n"
  ]

  def run(seconds) do
    Renderer.set_checklist([
      {"Intake", :done},
      {"Research", :active},
      {"Analysis", :pending},
      {"Directions", :pending},
      {"Brief + validation plan", :pending}
    ])

    tool_call("Researcher·1", "web_search(\"independent gym management software UK\")")
    tool_result("10 results · 4 new sources recorded")

    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    stream_loop(deadline, 0)
  end

  defp stream_loop(deadline, index) do
    if System.monotonic_time(:millisecond) >= deadline do
      Renderer.set_checklist([
        {"Intake", :done},
        {"Research", :done},
        {"Analysis", :active},
        {"Directions", :pending},
        {"Brief + validation plan", :pending}
      ])

      :done
    else
      paragraph = Enum.at(@paragraphs, rem(index, length(@paragraphs)))
      stream_paragraph(paragraph, deadline)
      stream_loop(deadline, index + 1)
    end
  end

  defp stream_paragraph(markdown, deadline) do
    tokens = markdown |> String.split(~r/(?<=\s)/) |> Enum.reject(&(&1 == ""))

    Enum.each(tokens, fn token ->
      if System.monotonic_time(:millisecond) < deadline do
        Renderer.stream_token(token)
        Renderer.add_tokens(1)
        Process.sleep(@token_interval_ms)
      end
    end)

    lines = Markdown.to_ansi_lines(markdown, cols() - 1)
    Renderer.commit(lines)
  end

  defp tool_call(who, summary) do
    Renderer.commit(["#{ANSI.cyan()}⏺#{ANSI.reset()} #{who}  #{summary}"])
  end

  defp tool_result(summary) do
    Renderer.commit(["  #{ANSI.faint()}⎿  #{summary}#{ANSI.reset()}"])
  end

  defp cols do
    case Renderer.snapshot() do
      %{cols: c} -> c
      _ -> 80
    end
  rescue
    _ -> 80
  end
end
