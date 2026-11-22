defmodule Experiment.Prompts do
  @moduledoc "Assembles the text sent to codex for each stage/solo/judge call."

  @dir Path.join(__DIR__, "../prompts") |> Path.expand()

  def read(relative_path), do: File.read!(Path.join(@dir, relative_path))

  def honesty_rules, do: read("_honesty_rules.md")
  def output_schema_doc, do: read("_output_schema.md")
  def final_report_sections, do: read("_final_report_sections.md")
  def scorecard_doc, do: read("_scorecard.md")
  def role(name), do: read("roles/#{name}.md")
  def stage(workflow, name), do: read("stages/#{workflow}/#{name}.md")
  def solo(workflow), do: read("solo/#{workflow}.md")
  def judge, do: read("judge.md")

  # ponytail: compact prior artifacts are truncated to this many characters of
  # their markdown before the source index, to bound prompt growth. Full
  # artifacts (the stage's direct predecessor(s), per Workflow's `full_from`)
  # are never truncated.
  @compact_excerpt_chars 1200

  @doc """
  Build a team stage prompt: role persona, stage instructions (with {{N}}
  substituted for parallel research/landscape stages), shared honesty rules,
  the output schema doc, the scorecard doc (discovery hypotheses stage
  only), the final report sections (final stage only), the task brief, and
  prior stage artifacts — full for the stage's direct predecessor(s), a
  compact handoff + source index for everything further back (see
  `Workflow`'s per-stage `full_from` list, and 01-experiment-design.md's
  "Slimming the team pipeline" section for why).
  """
  def team_stage(opts) do
    role = Keyword.fetch!(opts, :role)
    stage_text = Keyword.fetch!(opts, :stage_text)
    task = Keyword.fetch!(opts, :task)
    prior_stages = Keyword.get(opts, :prior_stages, [])
    final? = Keyword.get(opts, :final?, false)
    needs_scorecard? = Keyword.get(opts, :needs_scorecard?, false)
    angle_n = Keyword.get(opts, :angle_n)

    stage_text =
      if angle_n,
        do: String.replace(stage_text, "{{N}}", Integer.to_string(angle_n)),
        else: stage_text

    [
      role(role),
      "",
      stage_text,
      "",
      honesty_rules(),
      "",
      output_schema_doc(),
      needs_scorecard? && "\n" <> scorecard_doc(),
      final? && "\n" <> final_report_sections(),
      "",
      "## Task brief",
      "",
      task.brief_markdown,
      "",
      prior_artifacts_section(prior_stages)
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join("\n")
  end

  @doc "Build a solo prompt: single-agent workflow walkthrough + shared rules + task brief."
  def solo_prompt(workflow, task) do
    [
      solo(workflow),
      "",
      honesty_rules(),
      "",
      output_schema_doc(),
      workflow == :discovery && "\n" <> scorecard_doc(),
      "\n" <> final_report_sections(),
      "",
      "## Task brief",
      "",
      task.brief_markdown
    ]
    |> Enum.reject(&(&1 == false))
    |> Enum.join("\n")
  end

  @doc "Build the judge prompt from two labelled reports and their source verification tables."
  def judge_prompt(report_a, verify_table_a, report_b, verify_table_b) do
    [
      judge(),
      "",
      "## Report A",
      "",
      report_a,
      "",
      "## Report A — source verification",
      "",
      verify_table_a,
      "",
      "## Report B",
      "",
      report_b,
      "",
      "## Report B — source verification",
      "",
      verify_table_b
    ]
    |> Enum.join("\n")
  end

  defp prior_artifacts_section([]), do: ""

  defp prior_artifacts_section(prior_stages) do
    body = Enum.map_join(prior_stages, "\n\n", &render_prior_stage/1)
    "## Prior artifacts\n\n" <> body
  end

  # `prior_stages` entries are `{name, output, :full | :compact}` — see
  # `Workflow.prior_stages_for/2`.
  defp render_prior_stage({name, output, :full}) do
    """
    ### #{name} (full)

    #{output["artifact_markdown"]}

    **Handoff:** #{output["handoff"]}

    **Sources cited:**
    #{source_index(output["sources"])}
    """
  end

  defp render_prior_stage({name, output, :compact}) do
    excerpt = String.slice(output["artifact_markdown"] || "", 0, @compact_excerpt_chars)
    truncated? = String.length(output["artifact_markdown"] || "") > @compact_excerpt_chars

    """
    ### #{name} (compact — handoff, key findings excerpt, source index only)

    **Handoff:** #{output["handoff"]}

    **Key findings (excerpt):** #{excerpt}#{if truncated?, do: "…[truncated]", else: ""}

    **Sources cited:**
    #{source_index(output["sources"])}
    """
  end

  defp source_index([]), do: "(none)"

  defp source_index(sources) do
    Enum.map_join(sources, "\n", fn s ->
      "- #{s["id"]}: #{s["title"]} (#{s["url"]}) — supports: #{Enum.join(s["supports"] || [], "; ")}"
    end)
  end
end
