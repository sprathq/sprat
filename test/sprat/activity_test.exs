defmodule Sprat.ActivityTest do
  # The tables are named: one owner at a time.
  use ExUnit.Case, async: false

  alias Sprat.Activity

  test "without the process every call is a no-op" do
    assert Activity.emit(:job, text: "x") == :ok
    assert Activity.recent() == []
    assert Activity.commands() == []
    token = Activity.command_started("/usr/bin/git", ["log", "-1"])
    assert Activity.command_done(token, 0) == :ok
  end

  describe "running" do
    setup do
      for spec <- Activity.child_specs(), do: start_supervised!(spec)
      :ok
    end

    test "events come back newest first and reach subscribers" do
      Activity.subscribe()
      Activity.emit(:job, text: "first", project_root: "/p", status: :running)
      Activity.emit(:pm, text: "second", status: :ok)

      assert [%{text: "second", kind: :pm, status: :ok}, %{text: "first", project_root: "/p"}] =
               Activity.recent(10)

      assert_received {:activity, %{text: "first"}}
      assert_received {:activity, %{text: "second"}}
      assert [%{text: "second"}] = Activity.recent(1)
    end

    test "the stream keeps the newest 500" do
      for i <- 1..620, do: Activity.emit(:event, text: "e#{i}")
      Activity.emit(:event, text: "last")
      events = Activity.recent(1000)
      assert length(events) <= 550
      assert hd(events).text == "last"
    end

    test "programs are counted by name and subcommand, never their arguments" do
      t1 = Activity.command_started("/opt/homebrew/bin/git", ["log", "--oneline"])
      assert [%{name: "git log", running: 1}] = Activity.commands()
      Activity.command_done(t1, 0)

      t2 = Activity.command_started("/opt/homebrew/bin/git", ["-C", "/repo", "log", "-5"])
      Activity.command_done(t2, 1)

      t3 = Activity.command_started("/x/claude", ["[sprat] Your usage limit has reset."])
      Activity.command_done(t3, :timeout, "claude")

      assert %{name: "git log", runs: 2, running: 0, last_status: 1} =
               Enum.find(Activity.commands(), &(&1.name == "git log"))

      assert %{name: "claude", last_status: :timeout} =
               Enum.find(Activity.commands(), &(&1.name == "claude"))

      # Only the stopped one reaches the stream.
      assert [%{kind: :command, status: :failed, text: "claude did not finish" <> _}] =
               Activity.recent(10)
    end
  end
end
