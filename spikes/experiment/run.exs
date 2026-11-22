Mix.install([{:req, "~> 0.5"}])

root = __DIR__
Code.require_file(Path.join(root, "lib/pure.ex"))
Code.require_file(Path.join(root, "lib/semaphore.ex"))
Code.require_file(Path.join(root, "lib/codex.ex"))
Code.require_file(Path.join(root, "lib/tasks.ex"))
Code.require_file(Path.join(root, "lib/prompts.ex"))
Code.require_file(Path.join(root, "lib/workflow.ex"))
Code.require_file(Path.join(root, "lib/sources.ex"))
Code.require_file(Path.join(root, "lib/judge.ex"))
Code.require_file(Path.join(root, "lib/summary.ex"))

defmodule Experiment.CLI do
  @moduledoc "Entry point: `elixir run.exs [--tasks 01,02] [--configs team,solo] [--skip-judge] [--resume DIR] [--concurrency N]`"

  alias Experiment.{Judge, Pure, Semaphore, Sources, Summary, Tasks, Workflow}

  @root Path.expand(__DIR__)
  @stage_schema Path.join(@root, "schemas/stage.json")
  @judge_schema Path.join(@root, "schemas/judge.json")

  def main(argv) do
    opts = parse_args(argv)

    run_dir =
      opts[:resume] ||
        Path.join(@root, "runs/#{DateTime.utc_now() |> DateTime.to_iso8601(:basic)}")

    File.mkdir_p!(run_dir)
    {:ok, _} = Semaphore.start_link(opts[:concurrency])

    IO.puts("Run dir: #{run_dir}")

    baseline_per_call = measure_baseline(run_dir)
    IO.puts("Baseline per call: #{baseline_per_call} tokens")

    all_tasks = Tasks.load_all(Path.join(@root, "tasks"))
    tasks = if opts[:tasks], do: Enum.filter(all_tasks, &(&1.id in opts[:tasks])), else: all_tasks

    IO.puts(
      "Tasks: #{Enum.map_join(tasks, ", ", & &1.id)} | configs: #{Enum.join(opts[:configs], ", ")}"
    )

    task_results =
      tasks
      |> Task.async_stream(&run_task(&1, run_dir, opts, baseline_per_call),
        timeout: :infinity,
        max_concurrency: length(tasks)
      )
      |> Enum.map(fn {:ok, result} -> result end)

    summary = Summary.build(task_results, baseline_per_call)
    File.write!(Path.join(run_dir, "summary.md"), summary)
    IO.puts("\n" <> summary)
  end

  defp run_task(task, run_dir, opts, baseline_per_call) do
    task_dir = Path.join(run_dir, task.id)
    File.mkdir_p!(task_dir)

    config_data =
      for config <- opts[:configs], into: %{} do
        {config, run_config(task, config, task_dir, baseline_per_call)}
      end

    {judge, blind_map} =
      if (not opts[:skip_judge] and Map.has_key?(config_data, "team") and
            Map.has_key?(config_data, "solo") and
            config_data["team"].report) && config_data["solo"].report do
        run_judge(task, task_dir, config_data)
      else
        {nil, nil}
      end

    %{
      id: task.id,
      workflow: task.workflow,
      team: to_summary_entry(config_data["team"]),
      solo: to_summary_entry(config_data["solo"]),
      judge: judge,
      judge_blind_map: blind_map
    }
  end

  defp run_config(task, "team", task_dir, baseline_per_call) do
    config_dir = Path.join(task_dir, "team")
    result = Workflow.run(task, config_dir, @stage_schema)

    post_process(
      result,
      config_dir,
      length(Workflow.waves(task.workflow) |> List.flatten()),
      baseline_per_call
    )
  end

  defp run_config(task, "solo", task_dir, baseline_per_call) do
    config_dir = Path.join(task_dir, "solo")
    result = Workflow.run_solo(task, config_dir, @stage_schema)
    post_process(result, config_dir, 1, baseline_per_call)
  end

  defp post_process(result, config_dir, call_count, baseline_per_call) do
    merged_sources =
      result.stages
      |> Enum.map(fn {name, output} -> {name, output["sources"]} end)
      |> Pure.merge_and_dedup_sources()

    verified = Sources.verify_all(merged_sources, Path.join(config_dir, "snapshots"))
    File.write!(Path.join(config_dir, "sources.verified.json"), JSON.encode!(verified))

    final_markdown = result.final && result.final["artifact_markdown"]

    final_source_ids =
      if result.final, do: Enum.map(result.final["sources"], & &1["id"]), else: []

    dangling =
      if final_markdown, do: Pure.dangling_citations(final_markdown, final_source_ids), else: []

    usage_totals = Pure.sum_usage(result.usages)
    raw_total = usage_totals["total_tokens"]
    adjusted_total = Pure.baseline_adjusted(raw_total, baseline_per_call, call_count)

    usage_json = %{
      "raw" => usage_totals,
      "tokens_raw" => raw_total,
      "tokens_adjusted" => adjusted_total,
      "calls" => call_count,
      "failures" => result.failures,
      "web_search_calls" => result.web_search_calls,
      "web_search_queries" => result.web_search_queries,
      "dangling_citations" => dangling
    }

    File.write!(Path.join(config_dir, "usage.json"), JSON.encode!(usage_json))
    if final_markdown, do: File.write!(Path.join(config_dir, "report.md"), final_markdown)

    # sources actually cited in the final report, joined against the verified table, for the judge.
    final_verified =
      if result.final do
        Enum.map(result.final["sources"], fn s ->
          key = Pure.normalize_url(s["url"])
          verification = Enum.find(verified, &(&1["normalized_url"] == key))
          Map.put(s, "verification", verification && verification["verification"])
        end)
      else
        []
      end

    %{
      tokens_raw: raw_total,
      tokens_adjusted: adjusted_total,
      calls: call_count,
      failures: result.failures,
      report: final_markdown,
      verified: final_verified
    }
  end

  defp to_summary_entry(nil), do: %{}

  defp to_summary_entry(data),
    do: Map.take(data, [:tokens_raw, :tokens_adjusted, :calls, :failures])

  defp run_judge(task, task_dir, config_data) do
    reports = %{"team" => config_data["team"], "solo" => config_data["solo"]}

    case Judge.run(reports, task_dir, @judge_schema) do
      {:ok, judge, blind_map} ->
        {judge, blind_map}

      {:error, reason} ->
        IO.puts(:stderr, "judge failed for #{task.id}: #{inspect(reason)}")
        {nil, nil}
    end
  end

  defp measure_baseline(run_dir) do
    baseline_dir = Path.join(run_dir, "_baseline")
    File.mkdir_p!(baseline_dir)
    output_file = Path.join(baseline_dir, "out.json")
    events_file = Path.join(baseline_dir, "events.jsonl")
    usage_file = Path.join(baseline_dir, "usage.json")

    if File.exists?(usage_file) do
      usage_file |> File.read!() |> JSON.decode!() |> Map.fetch!("tokens")
    else
      prompt =
        "Respond only through the given schema. Set artifact_markdown to \"ok\", sources to [], assumptions to [], handoff to \"ok\"."

      tokens =
        case Experiment.Codex.call_with_retry(prompt,
               schema: @stage_schema,
               output_file: output_file,
               events_file: events_file,
               run_dir: baseline_dir,
               web_search: true,
               timeout_ms: 120_000
             ) do
          {:ok, %{usage: usage}} -> usage["input_tokens"] + usage["output_tokens"]
          {:error, _} -> 0
        end

      File.write!(usage_file, JSON.encode!(%{tokens: tokens}))
      tokens
    end
  end

  defp parse_args(argv) do
    {parsed, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          tasks: :string,
          configs: :string,
          skip_judge: :boolean,
          resume: :string,
          concurrency: :integer
        ]
      )

    %{
      tasks: parsed[:tasks] && String.split(parsed[:tasks], ",", trim: true),
      configs:
        (parsed[:configs] && String.split(parsed[:configs], ",", trim: true)) || ["team", "solo"],
      skip_judge: Keyword.get(parsed, :skip_judge, false),
      resume: parsed[:resume],
      concurrency: Keyword.get(parsed, :concurrency, 3)
    }
  end
end

Experiment.CLI.main(System.argv())
