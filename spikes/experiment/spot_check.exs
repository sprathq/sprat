Mix.install([])

# Human spot-check (§ "Human spot-check" in 01-experiment-design.md): print 3 randomly chosen
# tasks' A/B reports side by side, mapping hidden, so the owner can blind-score them against the
# judge's rubric before trusting the automated verdict.
#
# Usage: elixir spot_check.exs <run_dir> [n]

[run_dir | rest] = System.argv()

n =
  case rest do
    [n] -> String.to_integer(n)
    [] -> 3
  end

task_dirs =
  run_dir
  |> Path.join("*")
  |> Path.wildcard()
  |> Enum.filter(&File.dir?/1)
  |> Enum.filter(&File.exists?(Path.join(&1, "blind_map.json")))
  |> Enum.shuffle()
  |> Enum.take(n)

if task_dirs == [] do
  IO.puts("No tasks with a blind_map.json found under #{run_dir}. Run the judge first.")
  System.halt(1)
end

IO.puts("""
Blind spot-check: #{length(task_dirs)} task(s), reports A/B, mapping withheld.
Score each on the same rubric as the judge (evidence grounding, counter-evidence, honesty,
specificity, validation plan actionability -- 1-5 each) before looking at judge.json.
""")

for task_dir <- task_dirs do
  task_id = Path.basename(task_dir)
  blind_map = task_dir |> Path.join("blind_map.json") |> File.read!() |> JSON.decode!()

  report = fn label ->
    config = blind_map[label]
    Path.join([task_dir, config, "report.md"]) |> File.read!()
  end

  IO.puts(String.duplicate("=", 80))
  IO.puts("TASK #{task_id}")
  IO.puts(String.duplicate("=", 80))
  IO.puts("\n----- REPORT A -----\n")
  IO.puts(report.("a"))
  IO.puts("\n----- REPORT B -----\n")
  IO.puts(report.("b"))
  IO.puts("")
end

IO.puts("""
When you've scored all #{length(task_dirs)}, compare against each task's judge.json
("verdict") and blind_map.json (which label was team/solo) to see whether you agree.
If you disagree with the judge on 2+ of these #{length(task_dirs)}, per the design doc all
10 tasks go to full human review instead of trusting the automated verdicts.
""")
