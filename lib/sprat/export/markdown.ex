defmodule Sprat.Export.Markdown do
  @moduledoc """
  Pure artifact-JSON -> Markdown rendering (docs/spec-v1.md §19: "Markdown
  is the default human-readable format"). No store access, no IO — every
  function takes already-decoded content (string-keyed map, normalized to
  its canonical field names by `Sprat.Workflow.ArtifactSchema.normalize/2`
  before it was ever stored) and returns plain text, so it is unit
  testable with fixtures alone.

  Rendering never invents content: a field that is absent or blank prints
  as `#{inspect("_not recorded_")}` rather than being silently dropped, and a
  skipped-stage placeholder (`%{"incomplete" => true, "reason" => ...}`,
  `Sprat.Orchestrator`'s skip escape hatch) renders as an explicit notice,
  never as an empty or misleadingly-normal section.
  """

  @na "_not recorded_"

  @doc "True for a skipped stage's placeholder content."
  def incomplete?(content) when is_map(content), do: content["incomplete"] == true
  def incomplete?(_), do: false

  @doc "One-line summary for an artifact list row (`/artifacts`, the TUI Detail card title)."
  def summary(_type, content) when not is_map(content), do: "(no content)"

  def summary(type, content) do
    if incomplete?(content) do
      "skipped — #{content["reason"] || "no reason recorded"}"
    else
      do_summary(type, content)
    end
  end

  defp do_summary("intake_summary", c), do: truncate(field(c, "objective"))
  defp do_summary("research_memo", c), do: truncate(field(c, "summary"))
  defp do_summary("source_register", c), do: "#{count(c, "sources")} source(s)"
  defp do_summary("assumption_register", c), do: "#{count(c, "assumptions")} assumption(s)"
  defp do_summary("product_directions", c), do: "#{count(c, "directions")} direction(s)"

  defp do_summary("recommendation_memo", c),
    do: "recommendation: #{field(c, "recommendation")}"

  defp do_summary("product_brief", c), do: truncate(field(c, "problem"))
  defp do_summary("validation_plan", c), do: "#{count(c, "experiments")} experiment(s)"
  defp do_summary("competitor_matrix", c), do: "#{count(c, "competitors")} competitor(s)"
  defp do_summary("opportunity_scorecard", c), do: "total #{field(c, "total")}"
  defp do_summary(_type, _c), do: "(artifact)"

  @doc """
  Full Markdown body for one artifact's content (no heading — callers
  supply their own `#`/`##` level). Falls back to a generic key/value
  bullet render for a type this module has no dedicated renderer for, so
  every artifact type is always representable, not just the ten
  `ArtifactSchema` knows.
  """
  def render(type, content) do
    cond do
      not is_map(content) -> "_no content recorded_"
      incomplete?(content) -> "**Skipped.** #{content["reason"] || @na}"
      true -> do_render(type, content)
    end
  end

  defp do_render("intake_summary", c) do
    """
    **Objective:** #{field(c, "objective")}

    **Depth:** #{field(c, "depth")}

    **Open questions / assumptions:**
    #{bullet_list(c["open_questions"])}
    """
  end

  defp do_render("research_memo", c) do
    """
    #{field(c, "summary")}

    **Claims:**
    #{claim_list(c["claims"])}

    **Limitations:** #{stringify(c["limitations"])}
    """
  end

  defp do_render("source_register", c) do
    (c["sources"] || [])
    |> list_or_na()
    |> case do
      @na -> @na
      sources -> Enum.map_join(sources, "\n", &"- [#{field(&1, "title")}](#{field(&1, "url")})")
    end
  end

  defp do_render("assumption_register", c) do
    (c["assumptions"] || [])
    |> list_or_na()
    |> case do
      @na -> @na
      items -> Enum.map_join(items, "\n", &"- (#{field(&1, "risk")}) #{field(&1, "text")}")
    end
  end

  defp do_render("product_directions", c) do
    (c["directions"] || [])
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {d, i} ->
      """
      **Direction #{i} — #{field(d, "customer")}**
      - Problem: #{field(d, "problem")}
      - Value: #{field(d, "value")}
      - Scope: #{field(d, "scope")}
      - Validation approach: #{field(d, "validation_approach")}
      """
    end)
    |> blank_to_na()
  end

  defp do_render("recommendation_memo", c) do
    """
    **Recommendation:** #{field(c, "recommendation")}

    **Tradeoffs:** #{field(c, "tradeoffs")}

    **Evidence:** #{id_list(c["evidence"])}
    """
  end

  defp do_render("product_brief", c) do
    """
    **Customer:** #{field(c, "customer")}

    **Problem:** #{field(c, "problem")}

    **MVP scope:** #{field(c, "mvp_scope")}
    """
  end

  defp do_render("validation_plan", c) do
    (c["experiments"] || [])
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {e, i} ->
      """
      **Experiment #{i} — #{field(e, "assumption")}**
      - Method: #{field(e, "method")}
      - Participants: #{field(e, "participant_criteria")}
      - Budget: #{field(e, "budget")}  Duration: #{field(e, "duration")}
      - Success: #{field(e, "success_threshold")}
      - Failure: #{field(e, "failure_threshold")}
      - Decision: #{field(e, "decision")}
      """
    end)
    |> blank_to_na()
  end

  defp do_render("competitor_matrix", c) do
    (c["competitors"] || [])
    |> list_or_na()
    |> case do
      @na ->
        @na

      items ->
        Enum.map_join(items, "\n", fn m ->
          "- **#{field(m, "name")}** — strengths: #{field(m, "strengths")}; weaknesses: #{field(m, "weaknesses")}"
        end)
    end
  end

  defp do_render("opportunity_scorecard", c) do
    dims =
      (c["dimensions"] || [])
      |> list_or_na()
      |> case do
        @na -> @na
        items -> Enum.map_join(items, "\n", &"- #{field(&1, "name")}: #{field(&1, "rating")}")
      end

    "**Total:** #{field(c, "total")}\n\n#{dims}"
  end

  defp do_render(_type, content), do: generic_render(content)

  @doc "Generic key/value bullet render for content this module has no dedicated renderer for — never drops a field, never invents one."
  def generic_render(content) when is_map(content) do
    content
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("\n", fn {k, v} -> "- **#{k}:** #{stringify(v)}" end)
    |> blank_to_na()
  end

  def generic_render(_), do: @na

  # -- shared helpers ---------------------------------------------------

  defp field(map, key) when is_map(map), do: map |> Map.get(key) |> stringify()
  defp field(_map, _key), do: @na

  defp count(map, key), do: map |> Map.get(key) |> List.wrap() |> length()

  defp stringify(nil), do: @na
  defp stringify(""), do: @na
  defp stringify([]), do: @na
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_list(v), do: Enum.map_join(v, "; ", &stringify/1)
  defp stringify(v) when is_number(v), do: to_string(v)
  defp stringify(v) when is_boolean(v), do: to_string(v)
  defp stringify(v) when is_map(v), do: Map.get(v, "text") || JSON.encode!(v)
  defp stringify(v), do: inspect(v)

  defp bullet_list(nil), do: @na
  defp bullet_list([]), do: @na

  defp bullet_list(items) when is_list(items),
    do: Enum.map_join(items, "\n", &"- #{stringify(&1)}")

  defp bullet_list(other), do: stringify(other)

  defp id_list(nil), do: @na
  defp id_list([]), do: @na
  defp id_list(ids) when is_list(ids), do: Enum.join(ids, ", ")
  defp id_list(other), do: stringify(other)

  defp list_or_na(list) when is_list(list) and list != [], do: list
  defp list_or_na(_), do: @na

  defp blank_to_na(""), do: @na
  defp blank_to_na(s), do: s

  defp truncate(@na), do: @na

  defp truncate(s) when is_binary(s) do
    if String.length(s) > 120, do: String.slice(s, 0, 117) <> "...", else: s
  end

  defp truncate(other), do: stringify(other)

  # -- research.md's richer rendering: claims with sources as inline links
  #
  # `research_memo`'s own `claims` list only carries `source_ids` (plain
  # strings) — the human-readable title/URL those ids resolve to lives in
  # the mission's separate source register, which this pure module never
  # touches. `Sprat.Export` passes the resolved `%{id => source}` map in
  # so a claim's sources render as real Markdown links, not bare ids.

  @doc """
  `research_memo` content rendered with each claim's sources resolved to
  Markdown links via `sources_by_id` (`%{source_id => %Sprat.Store.Sources{}}`).
  A source id with no matching source (already deleted, or never recorded)
  prints the bare id instead of a broken link — still visible, never hidden.
  """
  def research_memo(content, _sources_by_id) when not is_map(content), do: "_no content recorded_"

  def research_memo(content, sources_by_id) do
    if incomplete?(content) do
      "**Skipped.** #{content["reason"] || @na}"
    else
      """
      #{field(content, "summary")}

      **Claims:**
      #{claim_list(content["claims"], sources_by_id)}

      **Limitations:** #{stringify(content["limitations"])}
      """
    end
  end

  defp claim_list(claims, sources_by_id \\ %{})
  defp claim_list(nil, _), do: @na
  defp claim_list([], _), do: @na

  defp claim_list(claims, sources_by_id) when is_list(claims) do
    Enum.map_join(claims, "\n", fn claim ->
      text = field(claim, "text")

      refs =
        (claim["source_ids"] || [])
        |> List.wrap()
        |> Enum.map(&claim_source_link(&1, sources_by_id))

      suffix =
        cond do
          claim["is_assumption"] -> " _(assumption)_"
          refs == [] -> " _(unsupported — no source)_"
          true -> " (" <> Enum.join(refs, ", ") <> ")"
        end

      "- #{text}#{suffix}"
    end)
  end

  defp claim_source_link(source_id, sources_by_id) do
    case Map.get(sources_by_id, source_id) do
      nil -> source_id
      source -> "[#{source.title || source.url}](#{source.url})"
    end
  end
end
