defmodule Sprat.EngineTest do
  # The engine runs PM investigations under the globally named
  # `Sprat.Engine.TaskSupervisor`, so these tests share it and run serially.
  use ExUnit.Case, async: false

  import Sprat.EngineHarness

  alias Sprat.Observer.Model.{Decision, Ticket}
  alias Sprat.Observer.Store
  alias Sprat.Roadmap
  alias Sprat.Roadmap.File, as: RFile

  @sid "aaaaaaaa-1111-4111-8111-111111111111"
  @sid2 "bbbbbbbb-2222-4222-8222-222222222222"
  @limit "You've hit your 5-hour limit · resets 11:50am (Europe/London)"

  setup do
    start_supervised!({Task.Supervisor, name: Sprat.Engine.TaskSupervisor})
    :ok
  end

  defp unblock(extra \\ []) do
    struct(
      %Decision{
        action: :unblock,
        obstacle: "bar/0 was renamed to bar/1 in the networks context",
        message: "bar/0 is now bar/1 (renamed in lib/networks.ex). Call bar(opts) and rerun.",
        confidence: :high,
        evidence_used: ["transcript:#{@sid}:3"]
      },
      extra
    )
  end

  defp ok(decision, meta \\ %{cost_usd: 0.05}), do: fn _ctx -> {:ok, decision, meta} end

  # An L1 loop in a live session on a fresh repo; returns the harness and root.
  defp looping(opts \\ []) do
    h = start(opts)
    root = repo(h, "proj")
    session(h, @sid, root)
    append(h, @sid, [user(DateTime.add(t0(), -600), "Carry on with A.2")])
    append(h, @sid, error_loop(DateTime.add(t0(), -480)))
    {h, root}
  end

  test "L1 under act: PM unblock is delivered, recorded, served, then resolved by the follow-up" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock()))

    tick(h)

    assert_received {:pm, "L1", fid}
    assert_received {:deliver, @sid, text, {:ok, :cmux}}
    assert String.starts_with?(text, "[sprat] bar/0 is now bar/1")
    assert String.ends_with?(text, "(roadmap: A.2 Loyalty.Networks context)")

    assert [%{text: ^text, state: "delivered"}] = Store.list_nudges(h.store, finding_id: fid)
    assert [%{text: "unblocked: " <> _, by: :sprat}] = Store.served_since(h.store, t0())
    assert finding(h, "L1").state == :acted
    assert %Ticket{owner: :sprat, headline: "following up: " <> _} = ticket(h, fid)

    # Ticks while the loop still matches keep what Sprat did on the finding.
    advance(h, 120)
    tick(h)
    assert %{nudge_id: "n_" <> _, delivered_at: %DateTime{}} = finding(h, "L1").data
    assert Store.get_finding(h.store, fid).data[:nudge_id]
    refute_received {:pm, _, _}

    # The agent fixed it; half an hour on the loop is gone.
    append(h, @sid, [
      bash(DateTime.add(t0(), 60), "ok1", "mix test test/networks_test.exs"),
      result(DateTime.add(t0(), 70), "ok1", "12 tests, 0 failures", false)
    ])

    advance(h, 31 * 60)
    tick(h)

    assert Store.get_finding(h.store, fid).state == :resolved
    assert [%{outcome: "resolved"}] = Store.list_nudges(h.store, finding_id: fid)

    assert Enum.any?(
             Store.served_since(h.store, t0()),
             &String.starts_with?(&1.text, "resolved:")
           )

    refute ticket(h, fid)
    refute_received {:pm, _, _}
  end

  test "L1 under propose (a new project's default): proposed, then fired by the owner" do
    {h, _root} = looping()
    pm(h, ok(unblock()))

    tick(h)

    assert_received {:pm, "L1", fid}
    refute_received {:deliver, _, _, _}

    assert %Ticket{owner: :yours, proposal: "[sprat] bar/0 is now bar/1" <> _ = proposal} =
             ticket(h, fid)

    assert String.ends_with?(proposal, "(roadmap: A.2 Loyalty.Networks context)")

    # The proposal survives later ticks.
    advance(h, 60)
    tick(h)
    assert %Ticket{owner: :yours, proposal: ^proposal} = ticket(h, fid)

    assert {:ok, {:message, "Sent."}} = command(h, {:fire, fid, nil})
    assert_received {:deliver, @sid, ^proposal, {:ok, :cmux}}
    fired_at = now(h)

    assert [%{text: ^proposal, delivered_at: ^fired_at}] =
             Store.list_nudges(h.store, finding_id: fid)

    served = Store.served_since(h.store, t0())
    assert [%{by: :owner, text: "you fired: " <> _}] = served
    assert %Ticket{owner: :sprat} = ticket(h, fid)
  end

  test "a fire that cannot be delivered says so and is not logged as served" do
    {h, _root} = looping()
    pm(h, ok(unblock()))
    tick(h)
    assert_received {:pm, "L1", fid}

    deliveries(h, fn _s, _text -> {:error, :no_adapter} end)

    assert {:error, "Not sent: delivery failed: :no_adapter. " <> hint} =
             command(h, {:fire, fid, nil})

    assert hint =~ "can't reach"
    assert Store.served_since(h.store, t0()) == []
    assert %Ticket{owner: :yours, headline: "delivery failed: :no_adapter"} = ticket(h, fid)
  end

  test "reassign marks the item blocked in .sprat/roadmap.md, recorded and revertible" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())

    pm(
      h,
      ok(
        unblock(
          action: :reassign,
          obstacle: "Deal rules wait on the payments spec",
          blocked_item: "A.3",
          blocked_reason: "waits on the payments spec",
          next_item: "A.4",
          message: "A.3 is blocked on the payments spec. Move on to the full gate."
        )
      )
    )

    tick(h)

    assert_received {:deliver, @sid, text, _}
    assert String.ends_with?(text, "(roadmap: A.4 Full gate)")

    assert %{state: :blocked, blocked_reason: "waits on the payments spec"} =
             Roadmap.find_item(RFile.read(root), "A.3")

    assert [%{id: wid, item_id: "A.3", to_state: "blocked", reverted_at: nil}] =
             Store.list_writes(h.store, root)

    fid = finding(h, "L1").id
    assert %Ticket{did: did} = ticket(h, fid)
    assert Enum.any?(did, &(&1.revertible_id == wid))

    assert {:ok, {:message, "Reverted A.3."}} = command(h, {:revert, wid})
    assert Roadmap.find_item(RFile.read(root), "A.3").state == :todo
    assert [%{reverted_at: %DateTime{}}] = Store.list_writes(h.store, root)

    tick(h)
    assert Roadmap.find_item(state(h).projects[root].roadmap, "A.3").state == :todo
  end

  test "done_items with a cited commit tick the item done, revertibly; without one, nothing" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())

    pm(
      h,
      ok(
        unblock(
          done_items: ["A.2"],
          evidence_used: ["transcript:x:1", "commit:abc1234"],
          message: "A.2 already landed in abc1234; carry on with A.3."
        )
      )
    )

    tick(h)

    assert Roadmap.find_item(RFile.read(root), "A.2").state == :done
    assert [%{id: wid, item_id: "A.2", to_state: "done"}] = Store.list_writes(h.store, root)
    assert {:ok, {:message, "Reverted A.2."}} = command(h, {:revert, wid})
    refute Roadmap.find_item(RFile.read(root), "A.2").state == :done
  end

  test "done_items without a commit in the evidence are ignored" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock(done_items: ["A.2"], evidence_used: ["transcript:x:1"])))

    tick(h)

    assert Store.list_writes(h.store, root) == []
  end

  test "owner-only content in the PM's message is refused and lands as yours" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock(message: "The fix is on main already: run git push and pull it back.")))

    tick(h)

    assert_received {:pm, "L1", fid}
    refute_received {:deliver, _, _, _}
    assert %Ticket{owner: :yours, headline: headline} = ticket(h, fid)
    assert headline =~ "refused"
    assert headline =~ "push"
    assert Store.list_nudges(h.store, finding_id: fid) == []
  end

  test "a delivery the session cannot take yet is held and retried on a later tick" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock()))
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    deliveries(h, fn _s, _text ->
      case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
        0 -> {:hold, :owner_typing}
        _ -> {:ok, :cmux}
      end
    end)

    tick(h)
    assert_received {:pm, "L1", fid}
    assert_received {:deliver, @sid, text, {:hold, :owner_typing}}
    assert Store.list_nudges(h.store, finding_id: fid) == []

    # Not due yet.
    advance(h, 30)
    tick(h)
    refute_received {:deliver, _, _, _}

    advance(h, 40)
    tick(h)
    assert_received {:deliver, @sid, ^text, {:ok, :cmux}}
    assert [%{text: ^text}] = Store.list_nudges(h.store, finding_id: fid)
    refute_received {:pm, _, _}
  end

  describe "a limit belongs to the login that hit it" do
    defp limited_two(opts) do
      h = start(opts)
      root = repo(h, "proj")
      session(h, @sid, root, status: :idle)
      session(h, @sid2, root, status: :idle)
      started = DateTime.add(t0(), -600)

      for sid <- [@sid, @sid2] do
        append(h, sid, [
          user(started, "Write the deal resolution tests"),
          say(DateTime.add(started, 60), "Writing the member-venue deal tests now."),
          limit(DateTime.add(started, 200), @limit)
        ])
      end

      tick(h)
      assert [%{limited_until: ~U[2026-11-23 11:50:00Z]}] = snapshot(h).header.limited_accounts
      h
    end

    test "/login to another account resumes the paused sessions now, not at the reset" do
      {:ok, login} = Agent.start_link(fn -> "acct-a" end)
      h = limited_two(login_fun: fn _dir -> Agent.get(login, & &1) end)
      assert [%{login: "acct-a"}] = snapshot(h).header.limited_accounts

      advance(h, 60)
      tick(h)
      refute_received {:deliver, _, "[sprat] Your usage limit" <> _, _}

      Agent.update(login, fn _ -> "acct-b" end)
      advance(h, 60)
      tick(h)

      assert_received {:deliver, _, "[sprat] Your usage limit has reset." <> _, _}

      # The second one five minutes later (resumes are spaced), and then the
      # dir is clear. The old login's limit message is still in the
      # transcripts; it does not limit the new login again.
      advance(h, 5 * 60 + 1)
      tick(h)
      assert_received {:deliver, _, "[sprat] Your usage limit has reset." <> _, _}
      advance(h, 60)
      tick(h)
      assert snapshot(h).header.limited_accounts == []
    end

    test "a session on the dir working again lifts the limit for the others" do
      h = limited_two([])

      append(h, @sid, [
        user(DateTime.add(t0(), 60), "go on"),
        say(DateTime.add(t0(), 120), "Back on the deal tests.")
      ])

      advance(h, 180)
      tick(h)
      assert_received {:deliver, @sid2, "[sprat] Your usage limit has reset." <> _, _}
      refute_received {:deliver, @sid, _, _}
    end
  end

  test "Q1 with a second free account on the project: offered, and f continues there" do
    other = Path.join(System.tmp_dir!(), "sprat-acct-#{System.unique_integer([:positive])}")
    plain = Path.join(System.tmp_dir!(), "sprat-acct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(other) && File.rm_rf!(plain) end)
    test = self()

    h =
      start(
        account_dirs: [plain, other],
        account_fun: fn root, dir, resume, text ->
          send(test, {:account, root, dir, resume, text})
          {:ok, :cmux}
        end
      )

    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    started = DateTime.add(t0(), -600)

    append(h, @sid, [
      user(started, "Write the deal resolution tests"),
      say(DateTime.add(started, 60), "Writing the member-venue deal tests now."),
      limit(DateTime.add(started, 200), @limit)
    ])

    # No other account has worked on this project yet: just wait for the reset.
    tick(h)
    fid = finding(h, "Q1", @sid).id

    # Scheduled once, not again on every tick.
    tick(h)
    tick(h)
    assert finding(h, "Q1", @sid).state == :acted
    assert [_] = Store.list_events(h.store, type: :limit_scheduled)
    assert %Ticket{headline: "usage limit · resumes " <> _, proposal: nil} = ticket(h, fid)

    # Two other accounts have worked on this project; only one can read this
    # session's transcript (a shared projects/), so it is the one offered.
    slug = Regex.replace(~r/[^A-Za-z0-9]/, root, "-")
    File.mkdir_p!(Path.join([plain, "projects", slug]))
    File.mkdir_p!(Path.join([other, "projects", slug]))
    File.write!(Path.join([other, "projects", slug, @sid <> ".jsonl"]), "")

    name = Path.basename(other)
    t = ticket(h, fid)
    assert t.headline =~ "#{name} is free and works on this project"
    assert t.action_label == "f continue on #{name}  ⏎ watch"
    assert t.proposal =~ "[sprat] The other account ran out of usage. Continue"

    # The project is not "limited" while a free account works on it.
    assert %{config_dirs: dirs} = Enum.find(snapshot(h).projects, &(&1.root == root))
    assert other in dirs and plain in dirs

    assert {{:ok, {:message, "Moving agent-aaaa to " <> _}}, [job]} =
             command_and_settle(h, {:fire, fid, t.proposal})

    assert %{kind: :switch_account, status: :done, ticket_id: ^fid} = job
    assert job.result =~ "started on #{name}"
    assert job.result =~ "carries on the same conversation"
    assert_received {:account, ^root, ^other, @sid, "[sprat] The other account" <> _}
    assert finding(h, "Q1", @sid).state == :dismissed

    assert [%{by: :owner, text: "you moved agent-aaaa to " <> ^name}] =
             Store.served_since(h.store, t0())

    # Resetting later does not resume the old session on top of the new one.
    set_now(h, ~U[2026-11-23 11:51:00Z])
    tick(h)
    refute_received {:deliver, _, "[sprat] Your usage limit" <> _, _}
  end

  test "f on an account with its own projects/ folder copies the conversation there first" do
    plain = Path.join(System.tmp_dir!(), "sprat-acct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(plain) end)
    test = self()

    h =
      start(
        account_dirs: [plain],
        account_fun: fn root, dir, resume, text ->
          send(test, {:account, root, dir, resume, text})
          {:ok, :cmux}
        end
      )

    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    started = DateTime.add(t0(), -600)

    append(h, @sid, [
      user(started, "Write the deal resolution tests"),
      say(DateTime.add(started, 60), "Writing the member-venue deal tests now."),
      limit(DateTime.add(started, 200), @limit)
    ])

    # The other account has worked on this project but keeps its own
    # conversations: it cannot read this session's transcript.
    slug = Regex.replace(~r/[^A-Za-z0-9]/, root, "-")
    File.mkdir_p!(Path.join([plain, "projects", slug]))
    tick(h)
    fid = finding(h, "Q1", @sid).id
    t = ticket(h, fid)
    assert t.action_label == "f continue on #{Path.basename(plain)}  ⏎ watch"

    assert {{:ok, {:message, "Moving " <> _}}, [job]} =
             command_and_settle(h, {:fire, fid, t.proposal})

    assert job.status == :done
    assert job.result =~ "the conversation was copied there"
    assert Enum.any?(job.steps, fn {_, text} -> text =~ "copying the conversation" end)

    # Resumed (and forked) with the whole conversation, not started over.
    assert_received {:account, ^root, ^plain, @sid, _}
    copy = Sprat.Observer.Transcript.locate(plain, @sid)
    assert copy
    assert File.read!(copy) =~ "Writing the member-venue deal tests now."
  end

  test "f whose session never starts: the job fails with why, the ticket stays" do
    other = Path.join(System.tmp_dir!(), "sprat-acct-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(other) end)

    h =
      start(
        account_dirs: [other],
        account_fun: fn _root, _dir, _resume, _text, step ->
          step.("opening a cmux workspace")
          {:error, "Claude didn't start in cmux workspace:9; it shows: Not logged in"}
        end
      )

    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    started = DateTime.add(t0(), -600)

    append(h, @sid, [
      user(started, "Write the deal resolution tests"),
      limit(DateTime.add(started, 200), @limit)
    ])

    slug = Regex.replace(~r/[^A-Za-z0-9]/, root, "-")
    File.mkdir_p!(Path.join([other, "projects", slug]))
    tick(h)
    fid = finding(h, "Q1", @sid).id
    t = ticket(h, fid)

    assert {{:ok, {:message, "Moving " <> _}}, [job]} =
             command_and_settle(h, {:fire, fid, t.proposal})

    assert job.status == :failed
    assert job.result =~ "Not logged in"
    assert {_, "opening a cmux workspace"} = List.last(job.steps)
    assert finding(h, "Q1", @sid).state == :acted
    assert Store.served_since(h.store, t0()) == []
    assert ticket(h, fid)
  end

  describe "the owner talks to a session from its screen" do
    test "sent as typed once the prompt is free; the job shows it waiting" do
      h = start(send_retry_ms: 5)
      root = repo(h, "proj")
      session(h, @sid, root, status: :busy)
      tick(h)

      {:ok, calls} = Agent.start_link(fn -> 0 end)

      deliveries(h, fn _s, _text ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:hold, :owner_typing}
          _ -> {:ok, :cmux}
        end
      end)

      assert {{:ok, {:message, "Sending to agent-aaaa…"}}, [job]} =
               command_and_settle(h, {:send_to_session, @sid, "what's left on C.4?"})

      assert %{kind: :message, status: :done, result: "sent via cmux"} = job
      assert [{_, "waiting: there is text in its prompt"}] = job.steps
      assert_received {:deliver, @sid, "what's left on C.4?", {:hold, :owner_typing}}
      assert_received {:deliver, @sid, "what's left on C.4?", {:ok, :cmux}}
    end

    test "gives up after the wait, says why; an ended or unknown session is refused" do
      h = start(send_retry_ms: 5, send_wait_ms: 30)
      root = repo(h, "proj")
      session(h, @sid, root, status: :busy)
      tick(h)
      deliveries(h, fn _s, _t -> {:hold, :dialog} end)

      assert {_, [job]} = command_and_settle(h, {:send_to_session, @sid, "hi"})
      assert job.status == :failed
      assert job.result =~ "a dialog is open; answer it first"

      assert {:error, "Unknown session."} = command(h, {:send_to_session, "nope", "hi"})
      session(h, @sid, root, live?: false, status: :ended)
      tick(h)
      assert {:error, msg} = command(h, {:send_to_session, @sid, "hi"})
      assert msg =~ "has ended"
    end
  end

  test "Q1: a usage limit limits the account, pauses PM runs, then resumes sessions 5 min apart" do
    h = start()
    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    session(h, @sid2, root, status: :idle)
    started = DateTime.add(t0(), -600)

    # Session one was looping when the limit hit: L1 would want a PM run.
    append(
      h,
      @sid,
      [user(DateTime.add(started, -60), "Next: A.2")] ++
        error_loop(started) ++ [limit(DateTime.add(started, 240), @limit)]
    )

    append(h, @sid2, [
      user(started, "Write the deal resolution tests for A.2"),
      say(DateTime.add(started, 60), "Writing the member-venue deal tests now."),
      limit(DateTime.add(started, 200), @limit)
    ])

    pm(h, ok(unblock(action: :wait, message: nil)))
    tick(h)

    snap = snapshot(h)

    assert [%{config_dir: cfg, limited_until: ~U[2026-11-23 11:50:00Z]}] =
             snap.header.limited_accounts

    assert cfg == h.cfg
    assert finding(h, "Q1", @sid).state == :acted
    assert finding(h, "Q1", @sid2).state == :acted

    assert %Ticket{owner: :sprat, headline: "usage limit · resumes " <> _} =
             ticket(h, finding(h, "Q1", @sid).id)

    for _ <- 1..3 do
      advance(h, 20 * 60)
      tick(h)
    end

    refute_received {:pm, _, _}
    refute_received {:deliver, _, _, _}

    set_now(h, ~U[2026-11-23 11:51:00Z])
    tick(h)
    assert_received {:deliver, first, "[sprat] Your usage limit has reset." <> _ = text, _}
    assert text =~ "(roadmap: A.2 Loyalty.Networks context)"
    refute_received {:deliver, _, "[sprat] Your usage limit" <> _, _}

    advance(h, 3 * 60)
    tick(h)
    refute_received {:deliver, _, "[sprat] Your usage limit" <> _, _}

    advance(h, 2 * 60)
    tick(h)
    assert_received {:deliver, second, "[sprat] Your usage limit has reset." <> _, _}
    assert Enum.sort([first, second]) == Enum.sort([@sid, @sid2])
    assert snapshot(h).header.limited_accounts == []

    # The limit stays cleared on later ticks (it is not re-read as tomorrow's).
    advance(h, 60)
    tick(h)
    assert snapshot(h).header.limited_accounts == []
    refute_received {:deliver, _, "[sprat] Your usage limit" <> _, _}

    # The loop held during the limit has aged out: it is not investigated late.
    refute_received {:pm, _, _}
  end

  test "Q1: a session talking about other work is not told the project's roadmap item" do
    h = start()
    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    started = DateTime.add(t0(), -600)

    append(h, @sid, [
      user(started, "[sprat] Continue with A.2 Loyalty.Networks context"),
      user(DateTime.add(started, 10), "Build the iOS scan shortcuts in the other repo"),
      say(DateTime.add(started, 60), "Task 4 passed. Next is Task 5: the iOS scan shortcuts."),
      limit(DateTime.add(started, 200), @limit)
    ])

    pm(h, ok(unblock(action: :wait, message: nil)))
    tick(h)
    set_now(h, ~U[2026-11-23 11:51:00Z])
    tick(h)

    assert_received {:deliver, @sid, text, _}

    assert text ==
             "[sprat] Your usage limit has reset. Continue from where you stopped: " <>
               "Task 4 passed. Next is Task 5: the iOS scan shortcuts."
  end

  test "W1: a question for the owner goes to the PM, escalates as yours, and dismissal sticks" do
    h = start()
    root = repo(h, "proj")
    session(h, @sid, root, status: :idle, status_since: DateTime.add(t0(), -15 * 60))
    asked = DateTime.add(t0(), -16 * 60)

    append(h, @sid, [
      user(DateTime.add(asked, -300), "Build the networks context"),
      say(asked, "The context is in.\n\nShould invites expire after 7 or 30 days?")
    ])

    pm(
      h,
      ok(%Decision{
        action: :escalate,
        obstacle: "No recorded decision on invite expiry",
        owner_note: "Decide invite expiry: 7 or 30 days (Sprat suggests 7).",
        confidence: :medium,
        evidence_used: ["transcript:#{@sid}:2"]
      })
    )

    tick(h)

    assert_received {:pm, "W1", fid}

    assert %Ticket{owner: :yours, headline: "Decide invite expiry: 7 or 30 days" <> _} =
             ticket(h, fid)

    # The owner hears about a new yours ticket on the next tick, once.
    tick(h)
    assert_received {:notify, _, "Decide invite expiry" <> _}
    tick(h)
    refute_received {:notify, _, _}

    assert :ok = command(h, {:dismiss, fid, "asked them in person"})
    refute ticket(h, fid)

    advance(h, 60)
    tick(h)
    refute ticket(h, fid)
    assert Store.get_finding(h.store, fid).state == :dismissed
    refute_received {:pm, _, _}

    # New evidence: the agent asks again.
    append(h, @sid, [
      say(DateTime.add(t0(), -11 * 60), "Should invites expire after 7 or 30 days?")
    ])

    tick(h)
    assert_received {:pm, "W1", ^fid}
    assert %Ticket{owner: :yours} = ticket(h, fid)
  end

  test "a PM that fails twice escalates with 'could not investigate'" do
    {h, _root} = looping()
    pm(h, fn _ctx -> {:error, :timeout, %{}} end)

    tick(h)
    assert_received {:pm, "L1", fid}
    refute ticket(h, fid).owner == :yours

    tick(h)
    assert_received {:pm, "L1", ^fid}
    assert %Ticket{owner: :yours, headline: headline} = ticket(h, fid)
    assert headline =~ "could not investigate"
    assert Store.count_pm_runs(h.store, fid) == 2

    tick(h)
    refute_received {:pm, _, _}
  end

  test "a decision that cites no evidence is retried once, then escalates" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock(evidence_used: [])))

    tick(h)
    assert_received {:pm, "L1", fid}
    refute_received {:deliver, _, _, _}
    refute ticket(h, fid).owner == :yours

    tick(h)
    assert_received {:pm, "L1", ^fid}
    assert %Ticket{owner: :yours} = ticket(h, fid)
    refute_received {:deliver, _, _, _}
  end

  test "budget: once the project's PM spend is at its cap, the next finding escalates without a run" do
    {h, root} = looping()
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    pm(h, ok(unblock(), %{cost_usd: 3.5}))

    tick(h)
    assert_received {:pm, "L1", first}
    # The run that crossed the cap is proposed, not delivered (§9.2).
    refute_received {:deliver, _, _, _}
    assert %Ticket{owner: :yours} = ticket(h, first)

    session(h, @sid2, root)
    append(h, @sid2, error_loop(DateTime.add(t0(), -400), "u"))
    tick(h)

    refute_received {:pm, _, _}
    second = finding(h, "L1", @sid2).id
    assert %Ticket{owner: :yours, headline: headline} = ticket(h, second)
    assert headline =~ "PM budget"
  end

  test "autonomy: propose becomes act after the first day unless the owner chose it" do
    h = start()
    auto = repo(h, "auto")
    chosen = repo(h, "chosen")
    Store.put_setting(h.store, "extra_projects", [auto, chosen])

    tick(h)
    assert state(h).projects[auto].autonomy == :propose
    assert {:ok, _} = command(h, {:set_autonomy, chosen, :propose})

    advance(h, 23 * 3600)
    tick(h)
    assert state(h).projects[auto].autonomy == :propose

    advance(h, 2 * 3600)
    tick(h)
    assert state(h).projects[auto].autonomy == :act
    assert %{level: :act, by: "sprat"} = Store.autonomy_change(h.store, auto)
    assert state(h).projects[chosen].autonomy == :propose
    assert %{level: :propose, by: "owner"} = Store.autonomy_change(h.store, chosen)
  end

  test "passive mode observes and detects but never investigates, delivers or notifies" do
    test = self()

    {h, root} =
      looping(
        passive: true,
        pm_fun: fn _, _ -> send(test, :pm_called) end,
        deliver_fun: fn _, _, _ -> send(test, :deliver_called) end,
        notify_fun: fn _, _ -> send(test, :notify_called) end
      )

    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())

    # A permission prompt too: outside passive mode it notifies at once.
    session(h, @sid2, root, status: :idle, status_since: DateTime.add(t0(), -10 * 60))

    append(h, @sid2, [
      user(DateTime.add(t0(), -20 * 60), "Run the migration"),
      bash(DateTime.add(t0(), -12 * 60), "p1", "mix ecto.migrate")
    ])

    tick(h)
    advance(h, 31 * 60)
    tick(h)

    assert finding(h, "L1")
    assert finding(h, "W2")
    assert Enum.all?(Map.values(state(h).findings), &(&1.state == :open))
    refute_received :pm_called
    refute_received :deliver_called
    refute_received :notify_called
  end

  test "snapshot: projects, tickets (yours first), served today, header" do
    h = start()
    root = repo(h, "proj")
    :ok = Store.set_autonomy(h.store, root, :act, "owner", t0())
    other_cfg = Path.join(h.tmp, "claude-work")

    # sprat: an L1 Sprat unblocked
    session(h, @sid, root)
    append(h, @sid, error_loop(DateTime.add(t0(), -480)))

    # yours: a permission prompt
    w2 = "cccccccc-3333-4333-8333-333333333333"
    session(h, w2, root, status: :idle, status_since: DateTime.add(t0(), -10 * 60))

    append(h, w2, [
      user(DateTime.add(t0(), -20 * 60), "Run the migration"),
      bash(DateTime.add(t0(), -12 * 60), "p1", "mix ecto.migrate")
    ])

    # sprat: a usage limit on another account
    session(h, @sid2, root, status: :idle, config_dir: other_cfg)

    append(
      h,
      @sid2,
      [user(DateTime.add(t0(), -600), "go"), limit(DateTime.add(t0(), -300), @limit)],
      other_cfg
    )

    pm(h, ok(unblock()))
    tick(h)

    snap = snapshot(h)

    assert %{now: now, projects: [project], tickets: tickets, served: served, header: header} =
             snap

    assert now == t0()
    assert project.root == root
    assert project.autonomy == :act
    assert project.position.item_id == "A.2"
    assert length(project.sessions) == 3

    assert [%Ticket{owner: :yours, finding: %{rule: "W2"}} | rest] = tickets
    assert Enum.all?(rest, &(&1.owner == :sprat))
    assert rest |> Enum.map(& &1.finding.rule) |> Enum.sort() == ["L1", "Q1"]

    assert [%{by: :sprat, project_name: "proj", text: "unblocked: " <> _}] = served

    assert %{
             pm_spend: spend,
             fleet_cap: 15.0,
             limited_accounts: [%{config_dir: ^other_cfg}],
             pm_running: 0,
             sessions: 3
           } = header

    assert_in_delta spend, 0.05, 1.0e-9
  end
end
