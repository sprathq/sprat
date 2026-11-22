defmodule Sprat.Engine.SocketTest do
  # spec-v5 §6: the board subscribes to the daemon over a Unix socket.
  use ExUnit.Case, async: false

  import Sprat.EngineHarness

  alias Sprat.Engine.{Publisher, Remote}

  setup do
    start_supervised!({Task.Supervisor, name: Sprat.Engine.TaskSupervisor})
    dir = Path.join(System.tmp_dir!(), "sk#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp door(h, dir) do
    pub = :"pub#{System.unique_integer([:positive])}"
    sock = :"sock#{System.unique_integer([:positive])}"
    path = Path.join(dir, "s.sock")

    start_supervised!(
      {Publisher, name: pub, engine: h.engine, file: Path.join(dir, "snapshot.etf")},
      id: pub
    )

    start_supervised!(
      {Sprat.Engine.Socket, name: sock, path: path, engine: h.engine, publisher: pub},
      id: sock
    )

    %{pub: pub, sock: sock, path: path}
  end

  defp remote(path) do
    name = :"remote#{System.unique_integer([:positive])}"
    {:ok, _} = Remote.start(path: path, name: name)
    on_exit(fn -> if pid = Process.whereis(name), do: Process.exit(pid, :kill) end)
    name
  end

  defp eventually(fun, tries \\ 200) do
    case fun.() do
      v when v in [nil, false] ->
        if tries == 0,
          do: flunk("never happened"),
          else: Process.sleep(10) && eventually(fun, tries - 1)

      v ->
        v
    end
  end

  test "a board gets the snapshot pushed, and again the moment something changes", %{dir: dir} do
    h = start()
    d = door(h, dir)
    r = remote(d.path)
    Remote.listen(r, self())

    assert %{projects: _, daemon_warning: nil} = eventually(fn -> Remote.snapshot(r) end)
    assert File.exists?(Path.join(dir, "snapshot.etf"))
    assert {:ok, %{mode: mode}} = File.stat(d.path)
    assert Bitwise.band(mode, 0o077) == 0, "the socket is the owner's only"

    flush_updates()
    root = repo(h, "proj")
    session(h, "aaaaaaaa-1111-4111-8111-111111111111", root, status: :idle)
    tick(h)
    Publisher.dirty(d.pub)

    assert_receive {:sprat_update}, 1_000

    eventually(fn ->
      Enum.any?(Remote.snapshot(r).projects, &(&1.root == root))
    end)
  end

  test "commands go to the engine and their replies come back", %{dir: dir} do
    h = start()

    d = door(h, dir)
    r = remote(d.path)
    eventually(fn -> Remote.snapshot(r) end)

    assert {:ok, {:session_lines, []}} = Remote.command(r, {:session_lines, "nope"})
    assert {:error, "Unknown session."} = Remote.command(r, {:send_to_session, "nope", "hi"})
  end

  test "the daemon going away: the last snapshot, marked stale; then it reconnects", %{dir: dir} do
    h = start()
    d = door(h, dir)
    r = remote(d.path)
    eventually(fn -> Remote.snapshot(r) end)

    stop_supervised!(d.sock)
    stale = eventually(fn -> Remote.snapshot(r).daemon_warning end)
    assert stale =~ "lost sprat serve"
    assert {:error, _} = Remote.command(r, {:session_lines, "x"})

    start_supervised!(
      {Sprat.Engine.Socket, name: d.sock, path: d.path, engine: h.engine, publisher: d.pub},
      id: :again
    )

    eventually(fn -> Remote.snapshot(r).daemon_warning == nil end, 400)
    assert {:ok, {:session_lines, []}} = Remote.command(r, {:session_lines, "x"})
  end

  test "no daemon: start/1 says so, so the board can fall back to files", %{dir: dir} do
    assert {:error, _} = Remote.start(path: Path.join(dir, "none.sock"), name: :nobody)
  end

  defp flush_updates do
    receive do
      {:sprat_update} -> flush_updates()
    after
      0 -> :ok
    end
  end
end
