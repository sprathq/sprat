defmodule Sprat.Observer.StoreTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Account, Decision, Finding, Project, Served}
  alias Sprat.Observer.Store

  @now ~U[2026-11-23 14:00:00Z]

  setup do
    dir =
      Path.join(System.tmp_dir!(), "sprat-observer-store-#{System.unique_integer([:positive])}")

    path = Path.join(dir, "observer.db")
    pid = start_supervised!({Store, path: path, name: nil})
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, store: pid, path: path}
  end

  defp finding(attrs \\ []) do
    struct(
      %Finding{
        id: "L1-abc",
        rule: "L1",
        kind: :stuck,
        project_root: "/r",
        session_id: "s1",
        summary: "error loop",
        evidence: ["transcript:s1:10", "transcript:s1:20"],
        data: %{signature: "sig", count: 3},
        first_seen_at: @now,
        last_seen_at: @now
      },
      attrs
    )
  end

  test "schema, WAL, and reopening an existing file", %{store: s, path: path} do
    assert Store.schema_version(s) == 2
    :ok = Store.put_setting(s, "x", %{"a" => 1})
    stop_supervised!(Store)

    pid = start_supervised!({Store, path: path, name: nil})
    assert Store.schema_version(pid) == 2
    assert Store.get_setting(pid, "x") == %{"a" => 1}
    assert File.exists?(path <> "-wal") or File.exists?(path)
  end

  test "named server" do
    dir =
      Path.join(System.tmp_dir!(), "sprat-observer-named-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)
    start_supervised!({Store, path: Path.join(dir, "o.db"), name: :obs_named_test}, id: :named)
    :ok = Store.put_offset(:obs_named_test, "/t.jsonl", 10, 3)
    assert Store.get_offset(:obs_named_test, "/t.jsonl") == {10, 3}
  end

  describe "findings" do
    test "insert, then re-detection updates without duplicating and keeps first_seen", %{store: s} do
      {:ok, f} = Store.upsert_finding(s, finding())
      assert f.kind == :stuck
      assert f.state == :open
      assert f.data == %{signature: "sig", count: 3}

      later = DateTime.add(@now, 600)

      {:ok, f2} =
        Store.upsert_finding(
          s,
          finding(
            evidence: ["transcript:s1:10", "transcript:s1:20", "transcript:s1:30"],
            first_seen_at: later,
            last_seen_at: later
          )
        )

      assert f2.first_seen_at == @now
      assert f2.last_seen_at == later
      assert length(f2.evidence) == 3
      assert [_] = Store.list_open_findings(s)
    end

    test "dismissed stays dismissed until evidence changes", %{store: s} do
      {:ok, _} = Store.upsert_finding(s, finding())
      :ok = Store.set_finding_state(s, "L1-abc", :dismissed, dismiss_reason: "deliberate loop")
      assert Store.list_open_findings(s) == []
      assert Store.dismiss_reason(s, "L1-abc") == "deliberate loop"

      {:ok, same} = Store.upsert_finding(s, finding())
      assert same.state == :dismissed

      {:ok, changed} = Store.upsert_finding(s, finding(evidence: ["transcript:s1:99"]))
      assert changed.state == :open
      assert Store.dismiss_reason(s, "L1-abc") == nil
    end

    test "filters by project and session", %{store: s} do
      {:ok, _} = Store.upsert_finding(s, finding())

      {:ok, _} =
        Store.upsert_finding(
          s,
          finding(id: "P1-x", rule: "P1", project_root: "/q", session_id: nil)
        )

      assert [%{id: "P1-x"}] = Store.list_open_findings(s, project_root: "/q")
      assert [%{id: "L1-abc"}] = Store.list_open_findings(s, session_id: "s1")
      assert Store.get_finding(s, "nope") == nil
    end
  end

  describe "pm runs and spend" do
    test "record, list with decoded decision, count and spend", %{store: s} do
      {:ok, _} = Store.upsert_finding(s, finding())
      {:ok, _} = Store.upsert_finding(s, finding(id: "P1-x", project_root: "/other"))

      d = %Decision{
        action: :reassign,
        confidence: :high,
        next_item: "B.5",
        evidence_used: ["roadmap:B.7"]
      }

      {:ok, id} =
        Store.record_pm_run(s, %{
          finding_id: "L1-abc",
          started_at: @now,
          decision: d,
          cost_usd: 0.31,
          turns: 11
        })

      {:ok, _} = Store.record_pm_run(s, %{finding_id: "P1-x", started_at: @now, cost_usd: 0.5})
      # yesterday's run does not count today
      {:ok, _} =
        Store.record_pm_run(s, %{
          finding_id: "L1-abc",
          started_at: DateTime.add(@now, -86_400),
          cost_usd: 9
        })

      # recorded again on finish: replaced, not duplicated
      {:ok, ^id} =
        Store.record_pm_run(s, %{
          id: id,
          finding_id: "L1-abc",
          started_at: @now,
          finished_at: DateTime.add(@now, 60),
          decision: d,
          cost_usd: 0.31,
          turns: 11,
          sources: ["fleet:liftlog-ios"]
        })

      assert Store.count_pm_runs(s, "L1-abc") == 2
      [_, run] = Store.list_pm_runs(s, "L1-abc")
      assert run.decision.action == :reassign
      assert run.decision.confidence == :high
      assert run.decision.evidence_used == ["roadmap:B.7"]
      assert run.sources == ["fleet:liftlog-ios"]

      assert_in_delta Store.spend_today(s, "/r", @now), 0.31, 1.0e-9
      assert_in_delta Store.spend_today(s, :fleet, @now), 0.81, 1.0e-9
    end
  end

  describe "nudges and the policy ledger" do
    test "record, update, ledger", %{store: s} do
      {:ok, id} =
        Store.record_nudge(s, %{
          finding_id: "L1-abc",
          session_id: "s1",
          text: "[sprat] hi",
          adapter: :cmux,
          created_at: @now
        })

      :ok = Store.update_nudge(s, id, %{state: :delivered, delivered_at: @now})
      [n] = Store.list_nudges(s, session_id: "s1")
      assert n.state == "delivered"
      assert n.delivered_at == @now

      d = %Decision{action: :answer, answer_source: "spec", evidence_used: ["x"]}
      {:ok, _} = Store.record_pm_run(s, %{finding_id: "L1-abc", started_at: @now, decision: d})

      ledger = Store.policy_ledger(s, "L1-abc")
      assert ledger.last_delivery_at_by_session == %{"s1" => @now}
      assert ledger.sent_texts_by_session == %{"s1" => ["[sprat] hi"]}
      assert ledger.pm_runs_for_finding == 1
      assert MapSet.member?(ledger.answers_given, "L1-abc")
    end
  end

  describe "roadmap writes" do
    test "record and revert", %{store: s} do
      {:ok, id} =
        Store.record_write(s, %{
          project_root: "/r",
          item_id: "B.7",
          from_state: :active,
          to_state: :blocked,
          reason: "cert",
          at: @now
        })

      :ok = Store.mark_reverted(s, id, DateTime.add(@now, 60))
      assert [%{to_state: "blocked", reverted_at: %DateTime{}}] = Store.list_writes(s, "/r")
      assert Store.mark_reverted(s, "nope", @now) == {:error, :not_found}
    end
  end

  describe "projects, accounts, offsets, served, settings, events" do
    test "projects and autonomy", %{store: s} do
      :ok = Store.upsert_project(s, %Project{root: "/r", name: "r", first_seen_at: @now})
      :ok = Store.set_autonomy(s, "/r", :act, :owner, DateTime.add(@now, 5))
      :ok = Store.upsert_project(s, %Project{root: "/r", name: "renamed", autonomy: :propose})

      assert [%Project{name: "renamed", autonomy: :act, first_seen_at: @now}] =
               Store.get_projects(s)

      assert %{level: :act, by: "owner"} = Store.autonomy_change(s, "/r")
    end

    test "accounts", %{store: s} do
      a = %Account{
        config_dir: "/c",
        limited_until: @now,
        limit_kind: :five_hour,
        limit_text: "hit",
        resume_queue: ["s1", "s2"],
        login: "0369fb8b",
        limited_at: DateTime.add(@now, -60)
      }

      :ok = Store.put_account(s, a)
      assert Store.get_accounts(s) == [a]
    end

    test "offsets", %{store: s} do
      assert Store.get_offset(s, "/t") == nil
      :ok = Store.put_offset(s, "/t", 100, 4)
      :ok = Store.put_offset(s, "/t", 200, 9)
      assert Store.get_offset(s, "/t") == {200, 9}
    end

    test "served since", %{store: s} do
      {:ok, _} =
        Store.record_served(
          s,
          %Served{at: DateTime.add(@now, -7200), project_name: "a", text: "old"},
          "/a"
        )

      {:ok, _} =
        Store.record_served(
          s,
          %Served{at: @now, project_name: "b", text: "new", ref: "pm-1"},
          "/b"
        )

      assert [%Served{text: "new", by: :sprat, ref: "pm-1"}] =
               Store.served_since(s, DateTime.add(@now, -60))
    end

    test "settings and events", %{store: s} do
      assert Store.get_setting(s, "missing", 7) == 7
      :ok = Store.put_setting(s, :w1_idle, 600)
      assert Store.get_setting(s, "w1_idle") == 600

      {:ok, 1} = Store.log_event(s, :finding_opened, %{id: "L1-abc"}, @now)
      {:ok, 2} = Store.log_event(s, :nudge_delivered, %{}, @now)

      assert [%{type: "finding_opened", data: %{"id" => "L1-abc"}}] =
               Store.list_events(s, type: :finding_opened)
    end
  end
end
