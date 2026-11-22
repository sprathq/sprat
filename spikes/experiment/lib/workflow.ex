defmodule Experiment.Workflow do
  @moduledoc "Team stage graphs (§5) and their execution against a task."

  alias Experiment.{Codex, Prompts}

  # `full_from`: names of prior stages inlined in full (this stage's direct
  # predecessor(s) — what it's actually built to read closely). Every other
  # already-run stage is inlined compact (handoff + excerpt + source index).
  # `web_search`: only Researcher-role stages get `-c web_search="live"` —
  # matching spec §4's tool table (PM and Analyst are not given web search).
  # See 01-experiment-design.md "Slimming the team pipeline" for why.
  @idea_waves [
    [%{name: "pm_intake", role: "pm", stage_file: "pm_intake", full_from: []}],
    [
      %{
        name: "research_a",
        role: "researcher",
        stage_file: "research",
        angle_n: 1,
        full_from: ["pm_intake"]
      },
      %{
        name: "research_b",
        role: "researcher",
        stage_file: "research",
        angle_n: 2,
        full_from: ["pm_intake"]
      }
    ],
    [
      %{
        name: "analysis",
        role: "analyst",
        stage_file: "analysis",
        full_from: ["research_a", "research_b"]
      }
    ],
    [%{name: "pm_directions", role: "pm", stage_file: "pm_directions", full_from: ["analysis"]}],
    [
      %{
        name: "analyst_recommendation",
        role: "analyst",
        stage_file: "analyst_recommendation",
        full_from: ["pm_directions"]
      }
    ],
    [
      %{
        name: "pm_brief",
        role: "pm",
        stage_file: "pm_brief",
        final?: true,
        full_from: ["pm_directions", "analyst_recommendation"]
      }
    ]
  ]

  @discovery_waves [
    [%{name: "pm_intake", role: "pm", stage_file: "pm_intake", full_from: []}],
    [
      %{
        name: "landscape_a",
        role: "researcher",
        stage_file: "landscape",
        angle_n: 1,
        full_from: ["pm_intake"]
      },
      %{
        name: "landscape_b",
        role: "researcher",
        stage_file: "landscape",
        angle_n: 2,
        full_from: ["pm_intake"]
      }
    ],
    [
      %{
        name: "hypotheses_scoring",
        role: "analyst",
        stage_file: "hypotheses_scoring",
        needs_scorecard?: true,
        full_from: ["landscape_a", "landscape_b"]
      }
    ],
    [
      %{
        name: "counter_evidence",
        role: "researcher",
        stage_file: "counter_evidence",
        full_from: ["hypotheses_scoring"]
      }
    ],
    [
      %{
        name: "analyst_recommendation",
        role: "analyst",
        stage_file: "analyst_recommendation",
        full_from: ["hypotheses_scoring", "counter_evidence"]
      }
    ],
    [
      %{
        name: "pm_validation_plan",
        role: "pm",
        stage_file: "pm_validation_plan",
        final?: true,
        full_from: ["hypotheses_scoring", "analyst_recommendation"]
      }
    ]
  ]

  def waves(:idea), do: @idea_waves
  def waves(:discovery), do: @discovery_waves

  @doc """
  Run every wave of the task's workflow in order, waves in parallel within
  themselves, under the shared global semaphore. Returns a result map with
  `:stages` (ordered list of `{name, output}`), `:usages`, `:web_search`,
  `:failures` (stage names that failed both attempts) and `:final` (the
  last stage's output, or nil if it never produced one).
  """
  def run(task, config_dir, schema_path) do
    File.mkdir_p!(Path.join(config_dir, "stages"))
    File.mkdir_p!(Path.join(config_dir, "events"))

    waves(task.workflow)
    |> Enum.reduce(
      %{stages: [], usages: [], web_search_calls: 0, web_search_queries: [], failures: []},
      fn wave, acc ->
        results =
          wave
          |> Task.async_stream(&run_stage(&1, task, config_dir, schema_path, acc.stages),
            timeout: :infinity,
            max_concurrency: length(wave)
          )
          |> Enum.map(fn {:ok, result} -> result end)

        Enum.reduce(results, acc, fn
          {:ok, name, output, usage, ws_calls, ws_queries}, acc ->
            %{
              acc
              | stages: acc.stages ++ [{name, output}],
                usages: acc.usages ++ [usage],
                web_search_calls: acc.web_search_calls + ws_calls,
                web_search_queries: acc.web_search_queries ++ ws_queries
            }

          {:error, name, _reason}, acc ->
            %{acc | failures: acc.failures ++ [name]}
        end)
      end
    )
    |> then(fn acc ->
      Map.put(acc, :final, acc.stages |> List.last() |> then(&(&1 && elem(&1, 1))))
    end)
  end

  defp run_stage(spec, task, config_dir, schema_path, prior_stages) do
    stage_json = Path.join([config_dir, "stages", "#{spec.name}.json"])
    events_file = Path.join([config_dir, "events", "#{spec.name}.jsonl"])
    usage_file = Path.join([config_dir, "stages", "#{spec.name}.usage.json"])

    if File.exists?(stage_json) and File.exists?(usage_file) do
      output = stage_json |> File.read!() |> JSON.decode!()
      usage = usage_file |> File.read!() |> JSON.decode!()

      {:ok, spec.name, output, usage["usage"], usage["web_search_calls"],
       usage["web_search_queries"]}
    else
      prompt =
        Prompts.team_stage(
          role: spec.role,
          stage_text: Prompts.stage(task.workflow, spec.stage_file),
          task: task,
          prior_stages: tag_prior_stages(prior_stages, spec.full_from),
          final?: Map.get(spec, :final?, false),
          needs_scorecard?: Map.get(spec, :needs_scorecard?, false),
          angle_n: Map.get(spec, :angle_n)
        )

      web_search? = spec.role == "researcher"

      run_codex(
        prompt,
        stage_json,
        events_file,
        usage_file,
        config_dir,
        schema_path,
        spec.name,
        web_search?
      )
    end
  end

  defp tag_prior_stages(prior_stages, full_from) do
    Enum.map(prior_stages, fn {name, output} ->
      mode = if name in full_from, do: :full, else: :compact
      {name, output, mode}
    end)
  end

  @doc "Run one solo call for a task (single stage: `solo`), same resume/retry semantics as a team stage."
  def run_solo(task, config_dir, schema_path) do
    File.mkdir_p!(Path.join(config_dir, "stages"))
    File.mkdir_p!(Path.join(config_dir, "events"))

    stage_json = Path.join([config_dir, "stages", "solo.json"])
    events_file = Path.join([config_dir, "events", "solo.jsonl"])
    usage_file = Path.join([config_dir, "stages", "solo.usage.json"])

    result =
      if File.exists?(stage_json) and File.exists?(usage_file) do
        output = stage_json |> File.read!() |> JSON.decode!()
        usage = usage_file |> File.read!() |> JSON.decode!()

        {:ok, "solo", output, usage["usage"], usage["web_search_calls"],
         usage["web_search_queries"]}
      else
        prompt = Prompts.solo_prompt(task.workflow, task)

        run_codex(
          prompt,
          stage_json,
          events_file,
          usage_file,
          config_dir,
          schema_path,
          "solo",
          true
        )
      end

    case result do
      {:ok, name, output, usage, ws_calls, ws_queries} ->
        %{
          stages: [{name, output}],
          usages: [usage],
          web_search_calls: ws_calls,
          web_search_queries: ws_queries,
          failures: [],
          final: output
        }

      {:error, name, _reason} ->
        %{
          stages: [],
          usages: [],
          web_search_calls: 0,
          web_search_queries: [],
          failures: [name],
          final: nil
        }
    end
  end

  defp run_codex(
         prompt,
         stage_json,
         events_file,
         usage_file,
         config_dir,
         schema_path,
         name,
         web_search?
       ) do
    Experiment.Semaphore.with_permit(fn ->
      case Codex.call_with_retry(prompt,
             schema: schema_path,
             output_file: stage_json,
             events_file: events_file,
             run_dir: config_dir,
             web_search: web_search?
           ) do
        {:ok,
         %{
           stage_output: output,
           usage: usage,
           web_search_calls: ws_calls,
           web_search_queries: ws_queries
         }} ->
          File.write!(stage_json, JSON.encode!(output))

          File.write!(
            usage_file,
            JSON.encode!(%{
              usage: usage,
              web_search_calls: ws_calls,
              web_search_queries: ws_queries
            })
          )

          {:ok, name, output, usage, ws_calls, ws_queries}

        {:error, reason} ->
          IO.puts(:stderr, "stage #{name} failed: #{inspect(reason)}")
          {:error, name, reason}
      end
    end)
  end
end
