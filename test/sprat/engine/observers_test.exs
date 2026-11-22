defmodule Sprat.Engine.ObserversTest do
  # spec-v5 §3: the observers run as their own processes and the engine reads
  # what they publish. Named processes and tables: not async.
  use ExUnit.Case, async: false

  import Sprat.EngineHarness

  alias Sprat.Observer.{Live, ProjectServer, SessionServer, Tail}

  @sid "0d6e1c2a-aaaa-4bbb-8ccc-000000000001"
  @limit "You've hit your 5-hour limit · resets 11:50am (Europe/London)"

  setup do
    start_supervised!({Task.Supervisor, name: Sprat.Engine.TaskSupervisor})
    :ok
  end

  defp eventually(fun, tries \\ 200) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if tries == 0,
          do: flunk("never happened"),
          else: Process.sleep(10) && eventually(fun, tries - 1)

      value ->
        value
    end
  end

  test "sessions, transcripts and roadmaps come from their own processes; the engine decides" do
    h =
      start(
        observers: :processes,
        sessions_ms: 20,
        tail_ms: 20,
        cmux_ms: 50,
        accounts_ms: 50,
        project_ms: 50
      )

    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    started = DateTime.add(t0(), -600)

    append(h, @sid, [
      user(started, "Write the deal resolution tests"),
      say(DateTime.add(started, 60), "Writing the member-venue deal tests now."),
      limit(DateTime.add(started, 200), @limit)
    ])

    # The scanner found the session and started its process, which read the
    # transcript; the project's process loaded its roadmap.
    eventually(fn -> Live.get(:sessions, :sessions)[@sid] end)
    assert %Tail{} = eventually(fn -> Live.get(:tails, @sid) end)
    assert SessionServer.running?(@sid)

    eventually(fn ->
      tick(h)
      ProjectServer.entry(root)
    end)

    tick(h)
    assert %{state: :acted} = finding(h, "Q1", @sid)
    snap = snapshot(h)
    assert Enum.any?(snap.projects, &(&1.root == root))

    assert SessionServer.count() == 1
    assert ProjectServer.count() == 1

    # More transcript: the session's process picks it up, not the engine.
    append(h, @sid, [say(DateTime.add(started, 300), "Back on the deal tests.")])

    eventually(fn ->
      tail = Live.get(:tails, @sid)
      inspect(tail.events) =~ "Back on the deal tests"
    end)
  end

  test "a session in a new project shows its project on the next fast tick, not a minute later" do
    h = start(observers: :processes, sessions_ms: 20, tail_ms: 20, project_ms: 20)
    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    append(h, @sid, [user(t0(), "hello")])
    eventually(fn -> Live.get(:sessions, :sessions)[@sid] end)

    # Only fast ticks: the first one starts the project's process, a later
    # one (once it loaded the roadmap) shows the project.
    eventually(fn ->
      advance(h, 11)
      send(h.engine, :fast_tick)
      Enum.any?(snapshot(h).projects, &(&1.root == root))
    end)
  end

  test "a crashed session process is restarted and catches up" do
    h = start(observers: :processes, sessions_ms: 20, tail_ms: 20)
    root = repo(h, "proj")
    session(h, @sid, root, status: :idle)
    append(h, @sid, [user(t0(), "hello")])

    eventually(fn -> Live.get(:tails, @sid) end)
    [{pid, _}] = Registry.lookup(Sprat.Observer.SessionRegistry, @sid)
    Process.exit(pid, :kill)

    new_pid =
      eventually(fn ->
        case Registry.lookup(Sprat.Observer.SessionRegistry, @sid) do
          [{p, _}] when p != pid -> p
          _ -> nil
        end
      end)

    assert Process.alive?(new_pid)
    append(h, @sid, [say(t0(), "still here")])

    eventually(fn ->
      inspect(Live.get(:tails, @sid).events) =~ "still here"
    end)
  end
end
