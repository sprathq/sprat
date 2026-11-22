defmodule Experiment.Judge do
  @moduledoc "Blind A/B judging of the two final reports for one task (post-processing)."

  alias Experiment.{Codex, Prompts}

  @doc """
  `reports` is `%{"team" => %{report:, verified:}, "solo" => %{...}}` (the shape
  `Experiment.CLI.post_process/4` returns).
  Randomly labels them A/B, calls the judge (no web search), and writes
  `judge.json` + `blind_map.json` under `task_dir`. Returns `{:ok, judge_map, blind_map}`
  or `{:error, reason}`.
  """
  def run(reports, task_dir, schema_path) do
    [config_a, config_b] = Enum.shuffle(Map.keys(reports))
    blind_map = %{"a" => config_a, "b" => config_b}

    prompt =
      Prompts.judge_prompt(
        reports[config_a].report,
        verification_table(reports[config_a].verified),
        reports[config_b].report,
        verification_table(reports[config_b].verified)
      )

    judge_json = Path.join(task_dir, "judge.json")
    events_file = Path.join(task_dir, "judge.events.jsonl")
    blind_map_path = Path.join(task_dir, "blind_map.json")

    File.write!(blind_map_path, JSON.encode!(blind_map))

    case Codex.call_with_retry(prompt,
           schema: schema_path,
           output_file: judge_json,
           events_file: events_file,
           run_dir: task_dir,
           web_search: false,
           kind: :judge
         ) do
      {:ok, %{stage_output: judge}} ->
        File.write!(judge_json, JSON.encode!(judge))
        {:ok, judge, blind_map}

      {:error, _reason} = err ->
        err
    end
  end

  defp verification_table(verified_sources) do
    if verified_sources == [] do
      "(no sources cited)"
    else
      header = "| id | url | status | classification |\n|---|---|---|---|"

      rows =
        Enum.map_join(verified_sources, "\n", fn s ->
          v = s["verification"] || %{}
          "| #{s["id"]} | #{s["url"]} | #{v["status"]} | #{v["classification"]} |"
        end)

      header <> "\n" <> rows
    end
  end
end
