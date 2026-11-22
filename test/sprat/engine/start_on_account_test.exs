defmodule Sprat.Engine.StartOnAccountTest do
  use ExUnit.Case, async: true

  alias Sprat.Engine

  setup do
    dir = Path.join(System.tmp_dir!(), "sprat-start-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sessions"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, root: "/Users/x/proj"}
  end

  defp fake_cmux(test, screen) do
    fn
      "cmux", ["new-workspace" | args], _opts ->
        send(test, {:new_workspace, args})
        {"OK workspace:9\n", 0}

      "cmux", ["read-screen" | args], _opts ->
        send(test, {:read_screen, args})
        {screen, 0}
    end
  end

  defp steps(test), do: fn text -> send(test, {:step, text}) end

  test "a session that appears in the account's sessions/ confirms the start", %{
    dir: dir,
    root: root
  } do
    test = self()

    write_session = fn ->
      File.write!(
        Path.join([dir, "sessions", "123.json"]),
        Jason.encode!(%{
          "pid" => 123,
          "sessionId" => "new-sid",
          "cwd" => root,
          "startedAt" => System.os_time(:millisecond)
        })
      )
    end

    spawn(fn ->
      Process.sleep(30)
      write_session.()
    end)

    assert {:ok, {:cmux, "workspace:9"}} =
             Engine.start_and_confirm(root, dir, "old-sid", "go on", steps(test),
               cmux_bin: "cmux",
               cmd: fake_cmux(test, ""),
               await_ms: 2_000,
               await_interval_ms: 10
             )

    assert_received {:new_workspace, args}
    assert "--command" in args
    assert Enum.any?(args, &(&1 =~ "claude --resume old-sid --fork-session"))
    assert_received {:step, "opening a cmux workspace for " <> _}
    assert_received {:step, "waiting for Claude to start and load the conversation"}
  end

  test "no session: the error carries what the terminal shows", %{dir: dir, root: root} do
    test = self()

    # An old session for the same folder does not count.
    File.write!(
      Path.join([dir, "sessions", "1.json"]),
      Jason.encode!(%{"sessionId" => "old", "cwd" => root, "startedAt" => 1})
    )

    screen =
      "\n➜ proj claude --resume old-sid\nNo conversation found with session ID: old-sid\n\n"

    assert {:error, why} =
             Engine.start_and_confirm(root, dir, "old-sid", "go on", steps(test),
               cmux_bin: "cmux",
               cmd: fake_cmux(test, screen),
               await_ms: 50,
               await_interval_ms: 10
             )

    assert why =~ "Claude didn't start in cmux workspace:9"
    assert why =~ "No conversation found with session ID: old-sid"
    assert_received {:read_screen, ["--workspace", "workspace:9" | _]}
  end
end
