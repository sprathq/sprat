defmodule Sprat.RecapTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.Event
  alias Sprat.Recap

  @since ~U[2026-11-25 20:00:00Z]

  defp at(min), do: DateTime.add(@since, min * 60)

  defp ev(kind, min, data, opts \\ []),
    do: %Event{kind: kind, line: min, at: at(min), data: data, sidechain?: opts[:side] == true}

  defp bash(id, min, cmd),
    do: ev(:tool_use, min, %{id: id, name: "Bash", input: %{"command" => cmd}})

  defp result(id, min, error?),
    do: ev(:tool_result, min, %{tool_use_id: id, is_error: error?, text: ""})

  defp repo_of(dir) do
    cond do
      String.starts_with?(dir, "/p/app_ios") -> "/p/app_ios"
      String.starts_with?(dir, "/p/app_flutter") -> "/p/app_flutter"
      true -> nil
    end
  end

  test "prompts, turn ends, commits, failed tests, limits and the repos it worked in" do
    events = [
      ev(:user_text, -30, %{text: "before the window"}),
      ev(:user_text, 1, %{text: "[Request interrupted by user]"}),
      ev(:user_text, 1, %{text: "We drop flutter; build the iOS app"}),
      ev(:assistant_text, 2, %{text: "Starting on the iOS skeleton."}),
      ev(:tool_use, 3, %{id: "e1", name: "Edit", input: %{"file_path" => "/p/app_ios/A.swift"}}),
      bash("b1", 4, "cd /p/app_ios && xcodebuild test -scheme X"),
      result("b1", 4, true),
      bash(
        "b2",
        5,
        ~s(cd /p/app_ios && git add -A && git commit -qm "feat: iOS skeleton" && git log -1)
      ),
      result("b2", 5, false),
      ev(:assistant_text, 6, %{text: "Task 1 done.\n\nNext Task 2."}),
      ev(:api_error, 7, %{text: "You've hit your limit", limit?: true}),
      ev(:user_text, 8, %{text: "[sprat] Your usage limit has reset. Continue"}),
      ev(:assistant_text, 9, %{text: "On Task 2."}),
      ev(:assistant_text, 9, %{text: "subagent chatter"}, side: true),
      bash("b3", 10, "cd /p/app_flutter && git status")
    ]

    r = Recap.build(events, @since, repo_of: &repo_of/1)

    assert r.counts == %{
             you: 1,
             sprat: 1,
             turns: 2,
             edits: 1,
             commits: 1,
             tests: 1,
             failed: 1,
             limits: 1
           }

    assert r.repos == [{"app_ios", 3}, {"app_flutter", 1}]

    assert Enum.map(r.timeline, &{&1.kind, &1.text}) == [
             {:you, "We drop flutter; build the iOS app"},
             {:failed, "cd /p/app_ios && xcodebuild test -scheme X"},
             {:commit, "feat: iOS skeleton"},
             {:said, "Task 1 done. Next Task 2."},
             {:stop, "You've hit your limit"},
             {:sprat, "Your usage limit has reset. Continue"},
             {:said, "On Task 2."}
           ]
  end

  test "a commit's message comes from the commit, not a heredoc beside it" do
    cmd = """
    cd /r && git commit -qm "feat: the real one" && git log -1
    cat > report.md <<'EOF'
    # Task 3 report
    EOF
    """

    assert Recap.commit?(cmd)
    assert Recap.commit_message(cmd) == "feat: the real one"

    heredoc = ~s[git commit -m "$(cat <<'EOF'\nfix: from a heredoc\n\nbody\nEOF\n)"]
    assert Recap.commit_message(heredoc) == "fix: from a heredoc"

    # "git commit" in the text of a script is not a commit.
    refute Recap.commit?("python3 - <<'EOF'\ns = \"\"\"\ngit commit -m x\n\"\"\"\nEOF")
    refute Recap.commit?("git log --format=%s | grep commit")
  end

  test "reads the transcript and its subagents' tool calls from disk" do
    dir = Path.join(System.tmp_dir!(), "recap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "s1/subagents"))
    on_exit(fn -> File.rm_rf!(dir) end)

    line = fn map -> Jason.encode!(map) <> "\n" end
    ts = fn min -> DateTime.to_iso8601(at(min)) end

    File.write!(
      Path.join(dir, "s1.jsonl"),
      line.(%{type: "user", timestamp: ts.(1), message: %{role: "user", content: "Build it"}})
    )

    File.write!(
      Path.join(dir, "s1/subagents/agent-a.jsonl"),
      line.(%{
        type: "assistant",
        timestamp: ts.(2),
        isSidechain: true,
        message: %{
          role: "assistant",
          content: [
            %{type: "text", text: "subagent prose"},
            %{
              type: "tool_use",
              id: "t1",
              name: "Bash",
              input: %{command: "git commit -m 'feat: by a subagent'"}
            }
          ]
        }
      })
    )

    assert {:ok, r} = Recap.from_file(Path.join(dir, "s1.jsonl"), @since)
    assert r.counts.you == 1
    assert r.counts.commits == 1
    assert Enum.map(r.timeline, & &1.kind) == [:you, :commit]
    refute r.cut?
  end
end
