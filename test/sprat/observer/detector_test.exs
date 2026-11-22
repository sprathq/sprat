defmodule Sprat.Observer.DetectorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Observer.Detector

  alias Sprat.Observer.Model.{
    Account,
    Event,
    Item,
    Phase,
    Position,
    Project,
    Roadmap,
    Session,
    SessionState
  }

  @now ~U[2026-11-23 14:00:00Z]
  @root "/repo/cupful"
  @sid "s1"

  defp ago(minutes), do: DateTime.add(@now, -minutes * 60)

  defp project(attrs \\ []) do
    items = [
      %Item{id: "C.3", text: "member join flow", state: :done},
      %Item{id: "C.4", text: "shared points ledger", state: :active, branch: "cafe-networks"},
      %Item{id: "C.5", text: "cross-cafe redemption", state: :todo}
    ]

    struct(
      %Project{
        root: @root,
        name: "cupful",
        roadmap: %Roadmap{
          project_root: @root,
          phases: [%Phase{id: "C", title: "Cafe networks", items: items}]
        },
        position: %Position{
          phase_id: "C",
          item_id: "C.4",
          item_text: "shared points ledger",
          done: 3,
          total: 9,
          last_progress_at: ago(60)
        },
        first_seen_at: ago(60 * 24 * 30)
      },
      attrs
    )
  end

  defp session(attrs \\ []) do
    struct(
      %Session{
        session_id: @sid,
        config_dir: "/home/.claude",
        live?: true,
        status: :idle,
        status_since: ago(15),
        project_root: @root,
        branch: "cafe-networks",
        last_activity_at: ago(15)
      },
      attrs
    )
  end

  defp state(attrs \\ []) do
    struct(%SessionState{session_id: @sid, last_event_at: ago(15), last_event_line: 100}, attrs)
  end

  defp run(opts) do
    input = %{
      now: @now,
      projects: Keyword.get(opts, :projects, [project()]),
      sessions: Keyword.get(opts, :sessions, [session()]),
      states: Keyword.get(opts, :states, %{@sid => state()}),
      accounts: Keyword.get(opts, :accounts, [])
    }

    Detector.detect(input, Keyword.get(opts, :settings, %{}))
  end

  defp rules(findings), do: findings |> Enum.map(& &1.rule) |> Enum.sort()
  defp only(findings, rule), do: Enum.filter(findings, &(&1.rule == rule))

  describe "W1 waiting on you" do
    test "fires when idle > 10 min on a question" do
      st =
        state(
          asks_user?: true,
          last_assistant_text: "I did X.\nShould I keep the old network_id column?",
          last_assistant_line: 88
        )

      [f] = run(states: %{@sid => st}) |> only("W1")
      assert f.kind == :needs_you
      assert f.evidence == ["transcript:s1:88"]
      assert f.summary =~ "network_id"
      assert f.data.question == "Should I keep the old network_id column?"
    end

    test "does not fire before 10 min" do
      st = state(asks_user?: true, last_assistant_text: "ok?", last_assistant_line: 1)

      assert run(sessions: [session(status_since: ago(9))], states: %{@sid => st}) |> only("W1") ==
               []
    end

    test "a pending AskUserQuestion counts as a question, not a permission prompt" do
      ev = %Event{
        kind: :tool_use,
        line: 77,
        data: %{id: "t1", name: "AskUserQuestion", input: %{}}
      }

      st = state(pending_tool_uses: %{"t1" => ev})
      found = run(states: %{@sid => st})
      assert [%{evidence: ["transcript:s1:77"]}] = only(found, "W1")
      assert only(found, "W2") == []
    end

    test "not on a busy session" do
      st = state(asks_user?: true, last_assistant_text: "ok?", last_assistant_line: 1)
      assert run(sessions: [session(status: :busy)], states: %{@sid => st}) |> only("W1") == []
    end
  end

  describe "W2 permission prompt" do
    test "fires on a pending tool_use idle > 5 min" do
      ev = %Event{kind: :tool_use, line: 50, data: %{id: "t9", name: "Bash", input: %{}}}
      st = state(pending_tool_uses: %{"t9" => ev})
      [f] = run(sessions: [session(status_since: ago(6))], states: %{@sid => st}) |> only("W2")
      assert f.evidence == ["transcript:s1:50"]
      assert f.data.tools == ["Bash"]
    end

    test "not within 5 min" do
      ev = %Event{kind: :tool_use, line: 50, data: %{id: "t9", name: "Bash", input: %{}}}
      st = state(pending_tool_uses: %{"t9" => ev})

      assert run(sessions: [session(status_since: ago(4))], states: %{@sid => st}) |> only("W2") ==
               []
    end
  end

  describe "W3 api errors" do
    test "fires on two non-limit errors in the last 10 assistant records" do
      errs = [
        %Event{
          kind: :api_error,
          line: 95,
          data: %{status: 529, text: "overloaded", limit?: false}
        },
        %Event{kind: :api_error, line: 90, data: %{status: 401, text: "auth", limit?: false}}
      ]

      st = state(api_errors: errs, recent_assistant_lines: Enum.to_list(95..86//-1))
      [f] = run(states: %{@sid => st}) |> only("W3")
      assert f.evidence == ["transcript:s1:90", "transcript:s1:95"]
    end

    test "ignores usage limits and errors outside the window" do
      errs = [
        %{line: 95, status: 429, limit?: true},
        %{line: 40, status: 529, limit?: false},
        %{line: 93, status: 529, limit?: false}
      ]

      st = state(api_errors: errs, recent_assistant_lines: Enum.to_list(95..86//-1))
      assert run(states: %{@sid => st}) |> only("W3") == []
    end
  end

  describe "Q1 usage limit" do
    test "scheduled finding with reset, kind and account" do
      limit = %Event{
        kind: :api_error,
        line: 120,
        data: %{limit?: true, reset_at: ~U[2026-11-23 15:50:00Z], limit_kind: :five_hour}
      }

      [f] = run(states: %{@sid => state(usage_limit: limit)}) |> only("Q1")
      assert f.kind == :scheduled

      assert f.data == %{
               reset_at: ~U[2026-11-23 15:50:00Z],
               limit_kind: :five_hour,
               account: "/home/.claude"
             }

      assert f.evidence == ["transcript:s1:120"]
    end

    test "falls back to the account's reset" do
      acct = %Account{
        config_dir: "/home/.claude",
        limited_until: ~U[2026-11-23 16:00:00Z],
        limit_kind: :weekly
      }

      [f] = run(states: %{@sid => state(usage_limit: %{line: 3})}, accounts: [acct]) |> only("Q1")
      assert f.data.reset_at == ~U[2026-11-23 16:00:00Z]
      assert f.data.limit_kind == :weekly
    end

    test "a limited account suppresses P4 and L3" do
      acct = %Account{config_dir: "/home/.claude", limited_until: ~U[2026-11-23 16:00:00Z]}
      sess = session(status_since: ago(40))
      st = state(last_assistant_text: "Summary of work.", last_assistant_line: 9)
      assert run(sessions: [sess], states: %{@sid => st}) |> only("P4") != []
      assert run(sessions: [sess], states: %{@sid => st}, accounts: [acct]) |> only("P4") == []
    end
  end

  describe "L1 error loop" do
    defp err(line, min, sig \\ "mix test: ** (CompileError) lib/x.ex:N") do
      %{line: line, at: ago(min), is_error: true, signature: sig, name: "Bash"}
    end

    test "same signature 3 times in 30 min with no edit between" do
      st =
        state(
          recent_results: [err(30, 5), err(20, 10), err(10, 20)],
          recent_edits: [%{line: 5, at: ago(25), path: "a.ex"}]
        )

      [f] =
        run(sessions: [session(status: :busy, status_since: ago(1))], states: %{@sid => st})
        |> only("L1")

      assert f.kind == :stuck
      assert f.data.count == 3
      assert f.evidence == ["transcript:s1:10", "transcript:s1:20", "transcript:s1:30"]
    end

    test "an edit between first and last occurrence breaks the loop" do
      st =
        state(
          recent_results: [err(30, 5), err(20, 10), err(10, 20)],
          recent_edits: [%{line: 15, at: ago(15), path: "a.ex"}]
        )

      assert run(states: %{@sid => st}) |> only("L1") == []
    end

    test "occurrences older than 30 min don't count" do
      st = state(recent_results: [err(30, 5), err(20, 10), err(10, 40)])
      assert run(states: %{@sid => st}) |> only("L1") == []
    end

    test "id is stable for the same signature as more evidence arrives" do
      st1 = state(recent_results: [err(30, 5), err(20, 10), err(10, 20)])
      st2 = state(recent_results: [err(40, 1), err(30, 5), err(20, 10), err(10, 20)])
      [a] = run(states: %{@sid => st1}) |> only("L1")
      [b] = run(states: %{@sid => st2}) |> only("L1")
      assert a.id == b.id
      assert b.data.count == 4
    end
  end

  describe "L2 edit churn" do
    defp edits(n, path \\ "lib/ledger.ex"),
      do: for(i <- 1..n, do: %{line: i * 10, at: ago(i), path: path})

    test "6 edits in 20 min while tests fail" do
      st = state(recent_edits: edits(6), last_test_failed?: true)
      [f] = run(states: %{@sid => st}) |> only("L2")
      assert f.data == %{path: "lib/ledger.ex", count: 6}
      assert "file:lib/ledger.ex" in f.evidence
    end

    test "not when tests pass, not with 5 edits" do
      assert run(states: %{@sid => state(recent_edits: edits(6), last_test_failed?: false)})
             |> only("L2") == []

      assert run(states: %{@sid => state(recent_edits: edits(5), last_test_failed?: true)})
             |> only("L2") == []
    end
  end

  describe "L3 spinning" do
    test "busy > 45 min with nothing landing" do
      sess = session(status: :busy, status_since: ago(50))
      proj = project(position: %Position{item_id: "C.4", last_progress_at: ago(600)})
      [f] = run(sessions: [sess], projects: [proj]) |> only("L3")
      assert f.evidence == ["transcript:s1:100"]
    end

    test "a recent edit, commit or tick prevents it" do
      sess = session(status: :busy, status_since: ago(50))
      proj = project(position: %Position{item_id: "C.4", last_progress_at: ago(600)})

      assert run(
               sessions: [sess],
               projects: [proj],
               states: %{@sid => state(recent_edits: [%{line: 1, at: ago(10), path: "x"}])}
             )
             |> only("L3") == []

      assert run(
               sessions: [sess],
               projects: [proj],
               states: %{@sid => state(last_commit_at: ago(10))}
             )
             |> only("L3") == []

      assert run(
               sessions: [sess],
               projects: [project(position: %Position{item_id: "C.4", last_progress_at: ago(5)})]
             )
             |> only("L3") == []
    end
  end

  describe "P1 roadmap stalled" do
    test "active item, no progress 48h, no live session" do
      proj =
        project(
          position: %Position{item_id: "C.4", item_text: "ledger", last_progress_at: ago(49 * 60)}
        )

      [f] = run(projects: [proj], sessions: [session(live?: false, status: :ended)]) |> only("P1")
      assert f.session_id == nil
      assert f.evidence == ["roadmap:C.4"]
    end

    test "a live session on the item prevents it" do
      proj = project(position: %Position{item_id: "C.4", last_progress_at: ago(49 * 60)})
      assert run(projects: [proj]) |> only("P1") == []
    end

    test "not for archived projects or all-done roadmaps" do
      stale = %Position{item_id: "C.4", last_progress_at: ago(49 * 60)}
      assert run(projects: [project(position: stale, archived?: true)], sessions: []) == []

      assert run(projects: [project(position: %{stale | all_done?: true})], sessions: [])
             |> only("P1") == []
    end
  end

  describe "P2 left mid-step" do
    test "ended with a dirty tree and no newer PAUSE.md" do
      sess = session(live?: false, status: :ended, dirty?: true, last_activity_at: ago(120))
      [f] = run(sessions: [sess]) |> only("P2")
      assert f.data.dirty?
    end

    test "ended on a branch whose item is unfinished" do
      sess = session(live?: false, status: :ended, last_activity_at: ago(120))
      assert [%{data: %{item_id: "C.4"}}] = run(sessions: [sess]) |> only("P2")
    end

    test "a newer PAUSE.md or a later session on the branch clears it" do
      sess = session(live?: false, status: :ended, dirty?: true, last_activity_at: ago(120))
      assert run(sessions: [sess], projects: [project(pause_md_at: ago(60))]) |> only("P2") == []

      later = session(session_id: "s2", live?: true, status: :busy)
      assert run(sessions: [sess, later], states: %{}) |> only("P2") == []
    end

    test "not for a clean session bound only through the position" do
      sess =
        session(
          live?: false,
          status: :ended,
          branch: "main",
          dirty?: false,
          last_activity_at: ago(120)
        )

      assert run(sessions: [sess]) |> only("P2") == []
    end
  end

  describe "P3 claimed done, not done" do
    test "claims done while the bound item is unticked" do
      st =
        state(
          last_assistant_text: "The ledger is done and all tests pass.",
          last_assistant_line: 7,
          last_event_at: ago(1)
        )

      [f] =
        run(sessions: [session(status: :busy, status_since: ago(1))], states: %{@sid => st})
        |> only("P3")

      assert f.evidence == ["transcript:s1:7"]
    end

    test "claims done while the last test failed, even with the item ticked" do
      proj = project(roadmap: nil, position: nil)

      st =
        state(last_assistant_text: "Finished!", last_assistant_line: 7, last_test_failed?: true)

      assert [_] = run(projects: [proj], states: %{@sid => st}) |> only("P3")
    end

    test "regex: word boundaries and negation" do
      for t <- [
            "Done.",
            "This is complete",
            "All finished",
            "Ready for review",
            "I've completed the task"
          ] do
        assert Detector.claims_done?(t), t
      end

      for t <- [
            "Not done yet",
            "this isn't finished",
            "abandoned the approach",
            "readyState is wrong",
            "incomplete",
            "nothing done",
            "not yet ready"
          ] do
        refute Detector.claims_done?(t), t
      end
    end
  end

  describe "P4 idle with work left" do
    test "idle > 30 min, not a question, item not done" do
      st = state(last_assistant_text: "Summary: did the migrations.", last_assistant_line: 9)
      [f] = run(sessions: [session(status_since: ago(31))], states: %{@sid => st}) |> only("P4")
      assert f.data.item_id == "C.4"
    end

    test "not when the last turn is a question (that is W1)" do
      st = state(asks_user?: true, last_assistant_text: "Shall I?", last_assistant_line: 9)
      found = run(sessions: [session(status_since: ago(31))], states: %{@sid => st})
      assert rules(found) == ["W1"]
    end
  end

  describe "binding" do
    test "branch wins over position" do
      sess = session(branch: "cafe-networks")

      assert %Item{id: "C.4"} =
               Detector.bound_item(project(position: %Position{item_id: "C.5"}), sess)

      assert %Item{id: "C.5"} =
               Detector.bound_item(
                 project(position: %Position{item_id: "C.5"}),
                 session(branch: "other")
               )
    end
  end

  describe "owner typing" do
    test "a user_text within 2 min suppresses all session rules" do
      st =
        state(
          asks_user?: true,
          last_assistant_text: "ok?",
          last_assistant_line: 1,
          last_user_at: ago(1)
        )

      assert run(states: %{@sid => st}) == []
    end
  end

  # ── properties ──────────────────────────────────────────────────────────

  defp gen_state do
    gen all(
          asks <- boolean(),
          failed <- one_of([constant(nil), boolean()]),
          n_err <- integer(0..5),
          n_edit <- integer(0..8),
          user_min <- one_of([constant(nil), integer(0..60)]),
          text <- member_of([nil, "Done.", "Shall I continue?", "Working on it", "not done yet"])
        ) do
      results =
        for i <- 1..n_err//1, do: %{line: i * 3, at: ago(i * 4), is_error: true, signature: "sig"}

      edits = for i <- 1..n_edit//1, do: %{line: i * 3 + 1, at: ago(i), path: "lib/a.ex"}

      state(
        asks_user?: asks,
        last_test_failed?: failed,
        recent_results: results,
        recent_edits: edits,
        last_user_at: user_min && ago(user_min),
        last_assistant_text: text,
        last_assistant_line: 50
      )
    end
  end

  defp gen_session(i) do
    gen all(
          status <- member_of([:busy, :idle, :ended]),
          since <- integer(0..120),
          dirty <- one_of([constant(nil), boolean()])
        ) do
      session(
        session_id: "s#{i}",
        status: status,
        live?: status != :ended,
        status_since: ago(since),
        dirty?: dirty,
        last_activity_at: ago(since)
      )
    end
  end

  defp gen_input do
    gen all(
          n <- integer(1..4),
          sessions <- fixed_list(Enum.map(1..n, &gen_session/1)),
          states <- list_of(gen_state(), length: n)
        ) do
      states =
        sessions
        |> Enum.zip(states)
        |> Map.new(fn {s, st} -> {s.session_id, %{st | session_id: s.session_id}} end)

      %{now: @now, projects: [project()], sessions: sessions, states: states, accounts: []}
    end
  end

  property "deterministic and independent of session order" do
    check all(input <- gen_input()) do
      a = Detector.detect(input)
      assert a == Detector.detect(input)
      assert a == Detector.detect(%{input | sessions: Enum.reverse(input.sessions)})
    end
  end

  property "every finding cites evidence and has a unique, rule-prefixed id" do
    check all(input <- gen_input()) do
      found = Detector.detect(input)
      assert Enum.all?(found, &(&1.evidence != []))
      assert Enum.all?(found, &String.starts_with?(&1.id, &1.rule <> "-"))
      assert length(Enum.uniq_by(found, & &1.id)) == length(found)
    end
  end

  property "a session with a user_text in the last 2 minutes gets no findings" do
    check all(input <- gen_input()) do
      typing =
        for {sid, %{last_user_at: %DateTime{} = at}} <- input.states,
            DateTime.diff(@now, at) < 120,
            do: sid

      found = Detector.detect(input)
      refute Enum.any?(found, &(&1.session_id in typing))
    end
  end

  property "re-detection a minute later keeps the ids of findings whose evidence is unchanged" do
    check all(input <- gen_input()) do
      ids =
        input
        |> Detector.detect()
        |> Enum.filter(&(&1.rule in ~w(W1 P2 P3 P4)))
        |> MapSet.new(& &1.id)

      later = Detector.detect(%{input | now: DateTime.add(@now, 60)}) |> MapSet.new(& &1.id)
      assert MapSet.subset?(ids, later)
    end
  end

  describe "Q1 with background agents' limits" do
    defp agent_limit(reset),
      do: %{line: 90, at: ago(30), kind: :weekly, reset_at: reset, text: "weekly"}

    test "an agents' limit that resets later than the main thread's wins" do
      main = %{line: 120, reset_at: ~U[2026-11-23 15:50:00Z], kind: :five_hour}
      later = ~U[2026-11-23 17:00:00Z]
      st = state(usage_limit: main, agent_limit: agent_limit(later))

      [f] = run(states: %{@sid => st}) |> only("Q1")
      assert f.data.reset_at == later
      assert f.data.agents? == true
      assert f.summary == "agents' usage limit · resets 17:00"
    end

    test "an agents' limit that resets earlier changes nothing" do
      main = %{line: 120, reset_at: ~U[2026-11-23 15:50:00Z], kind: :five_hour}
      st = state(usage_limit: main, agent_limit: agent_limit(~U[2026-11-23 14:30:00Z]))

      [f] = run(states: %{@sid => st}) |> only("Q1")
      assert f.data.reset_at == ~U[2026-11-23 15:50:00Z]
      refute Map.has_key?(f.data, :agents?)
    end

    test "alone it schedules an idle session, not a busy one, and expires at its reset" do
      st = state(agent_limit: agent_limit(~U[2026-11-23 17:00:00Z]))
      assert [%{data: %{agents?: true}}] = run(states: %{@sid => st}) |> only("Q1")

      busy = [session(status: :busy)]
      assert run(states: %{@sid => st}, sessions: busy) |> only("Q1") == []

      gone = state(agent_limit: agent_limit(~U[2026-11-23 13:00:00Z]))
      assert run(states: %{@sid => gone}) |> only("Q1") == []
    end
  end
end
