defmodule Sprat.Observer.SessionStateTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Event, SessionState}
  alias Sprat.Observer.{Transcript, UsageLimit}
  alias Sprat.Observer.SessionState, as: Fold

  @golden Path.expand("../../fixtures/v4/transcripts/golden.jsonl", __DIR__)
  @t0 ~U[2026-11-23 10:00:00Z]

  # Tiny event builders; `n` is the line number, time = t0 + n seconds.
  defp ev(kind, n, data, extra \\ []),
    do: struct!(Event, [kind: kind, line: n, at: DateTime.add(@t0, n), data: data] ++ extra)

  defp user(n, text), do: ev(:user_text, n, %{text: text})
  defp say(n, text), do: ev(:assistant_text, n, %{text: text})
  defp use(n, id, name, input), do: ev(:tool_use, n, %{id: id, name: name, input: input})
  defp bash(n, id, cmd), do: use(n, id, "Bash", %{"command" => cmd})

  defp result(n, id, is_error, text \\ ""),
    do: ev(:tool_result, n, %{tool_use_id: id, is_error: is_error, text: text})

  defp limit_error(n, text) do
    {:ok, l} = UsageLimit.parse(text, DateTime.add(@t0, n))
    ev(:api_error, n, %{status: 429, error: "rate_limit", text: text, limit?: true, limit: l})
  end

  test "golden transcript folds" do
    {events, _, _} = Transcript.read_from(@golden, 0, 1)
    s = Fold.fold(events)

    assert s.last_user_text == "Fix the login bug please"
    assert s.last_assistant_text =~ "Should I also update the docs?"
    assert s.title == "Fix the login bug"
    assert s.cost_usd == 1.25
    assert s.last_test_failed? == true
    assert s.last_commit_at == ~U[2026-11-23 10:00:10.000Z]
    assert [%{path: "/tmp/sprat-fixture/alpha/lib/foo.ex"}] = s.recent_edits
    assert Map.keys(s.pending_tool_uses) == ["toolu_4"]
    assert s.asks_user?
    assert s.pending_question == "Which docs should I update?"
    # the limit was followed by assistant text, so it is no longer current
    assert s.usage_limit == nil
    assert [%{limit?: true}] = s.api_errors
    assert [%{name: "Bash", command: "git add -A && git commit" <> _} | _] = s.recent_results
    assert Enum.at(s.recent_results, 2).signature =~ "mix test |"
  end

  test "folding is incremental" do
    {events, _, _} = Transcript.read_from(@golden, 0, 1)

    for k <- 0..length(events) do
      {a, b} = Enum.split(events, k)
      assert Fold.fold(Fold.fold(a), b) == Fold.fold(events)
    end
  end

  test "pending tool uses are removed by their result" do
    s = Fold.fold([bash(1, "a", "ls"), bash(2, "b", "pwd"), result(3, "a", false)])
    assert Map.keys(s.pending_tool_uses) == ["b"]
    assert [%{name: "Bash", command: "ls", is_error: false, signature: nil}] = s.recent_results
  end

  test "recent results cap at 50, edits at 100" do
    events =
      Enum.flat_map(1..120, fn i ->
        [
          use(2 * i, "e#{i}", "Write", %{"file_path" => "/p/f#{i}.ex"}),
          result(2 * i + 1, "e#{i}", false)
        ]
      end)

    s = Fold.fold(events)
    assert length(s.recent_results) == 50
    assert length(s.recent_edits) == 100
    assert hd(s.recent_edits).path == "/p/f120.ex"
  end

  test "failed edits and NotebookEdit paths" do
    s =
      Fold.fold([
        use(1, "a", "Edit", %{"file_path" => "/p/a.ex"}),
        result(2, "a", true, "String not found"),
        use(3, "b", "NotebookEdit", %{"notebook_path" => "/p/n.ipynb"}),
        result(4, "b", false),
        use(5, "c", "MultiEdit", %{"file_path" => "/p/m.ex"}),
        result(6, "c", false)
      ])

    assert Enum.map(s.recent_edits, & &1.path) == ["/p/m.ex", "/p/n.ipynb"]
  end

  describe "signature" do
    test "same failure, different numbers, paths, ids and quotes" do
      a =
        Fold.signature(
          "Bash",
          "cd /a/b && mix test test/x_test.exs:12",
          "Exit code 2\n** (CompileError) /Users/a/app/lib/foo.ex:12: undefined function bar/0 in 'Foo'"
        )

      b =
        Fold.signature(
          "Bash",
          "cd /c && mix test test/y_test.exs",
          "Exit code 1\n** (CompileError) /Users/b/other/lib/foo.ex:99: undefined function bar/3 in 'Baz'"
        )

      assert a == b
      assert a =~ "mix test | ** (CompileError) <path>"
    end

    test "hex ids and env prefixes" do
      a = Fold.signature("Bash", "FOO=1 git push", "error: failed to push ref 3f9a2c1d to origin")
      b = Fold.signature("Bash", "FOO=2 git push", "error: failed to push ref 9b8e7d6c to origin")
      assert a == b
      assert a =~ "git push | error: failed to push ref <hex>"
    end

    test "non-bash tools use the tool name; exit code alone still signs" do
      assert Fold.signature("Edit", nil, "String to replace not found in file") =~ "Edit | String"
      assert Fold.signature("Bash", "false", "Exit code 1") == "false | Exit code N"
    end

    test "a different failure gives a different signature" do
      refute Fold.signature("Bash", "mix test", "** (CompileError) x") ==
               Fold.signature("Bash", "mix test", "1 test, 1 failure")
    end
  end

  describe "usage_limit" do
    @text "You've hit your 5-hour limit · resets 11:50am (Europe/London)"

    test "set when the newest assistant-side event is a limit" do
      s = Fold.fold([say(1, "working"), limit_error(2, @text)])
      assert %{kind: :five_hour, reset_at: ~U[2026-11-23 11:50:00Z], line: 2} = s.usage_limit
    end

    test "survives user text and tool results, cleared by later assistant text or tool use" do
      s = Fold.fold([limit_error(1, @text), user(2, "continue")])
      assert s.usage_limit

      assert Fold.fold(s, [say(3, "ok")]).usage_limit == nil
      assert Fold.fold(s, [bash(3, "x", "ls")]).usage_limit == nil
    end

    test "a later non-limit api error clears it" do
      other = ev(:api_error, 2, %{status: 500, text: "overloaded", limit?: false, limit: nil})
      s = Fold.fold([limit_error(1, @text), other])
      assert s.usage_limit == nil
      assert length(s.api_errors) == 2
    end

    test "sidechain limits do not count" do
      side = %{limit_error(1, @text) | sidechain?: true}
      assert Fold.fold([side]).usage_limit == nil
    end
  end

  describe "tests and commits" do
    test "test-like commands" do
      for cmd <- [
            "mix test",
            "cd app && mix test test/a_test.exs",
            "npm test",
            "pnpm run test:unit",
            "yarn test",
            "pytest -q",
            "python -m pytest",
            "flutter test",
            "xcodebuild -scheme App test",
            "cargo test",
            "go test ./...",
            "bundle exec rspec",
            "npx jest",
            "npx vitest run"
          ] do
        assert Fold.test_command?(cmd), cmd
      end

      for cmd <- ["mix compile", "ls test", "cat jest.config.js", "git commit -m test"] do
        refute Fold.test_command?(cmd), cmd
      end
    end

    test "last_test_failed? follows the newest test run" do
      s = Fold.fold([bash(1, "a", "mix test"), result(2, "a", true, "1 failure")])
      assert s.last_test_failed? == true
      s = Fold.fold(s, [bash(3, "b", "ls"), result(4, "b", true)])
      assert s.last_test_failed? == true
      s = Fold.fold(s, [bash(5, "c", "mix test"), result(6, "c", false)])
      assert s.last_test_failed? == false
      assert Fold.fold([]).last_test_failed? == nil
    end

    test "last_commit_at only for successful commits" do
      s = Fold.fold([bash(1, "a", "git commit -m x"), result(2, "a", true, "nothing to commit")])
      assert s.last_commit_at == nil
      s = Fold.fold(s, [bash(3, "b", "git -C /r commit -am y"), result(4, "b", false)])
      assert s.last_commit_at == DateTime.add(@t0, 4)
    end
  end

  describe "asks_user?" do
    test "newest assistant text ending in a question" do
      s = Fold.fold([say(1, "Done.\n\nWant me to **open a PR** too?")])
      assert s.asks_user?
      assert s.pending_question == "Want me to **open a PR** too?"

      s = Fold.fold([say(1, "Tests pass. Shall I commit?")])
      assert s.pending_question == "Shall I commit?"
    end

    test "cleared by a reply, a later tool use, or a plain summary" do
      q = say(1, "Shall I commit?")
      refute Fold.fold([q, user(2, "yes")]).asks_user?
      refute Fold.fold([q, bash(2, "a", "git commit")]).asks_user?
      refute Fold.fold([q, say(2, "All done.")]).asks_user?
    end

    test "pending AskUserQuestion, answered by its result" do
      ask = use(1, "q1", "AskUserQuestion", %{"questions" => [%{"question" => "Which one?"}]})
      s = Fold.fold([ask])
      assert s.asks_user? and s.pending_question == "Which one?"

      s = Fold.fold(s, [result(2, "q1", false, "User answered")])
      refute s.asks_user?
      assert s.pending_question == nil
    end

    test "sidechain text is not the main conversation" do
      side = %{say(2, "Should I?") | sidechain?: true}
      s = Fold.fold([say(1, "Finished."), side])
      refute s.asks_user?
      assert s.last_assistant_text == "Finished."
    end
  end

  test "default state" do
    assert Fold.fold([]) == %SessionState{}
  end
end
