defmodule Sprat.CmdTest do
  use ExUnit.Case, async: true

  alias Sprat.Cmd

  test "returns output and exit status like System.cmd" do
    assert Cmd.run("sh", ["-c", "echo hi; echo err >&2; exit 3"]) == {"hi\nerr\n", 3}
  end

  test "stdin is closed, so a command reading it does not hang" do
    assert {"", 0} = Cmd.run("cat", [], timeout: 10_000)
  end

  test "a command past its deadline is killed" do
    {us, result} = :timer.tc(fn -> Cmd.run("sleep", ["30"], timeout: 200) end)
    assert {_, :timeout} = result
    assert us < 2_000_000
  end

  test "a missing executable is 127" do
    assert Cmd.run("definitely-not-a-command-sprat", []) == {"", 127}
  end

  test "cd and env are passed" do
    assert {"hello /\n", 0} =
             Cmd.run("sh", ["-c", "echo \"$X $(pwd)\""], env: [{"X", "hello"}], cd: "/")
  end
end
