defmodule Sprat.Engine.QuietTest do
  use ExUnit.Case, async: true

  alias Sprat.Engine.Quiet
  alias Sprat.Observer.Model.{Account, Event, Finding, Item, Project, Session, SessionState}

  @now ~U[2026-11-23 14:00:00Z]
  @fmt &__MODULE__.hhmm/1

  def hhmm(t), do: Calendar.strftime(t, "%H:%M")

  defp session(attrs \\ []) do
    struct(
      %Session{
        session_id: "s1",
        live?: true,
        status: :idle,
        status_since: ~U[2026-11-23 13:40:00Z],
        config_dir: "/c/main"
      },
      attrs
    )
  end

  defp explain(s, ctx) do
    Quiet.explain(
      s,
      Map.merge(
        %{
          now: @now,
          project: %Project{root: "/p", autonomy: :act},
          item: %Item{id: "B.5", text: "onboarding", state: :doing},
          findings: []
        },
        ctx
      )
    )
  end

  defp texts(q),
    do: {Quiet.why_text(q, @fmt), Quiet.last_text(q, @now), Quiet.plan_text(q, @now, @fmt)}

  defp tool(name, input, line, at \\ ~U[2026-11-23 13:30:00Z]) do
    %Event{kind: :tool_use, line: line, at: at, data: %{id: "t#{line}", name: name, input: input}}
  end

  test "a finished turn with work left says when Sprat looks, by autonomy" do
    st = %SessionState{
      last_action: {~U[2026-11-23 13:38:00Z], :edit, "network_live.ex"}
    }

    q = explain(session(), %{state: st})
    assert q.reason == :turn_done

    assert texts(q) ==
             {"finished its turn", "edited network_live.ex 22m ago",
              "sprat looks at 14:10 and may nudge it on"}

    propose = explain(session(), %{state: st, project: %Project{root: "/p", autonomy: :propose}})
    assert Quiet.plan_text(propose, @now, @fmt) == "sprat looks at 14:10 and proposes a next step"

    watch = explain(session(), %{state: st, project: %Project{root: "/p", autonomy: :watch}})
    assert Quiet.plan_text(watch, @now, @fmt) == "sprat looks at 14:10, but only watches"
  end

  test "a question waits for the owner and Sprat sends nothing" do
    st = %SessionState{asks_user?: true, pending_question: "Keep network_id?\nmore"}
    q = explain(session(), %{state: st})

    assert {"asked you: Keep network_id?", nil, "waits for you; sprat sends it nothing"} =
             texts(q)
  end

  test "a tool with no result: running while busy, a permission prompt while idle" do
    st = %SessionState{pending_tool_uses: %{"t9" => tool("Bash", %{"command" => "mix test"}, 9)}}

    busy = explain(session(status: :busy), %{state: st})
    assert {:running, "mix test", ~U[2026-11-23 13:30:00Z]} = busy.reason
    assert Quiet.plan_text(busy, @now, @fmt) == nil

    idle = explain(session(), %{state: st})
    assert Quiet.why_text(idle, @fmt) == "waiting for your ok to run mix test"
    assert idle.plan == :waits_for_you
  end

  test "a usage limit: continued at the reset when live, restarted or proposed when ended" do
    st = %SessionState{
      usage_limit: %{reset_at: ~U[2026-11-23 15:10:00Z], kind: :five_hour, line: 3}
    }

    q = explain(session(), %{state: st})
    assert {"usage limit until 15:10", nil, "sprat continues it at 15:10"} = texts(q)

    ended = session(live?: false, status: :ended)

    assert Quiet.plan_text(
             explain(ended, %{state: st, project: %Project{root: "/p", autonomy: :act_resume}}),
             @now,
             @fmt
           ) == "sprat starts it again at 15:10"

    assert Quiet.plan_text(explain(ended, %{state: st}), @now, @fmt) ==
             "sprat asks you to start it again at 15:10"
  end

  test "an account limit counts even when the session's own transcript has none" do
    acct = %Account{config_dir: "/c/main", limited_until: ~U[2026-11-23 16:00:00Z]}
    q = explain(session(), %{state: %SessionState{}, account: acct})
    assert q.reason == {:limit, ~U[2026-11-23 16:00:00Z]}
  end

  test "the owner typing keeps Sprat out" do
    st = %SessionState{last_user_at: ~U[2026-11-23 13:59:00Z], last_user_text: "hm"}
    assert explain(session(), %{state: st}).plan == :stays_out
  end

  test "a finding already on the rail, or being looked into, is said so" do
    f = %Finding{id: "P4-x", rule: "P4", project_root: "/p", session_id: "s1", state: :open}
    assert explain(session(), %{state: %SessionState{}, findings: [f]}).plan == :on_rail

    running = %{f | state: :pm_running}

    assert Quiet.plan_text(explain(session(), %{findings: [running]}), @now, @fmt) ==
             "sprat is looking into it now"
  end

  test "nothing planned when the item is done or there is none" do
    done = explain(session(), %{item: %Item{id: "A.1", text: "x", state: :done}})
    assert Quiet.plan_text(done, @now, @fmt) == "its item is done; sprat leaves it"

    none = explain(session(), %{item: nil})
    assert Quiet.plan_text(none, @now, @fmt) == "no roadmap item; sprat leaves it"
  end

  test "the last thing it said reads as its first line" do
    st = %SessionState{
      last_action: {~U[2026-11-23 13:59:30Z], :say, nil},
      last_assistant_text: "The fix is in.\n\nMore."
    }

    assert Quiet.last_text(explain(session(), %{state: st}), @now) ==
             "wrote “The fix is in.” just now"
  end

  test "the fold keeps the main thread's last action, not a subagent's or a result" do
    alias Sprat.Observer.SessionState, as: Fold

    events = [
      tool("Edit", %{"file_path" => "/p/lib/a.ex"}, 1),
      %Event{kind: :tool_result, line: 2, at: ~U[2026-11-23 13:31:00Z], data: %{id: "t1"}},
      %{tool("Bash", %{"command" => "mix test"}, 3, ~U[2026-11-23 13:32:00Z]) | sidechain?: true}
    ]

    assert %{last_action: {~U[2026-11-23 13:30:00Z], :edit, "a.ex"}} = Fold.fold(events)
  end
end
