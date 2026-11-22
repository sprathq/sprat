defmodule Sprat.Export do
  @moduledoc """
  The mission export bundle (docs/spec-v1.md §19: "every completed mission
  delivers... research brief and source register, product brief, MVP
  scope, validation experiments, technical notes, task graph, usage and
  cost report including unknown coverage, and a session event export...
  Exported documents include mission ID, generation date, source
  references, version and known limitations. The user can export from the
  TUI without copying text manually").

  One directory per mission (`<base>/<mission_id>/`), always all of:
  `README.md`, `brief.md`, `validation-plan.md`, `research.md`,
  `sources.md`, `usage.csv`, `usage.md`, `events.jsonl`, `artifacts.json`.
  `Sprat.Export.Markdown` does the actual JSON -> Markdown rendering
  (pure, unit tested on fixtures); this module is the DB-touching,
  file-writing half.

  `run/3` refuses to write anything for the three genuinely-nothing-here
  cases (§ honesty over an empty directory) — no mission, no mission in
  this session yet delivered anything, or a mission that failed before
  any artifact was written — but still writes the full bundle for a
  mission that delivered with skipped stages or that failed *after*
  producing partial artifacts, with the gap named in `README.md` rather
  than hidden.
  """

  alias Sprat.Export.Markdown
  alias Sprat.Store.{Artifacts, Claims, Decisions, Missions, Projection, Sources, Tasks, Usage}

  @doc """
  Exports the latest mission in `session_id` into `<base>/<mission_id>/`.
  `base` defaults to `"sprat-export"`. Returns `{:ok, dir}` or
  `{:error, message}` — `message` is always a complete, user-facing
  sentence, never a bare atom.
  """
  def run(store \\ Sprat.Store, session_id, base \\ "sprat-export") do
    case latest_mission(store, session_id) do
      nil ->
        {:error, "No mission yet in this session — nothing to export."}

      mission ->
        export_mission(store, mission, base)
    end
  end

  @doc """
  Whether `/export` would write a bundle right now, without writing
  anything — `{:ok, mission_id}` or `{:error, message}` with the same
  message `run/3` itself would give. `Sprat.Session.ExitSummary` uses this
  so its exit-time hint never promises a bundle `/export` would then
  refuse.
  """
  def preview(store \\ Sprat.Store, session_id) do
    case latest_mission(store, session_id) do
      nil ->
        {:error, "No mission yet — nothing to export."}

      mission ->
        case classify(mission, export_artifacts(store, mission.id)) do
          {:refuse, message} -> {:error, message}
          {:ok, _note} -> {:ok, mission.id}
        end
    end
  end

  defp latest_mission(store, session_id),
    do: store |> Missions.by_session(session_id) |> List.last()

  defp export_mission(store, mission, base) do
    artifacts = export_artifacts(store, mission.id)

    case classify(mission, artifacts) do
      {:refuse, message} ->
        {:error, message}

      {:ok, note} ->
        dir = Path.join(base, mission.id)
        File.mkdir_p!(dir)
        write_bundle(store, dir, mission, artifacts, note)
        {:ok, dir}
    end
  end

  # -- classification: what to write, and the one honest caveat line ----

  defp classify(mission, artifacts) do
    any_content? = Enum.any?(artifacts, &(&1.content != nil))
    failed? = mission.status == "failed"

    cond do
      not any_content? and mission.status in ["active", "paused_budget"] ->
        {:refuse,
         "Mission still running — nothing delivered yet. Try /export again once at least " <>
           "one stage has written an artifact."}

      not any_content? and failed? ->
        {:refuse, "Mission failed before writing anything — nothing to export."}

      not any_content? and mission.status == "cancelled" ->
        {:refuse, "Mission was cancelled before writing anything — nothing to export."}

      failed? ->
        {:ok,
         "Mission failed — this export is a partial record of what was produced before that."}

      mission.status == "completed" ->
        {:ok, nil}

      mission.status == "cancelled" ->
        {:ok, "Mission was abandoned — this export is a partial record of what exists."}

      # Missions written before the Orchestrator recorded a terminal state
      # stay `active` forever, so delivery is inferred from the last stage's
      # artifact. New missions take the branch above.
      delivered?(artifacts) ->
        {:ok, nil}

      true ->
        {:ok, "Mission is still #{mission.status} — this export is a partial record so far."}
    end
  end

  # Both workflow templates end with a validation_plan.
  defp delivered?(artifacts),
    do: Enum.any?(artifacts, &(&1.type == "validation_plan" and &1.content != nil))

  # -- file writers -------------------------------------------------------

  defp write_bundle(store, dir, mission, artifacts, note) do
    sources = Sources.by_mission(store, mission.id)
    sources_by_id = Map.new(sources, &{&1.id, &1})
    claims_with_sources = Claims.by_mission_with_sources(store, mission.id)
    tasks = Tasks.by_mission(store, mission.id)
    usage_records = Usage.by_mission(store, mission.id)
    totals = Usage.totals(usage_records)
    skipped = Enum.filter(artifacts, &Markdown.incomplete?(&1.content))
    decisions = Decisions.by_mission(store, mission.id)
    header = header(mission)

    File.write!(
      Path.join(dir, "README.md"),
      readme(
        header,
        mission,
        artifacts,
        sources,
        claims_with_sources,
        totals,
        skipped,
        decisions,
        note
      )
    )

    File.write!(Path.join(dir, "brief.md"), brief_md(header, mission, artifacts))
    File.write!(Path.join(dir, "validation-plan.md"), validation_plan_md(header, artifacts))

    File.write!(
      Path.join(dir, "research.md"),
      research_md(header, artifacts, sources_by_id)
    )

    File.write!(Path.join(dir, "sources.md"), sources_md(header, sources))
    File.write!(Path.join(dir, "usage.csv"), usage_csv(tasks, usage_records))

    File.write!(
      Path.join(dir, "usage.md"),
      usage_md(header, mission, tasks, usage_records, totals)
    )

    File.write!(Path.join(dir, "events.jsonl"), events_jsonl(store, mission.session_id))
    File.write!(Path.join(dir, "artifacts.json"), artifacts_json(artifacts))

    File.write!(
      Path.join(dir, "decisions.json"),
      decisions |> Enum.map(&Map.from_struct/1) |> JSON.encode!()
    )
  end

  defp header(mission) do
    version = Application.spec(:sprat, :vsn) |> to_string()

    "_Mission `#{mission.id}` — generated #{DateTime.utc_now() |> DateTime.to_iso8601()} — " <>
      "Sprat v#{version}_"
  end

  # -- README.md ----------------------------------------------------------

  defp readme(
         header,
         mission,
         artifacts,
         sources,
         claims_with_sources,
         totals,
         skipped,
         decisions,
         note
       ) do
    by_type = Map.new(artifacts, &{&1.type, &1.content})

    unsupported =
      claims_with_sources |> Enum.count(fn {c, ids} -> ids == [] and not c.is_assumption end)

    unverified_sources = Enum.count(sources, &is_nil(&1.content_hash))

    """
    # Mission: #{mission.objective}

    #{header}

    #{note_line(note)}

    ## Recommendation

    #{Markdown.render("recommendation_memo", by_type["recommendation_memo"])}

    ## Chosen direction

    #{chosen_line(decisions)}

    #{chosen_direction(by_type["product_directions"])}

    ## What was researched

    #{Markdown.render("intake_summary", by_type["intake_summary"])}

    ## Cost

    - Total: #{cost_word(totals.cost)}
    - Model calls: #{totals.calls}
    - Pricing version: #{pricing_note(mission, totals)}

    ## Limitations

    - #{length(skipped)} stage(s) skipped: #{skipped_names(skipped)}
    - No live search beyond what the source register below records
    - #{unverified_sources} of #{length(sources)} source(s) have no recorded content hash (unverified)
    - #{unsupported} claim(s) have no supporting source recorded

    ## In this export

    - `brief.md` — the product brief and MVP scope
    - `validation-plan.md` — the validation experiments
    - `research.md` — the research memo with claims and sources
    - `sources.md` — the source register
    - `usage.csv` / `usage.md` — per-stage and total cost
    - `events.jsonl` — the redacted event export
    - `artifacts.json` — the raw structured artifacts
    """
  end

  defp note_line(nil), do: ""
  defp note_line(note), do: "**Note:** #{note}\n"

  defp chosen_direction(nil), do: Markdown.render("product_directions", nil)
  defp chosen_direction(content), do: Markdown.render("product_directions", content)

  # `product_directions` itself only ever holds the 1-3 candidates a
  # stage proposed — which one the user actually picked lives in
  # `Sprat.Store.Decisions`, recorded as free text at the moment of
  # choice (`Sprat.Orchestrator.user_choice/2`). Neither replaces the
  # other: the decision names the choice, the directions below show what
  # else was considered and why.
  defp chosen_line([]), do: "_No recorded decision — every direction below was still open._"

  defp chosen_line(decisions),
    do: Enum.map_join(decisions, "\n", &"**Chosen:** #{&1.summary}")

  defp skipped_names([]), do: "none"
  defp skipped_names(skipped), do: Enum.map_join(skipped, ", ", & &1.type)

  defp cost_word(nil), do: "unknown"
  defp cost_word(%Decimal{} = d), do: "$#{Decimal.round(d, 4)}"

  defp pricing_note(_mission, %{calls: 0}), do: "n/a — no calls recorded"

  defp pricing_note(_mission, _totals), do: "see usage.md"

  # -- brief.md / validation-plan.md / research.md / sources.md -----------

  defp brief_md(header, mission, artifacts) do
    by_type = Map.new(artifacts, &{&1.type, &1.content})

    """
    # Product brief — #{mission.objective}

    #{header}

    ## Brief

    #{Markdown.render("product_brief", by_type["product_brief"])}

    ## MVP scope and directions considered

    #{Markdown.render("product_directions", by_type["product_directions"])}
    """
  end

  defp validation_plan_md(header, artifacts) do
    content = artifacts |> Enum.find(&(&1.type == "validation_plan")) |> then(&(&1 && &1.content))

    """
    # Validation plan

    #{header}

    #{Markdown.render("validation_plan", content)}
    """
  end

  defp research_md(header, artifacts, sources_by_id) do
    content = artifacts |> Enum.find(&(&1.type == "research_memo")) |> then(&(&1 && &1.content))

    """
    # Research memo

    #{header}

    #{Markdown.research_memo(content, sources_by_id)}
    """
  end

  defp sources_md(header, sources) do
    rows =
      if sources == [] do
        "_no sources recorded_"
      else
        Enum.map_join(sources, "\n\n", fn s ->
          """
          ### #{s.title || s.url}

          - URL: #{s.url}
          - Publisher: #{na(s.publisher)}
          - Retrieved: #{na(s.retrieved_at)}
          - Verification status: not tracked by this build (no field recorded)
          - Content hash: #{na(s.content_hash)}
          """
        end)
      end

    "# Source register\n\n#{header}\n\n#{rows}"
  end

  defp na(nil), do: "_not recorded_"
  defp na(""), do: "_not recorded_"
  defp na(v), do: v

  # -- usage.csv / usage.md ------------------------------------------------

  defp usage_csv(tasks, usage_records) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    by_task = Enum.group_by(usage_records, & &1.task_id)

    header = "stage,role,calls,cost_usd,input_tokens,output_tokens,pricing_version,coverage\n"

    rows =
      Enum.map_join(by_task, "", fn {task_id, records} ->
        task = Map.get(tasks_by_id, task_id)
        t = Usage.totals(records)
        pricing = records |> Enum.map(& &1.pricing_version) |> Enum.uniq() |> unknown_join()
        coverage = records |> Enum.map(& &1.coverage) |> Enum.uniq() |> Enum.join("|")

        [
          csv_field(task && stage_word(task)),
          csv_field(task && task.role),
          t.calls,
          csv_field(t.cost && Decimal.to_string(t.cost)),
          t.input_tokens || "unknown",
          t.output_tokens || "unknown",
          csv_field(pricing),
          csv_field(coverage)
        ]
        |> Enum.join(",")
        |> Kernel.<>("\n")
      end)

    header <> rows
  end

  defp unknown_join([nil]), do: "unknown"
  defp unknown_join(list), do: list |> Enum.map(&(&1 || "unknown")) |> Enum.join("|")

  defp csv_field(nil), do: "\"unknown\""
  defp csv_field(v), do: "\"#{v |> to_string() |> String.replace("\"", "\"\"")}\""

  defp usage_md(header, mission, tasks, usage_records, totals) do
    tasks_by_id = Map.new(tasks, &{&1.id, &1})
    by_task = Enum.group_by(usage_records, & &1.task_id)

    rows =
      Enum.map_join(by_task, "\n", fn {task_id, records} ->
        task = Map.get(tasks_by_id, task_id)
        t = Usage.totals(records)

        "| #{stage_word(task)} | #{t.calls} | #{cost_word(t.cost)} | " <>
          "#{tok(t.input_tokens)} | #{tok(t.output_tokens)} | #{coverage_word(records)} |"
      end)

    """
    # Usage and cost — #{mission.objective}

    #{header}

    | Stage | Calls | Cost | Input tokens | Output tokens | Coverage |
    |---|---|---|---|---|---|
    #{rows}
    | **Total** | **#{totals.calls}** | **#{cost_word(totals.cost)}** | **#{tok(totals.input_tokens)}** | **#{tok(totals.output_tokens)}** | — |

    Coverage is `reported` (from the provider), `estimated`, or `unavailable` — an
    unavailable/estimated figure is shown as such, never rounded into the total as
    if it were a known zero (docs/spec-v1.md §12).
    """
  end

  defp stage_word(nil), do: "(unknown stage)"

  # `task.objective` can carry an embedded `\n\nUser's choice after...`
  # suffix (`Sprat.Orchestrator` folds the user's Directions answer into
  # the next stage's objective text) — a literal newline inside a
  # Markdown table cell breaks the row, so only the first line names the
  # stage here; the full objective is still in `tasks.json`/the task tree
  # (`/tasks`), never lost, just not repeated into every table cell.
  defp stage_word(task), do: task.objective |> String.split("\n", parts: 2) |> hd()

  defp tok(nil), do: "unknown"
  defp tok(n), do: to_string(n)

  defp coverage_word(records) do
    records |> Enum.map(& &1.coverage) |> Enum.uniq() |> Enum.join(", ")
  end

  # -- events.jsonl / artifacts.json ---------------------------------------

  defp events_jsonl(store, session_id) do
    store
    |> Projection.session_events(session_id)
    |> Enum.map_join("\n", fn event ->
      event
      |> Map.from_struct()
      |> Map.update!(:payload, fn
        nil -> nil
        payload -> JSON.decode!(payload)
      end)
      |> JSON.encode!()
    end)
    |> Kernel.<>("\n")
  end

  defp artifacts_json(artifacts), do: JSON.encode!(artifacts)

  defp export_artifacts(store, mission_id),
    do: Artifacts.by_mission_with_content(store, mission_id)
end
