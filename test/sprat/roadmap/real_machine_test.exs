defmodule Sprat.Roadmap.RealMachineTest do
  @moduledoc """
  Builds roadmaps for the owner's real repositories, read-only, and prints
  what it found. Excluded by default:
  `SPRAT_REAL_REPOS=/path/a:/path/b mix test --only real_machine`.
  """
  use ExUnit.Case, async: false

  @moduletag :real_machine

  # The repositories to read: SPRAT_REAL_REPOS, separated by colons.
  @repos "SPRAT_REAL_REPOS" |> System.get_env("") |> String.split(":", trim: true)

  # Public: with no SPRAT_REAL_REPOS no test is generated to call it.
  def commits(root) do
    case System.cmd(
           "git",
           ["-C", root, "log", "--all", "-n", "3000", "--format=%H%x1f%cI%x1f%s%x1f%D"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          with [sha, at, subject, refs] <- String.split(line, "\x1f"),
               {:ok, dt, _} <- DateTime.from_iso8601(at) do
            branches =
              refs
              |> String.split(", ", trim: true)
              |> Enum.map(&String.replace(&1, ~r/^(HEAD -> |origin\/|tag: )/, ""))

            [%{sha: sha, at: dt, subject: subject, branches: branches}]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  for root <- @repos do
    @root root
    test "builds a roadmap for #{Path.basename(root)} without writing anything" do
      alias Sprat.Roadmap, as: RM
      alias Sprat.Roadmap.{Position, Progress}

      if File.dir?(@root) do
        before = File.exists?(Path.join(@root, ".sprat/roadmap.md"))
        now = DateTime.utc_now()
        commits = commits(@root)
        rm = RM.build(@root, commits: commits, now: now)
        events = Progress.from_git(commits, rm)
        pos = Position.compute(rm, events, now)

        assert File.exists?(Path.join(@root, ".sprat/roadmap.md")) == before
        assert rm.project_root == @root

        items = Enum.flat_map(rm.phases, & &1.items)

        IO.puts("""

        ── #{@root}
           sources:  #{Enum.join(rm.sources, ", ")}
           phases:   #{length(rm.phases)}  items: #{length(items)}  confirmed: #{rm.confirmed?}
           position: #{pos.phase_id} · #{pos.phase_title} → #{pos.item_id} #{pos.item_text} (#{pos.done}/#{pos.total})
           last:     #{pos.last_progress_kind} #{pos.last_progress_at}  velocity: #{pos.velocity}  bound commits: #{Enum.count(events, & &1.item_id)}
           notes:    #{Enum.join(rm.notes, " | ")}
        """)
      else
        IO.puts("\n── #{@root}: not on this machine, skipped")
      end
    end
  end
end
