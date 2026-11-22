defmodule Sprat.SessionTest do
  use Sprat.StoreCase, async: true

  alias Sprat.{Session, SessionSupervisor}
  alias Sprat.Session.{PubSub, Subscriber}
  alias Sprat.Store.{Events, Messages, Sessions, Tasks}
  alias Sprat.Terminal.Renderer

  defp open(store, session_id), do: SessionSupervisor.open(session_id, store: store)

  # Terminates the child without restarting it (a `:permanent` child would
  # otherwise be restarted automatically by the DynamicSupervisor), then
  # opens the session fresh — a real process restart, not a mock of one.
  defp restart(store, session_id, pid) do
    :ok = DynamicSupervisor.terminate_child(Sprat.SessionSupervisor, pid)
    {:ok, new_pid} = open(store, session_id)
    new_pid
  end

  defp new_session(store, attrs \\ %{}) do
    {:ok, session} = Sessions.create(store, Map.put_new(attrs, :project_path, "/tmp/proj"))
    session
  end

  describe "submit_user_message/2 and add_block/2" do
    test "persists a messages row and a message.appended event in one write", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)

      :ok = Session.submit_user_message(pid, "hello there")

      [message] = Messages.by_session(store, session.id)
      assert message.role == "user"
      assert message.content =~ "hello there"

      assert Events.by_session(store, session.id) |> Enum.any?(&(&1.type == "message.appended"))
    end

    test "add_block persists a non-user block under its own role", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)

      :ok = Session.add_block(pid, %{kind: :agent_message, role: "PM", markdown: "hi there"})

      [message] = Messages.by_session(store, session.id)
      assert message.role == "PM"

      %{blocks: [block]} = Session.snapshot(pid)

      assert block == %{
               kind: :agent_message,
               role: "PM",
               markdown: "hi there",
               occurred_at: message.occurred_at
             }
    end

    test "a submitted user message is appended to the project's composer history", %{store: store} do
      session = new_session(store, %{project_path: "/tmp/proj-history-test"})
      {:ok, pid} = open(store, session.id)

      :ok = Session.submit_user_message(pid, "remember me")

      assert "remember me" in Sprat.Store.ProjectHistory.load("/tmp/proj-history-test")
    end
  end

  describe "replay equivalence" do
    test "a resumed session rebuilds an identical transcript from stored blocks", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)

      :ok = Session.submit_user_message(pid, "first")
      :ok = Session.add_block(pid, %{kind: :agent_message, role: "PM", markdown: "reply"})

      :ok =
        Session.add_block(pid, %{
          kind: :tool_call,
          role: "Researcher",
          summary: "web_search(\"x\")"
        })

      :ok = Session.submit_user_message(pid, "second")

      live_blocks = Session.snapshot(pid).blocks
      assert length(live_blocks) == 4

      new_pid = restart(store, session.id, pid)
      assert Session.snapshot(new_pid).blocks == live_blocks
    end

    # Defect backlog item 2: a real database from an older Sprat build has
    # `messages` rows whose `content` predates the JSON envelope entirely
    # (plain text, not JSON) — `Session.init/1`'s replay used to call
    # `Block.decode!/1` on every row and crash on the first one, taking
    # `sprat --resume` down with it before the user saw a single line.
    # `Messages.append/3` here writes that same shape directly (bypassing
    # `Block.encode/1`, which a current build would never produce) to
    # reproduce it without a fixture database.
    test "resume tolerates a legacy row Block.decode/1 can't interpret: placeholder, not a crash",
         %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)

      :ok = Session.submit_user_message(pid, "before the legacy row")

      {:ok, _} =
        Sprat.Store.Messages.append(store, session.id, %{
          role: "researcher",
          content: "Assigned to Researcher: a pre-JSON-envelope row from an old build"
        })

      :ok = Session.submit_user_message(pid, "after the legacy row")

      new_pid = restart(store, session.id, pid)
      blocks = Session.snapshot(new_pid).blocks

      assert length(blocks) == 3
      assert Enum.at(blocks, 0).text == "before the legacy row"
      assert Enum.at(blocks, 1).kind == :system
      assert Enum.at(blocks, 1).text == "(a message from an older Sprat build could not be read)"
      assert Enum.at(blocks, 2).text == "after the legacy row"
    end
  end

  describe "pub/sub boundary" do
    test "the session broadcasts block_added to subscribers without them polling", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)

      {:ok, _owner} = PubSub.subscribe(session.id)
      :ok = Session.submit_user_message(pid, "ping")

      assert_receive {:sprat_session, sid, {:block_added, %{kind: :user_message, text: "ping"}}}
      assert sid == session.id
    end

    test "Sprat.Session never calls the renderer: Subscriber is the only adapter", %{store: store} do
      # Compile-time proof, not a runtime one: Sprat.Session's object code
      # does not reference Sprat.Terminal.* or Sprat.Session.Render at all
      # — only Sprat.Session.Subscriber does (see its own moduledoc).
      {:ok, {_mod, chunks}} = :beam_lib.chunks(:code.which(Sprat.Session), [:atoms])
      atoms = chunks[:atoms] |> Enum.map(&elem(&1, 1))

      refute Sprat.Terminal.Renderer in atoms
      refute Sprat.Session.Render in atoms

      # Sanity: the module under test actually loads and runs, so the
      # absence above isn't just because it failed to compile.
      session = new_session(store)
      assert {:ok, _pid} = open(store, session.id)
    end

    test "Subscriber replays existing blocks in one batched commit, not one per block", %{
      store: store
    } do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)
      Session.submit_user_message(pid, "a")
      Session.submit_user_message(pid, "b")
      Session.submit_user_message(pid, "c")

      {:ok, io} = StringIO.open("")
      name = :"renderer_#{System.unique_integer([:positive])}"
      {:ok, renderer_pid} = Renderer.start_link(io_device: io, name: name, skip_timers: true)

      # Suspend the renderer (an OTP `:sys` primitive: it stops handling
      # messages until resumed) *before* the Subscriber sends anything, so
      # its mailbox can't be drained concurrently and the count below is
      # deterministic. `cols: 80` skips the renderer round-trip Subscriber
      # would otherwise make for the draw width, so the only messages that
      # can land in the mailbox are the ones under test.
      :sys.suspend(renderer_pid)
      {:ok, sub_pid} = Subscriber.start_link(session_id: session.id, renderer: name, cols: 80)

      # Subscriber's init/1 (and therefore start_link/1) only returns after
      # every cast it issues for the replay has been sent — exactly one
      # `commit` (for all 3 blocks batched together) and one `set_live`,
      # not 3 separate commits.
      assert {:message_queue_len, 2} = Process.info(renderer_pid, :message_queue_len)

      :sys.resume(renderer_pid)
      GenServer.stop(sub_pid)
      GenServer.stop(renderer_pid)
    end

    # `Sprat.Session`'s own `live` struct carries `checklist`/`activity`
    # fields it never actually writes (`Sprat.Orchestrator`'s own
    # `PubSub.broadcast/2` sets those, bypassing this GenServer's state
    # entirely). `await_permission/2`, `answer_permission/2` and
    # `cancel_permission/1` must broadcast only the `permission` key they
    # actually changed — broadcasting the whole `live` map would send
    # `checklist: nil` every time a prompt appears or is answered,
    # clobbering whatever checklist status was just broadcast (this is
    # exactly what a real run showed: a stage broadcast `:failed` right
    # before its recovery prompt, and the checklist went blank instead of
    # showing the failed glyph).
    test "await_permission/answer_permission broadcast only :permission, never a stale :checklist",
         %{store: store} do
      session = new_session(store)
      {:ok, pid} = open(store, session.id)
      {:ok, _owner} = PubSub.subscribe(session.id)

      Task.start(fn ->
        Session.await_permission(pid, %{title: "t", lines: [], options: ["a", "b"], selected: 0})
      end)

      assert_receive {:sprat_session, _, {:live_updated, live}}
      refute Map.has_key?(live, :checklist)
      assert %{permission: %{title: "t"}} = live

      :ok = Session.answer_permission(pid, 0)
      assert_receive {:sprat_session, _, {:live_updated, %{permission: nil} = live2}}
      refute Map.has_key?(live2, :checklist)
    end
  end

  describe "recovery surfacing" do
    test "an interrupted task is shown as a numbered prompt when the session opens", %{
      store: store
    } do
      {session, _mission, task} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task.id, :running, %{session_id: session.id})

      {:ok, pid} = open(store, session.id)

      assert %{title: "Recovered task", options: [_, _, _], selected: 0} =
               Session.snapshot(pid).live.permission

      assert Tasks.get(store, task.id).status == "interrupted"
    end

    test "recovery_choice/2 records the decision as an event and clears the prompt", %{
      store: store
    } do
      {session, _mission, task} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task.id, :running, %{session_id: session.id})
      {:ok, pid} = open(store, session.id)

      :ok = Session.recovery_choice(pid, 0)

      assert [event] = Events.by_type(store, session.id, "recovery.decision")
      assert event.payload =~ ~s("choice":"resume")

      snapshot = Session.snapshot(pid)
      assert snapshot.live.permission == nil

      assert Enum.any?(
               snapshot.blocks,
               &(&1.kind == :system and &1.text =~ "no orchestration")
             )
    end

    test "'cancel' also transitions the task to cancelled", %{store: store} do
      {session, _mission, task} = fixture_chain(store)
      {:ok, _} = Tasks.transition(store, task.id, :running, %{session_id: session.id})
      {:ok, pid} = open(store, session.id)

      :ok = Session.recovery_choice(pid, 2)

      assert Tasks.get(store, task.id).status == "cancelled"
    end

    test "a session with no interrupted tasks shows no permission prompt", %{store: store} do
      {session, _mission, _task} = fixture_chain(store)
      {:ok, pid} = open(store, session.id)
      assert Session.snapshot(pid).live.permission == nil
    end
  end

  describe "notifications (Sprat.Notify)" do
    defp open_notifying(store, session_id) do
      parent = self()

      SessionSupervisor.open(session_id,
        store: store,
        tty_check: fn -> true end,
        notifier: fn title, message -> send(parent, {:notified, title, message}) end
      )
    end

    test "await_permission fires a pause notification — the same hook covers fetch approval, Directions choice and stage-failure recovery, which all funnel through it",
         %{store: store} do
      session = new_session(store)
      {:ok, pid} = open_notifying(store, session.id)

      Task.start(fn ->
        Session.await_permission(pid, %{title: "t", lines: [], options: ["a"], selected: 0})
      end)

      assert_receive {:notified, "Sprat needs you", "waiting for your input"}, 2_000
    end

    test "notify_finished/2 fires a mission-delivered notification", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open_notifying(store, session.id)

      :ok = Session.notify_finished(pid, :completed)
      assert_receive {:notified, "Sprat", "mission delivered"}, 2_000
    end

    test "notify_finished/2 fires a mission-failed notification", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open_notifying(store, session.id)

      :ok = Session.notify_finished(pid, :failed)
      assert_receive {:notified, "Sprat", "mission failed"}, 2_000
    end

    test "a plain-mode session (notify?: false) never notifies", %{store: store} do
      session = new_session(store)
      parent = self()

      {:ok, pid} =
        SessionSupervisor.open(session.id,
          store: store,
          notify?: false,
          tty_check: fn -> true end,
          notifier: fn title, message -> send(parent, {:notified, title, message}) end
        )

      :ok = Session.notify_finished(pid, :completed)
      refute_receive {:notified, _, _}, 50
    end

    test "adding an ordinary block (a model turn) never notifies", %{store: store} do
      session = new_session(store)
      {:ok, pid} = open_notifying(store, session.id)

      :ok = Session.add_block(pid, %{kind: :system, text: "just a turn"})
      refute_receive {:notified, _, _}, 50
    end
  end
end
