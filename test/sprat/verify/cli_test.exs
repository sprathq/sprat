defmodule Sprat.Verify.CLITest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Store
  alias Sprat.Verify.CLI

  # Outside this checkout: a temp dir under it would sit inside its git repo.
  setup do
    tmp = Path.join(System.tmp_dir!(), "sprat-verify-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    project = Path.join(tmp, "proj")
    data = Path.join(tmp, "data")
    File.mkdir_p!(Path.join(project, ".sprat"))
    git = &System.cmd("git", ["-C", project, "-c", "user.email=t@t", "-c", "user.name=t" | &1])
    {_, 0} = System.cmd("git", ["init", "-q", project])

    File.write!(
      Path.join(project, "fail.sh"),
      "#!/bin/sh\necho 'compiling'\necho 'test/a_test.exs:3 assertion failed: 1 == 2' >&2\nexit 2\n"
    )

    File.chmod!(Path.join(project, "fail.sh"), 0o755)
    File.write!(Path.join([project, ".sprat", "checks"]), "# verify\ntrue\n./fail.sh\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-qm", "init"])

    opts = [data_dir: data, store_path: Path.join(data, "observer.db")]
    %{project: project, data: data, opts: opts, tmp: tmp}
  end

  defp input(project, active?) do
    JSON.encode!(%{
      "session_id" => "sess-1",
      "transcript_path" => "/dev/null",
      "cwd" => project,
      "hook_event_name" => "Stop",
      "stop_hook_active" => active?,
      "last_assistant_message" => "Done."
    })
  end

  test "blocks with the failing check, then allows on the same evidence, then re-checks a change",
       %{project: project, data: data, opts: opts} do
    out = CLI.stop(input(project, false), opts)
    assert %{"decision" => "block", "reason" => reason} = JSON.decode!(out)
    assert reason =~ "1 of 2 checks failed (blocked stop 1 of 4)"
    assert reason =~ "`./fail.sh`: FAILED (exit 2)"
    assert reason =~ "assertion failed: 1 == 2"
    assert reason =~ "`true` (exit 0)"

    state = JSON.decode!(File.read!(Path.join([data, "v4", "verify", "sess-1.json"])))
    assert state["blocks"] == 1
    assert state["failing"] == ["./fail.sh"]

    # Claude stops again without changing anything: allowed, never twice.
    assert CLI.stop(input(project, true), opts) == nil

    # It edits something: checks run again and still fail.
    File.write!(Path.join(project, "lib.ex"), "x")
    assert %{"reason" => r2} = JSON.decode!(CLI.stop(input(project, true), opts))
    assert r2 =~ "blocked stop 2 of 4"

    # It fixes the check: allowed, the count resets.
    File.write!(Path.join([project, ".sprat", "checks"]), "true\n")
    assert CLI.stop(input(project, true), opts) == nil

    assert JSON.decode!(File.read!(Path.join([data, "v4", "verify", "sess-1.json"])))["blocks"] ==
             0

    log = File.read!(Path.join([data, "v4", "verify.log"]))
    assert log =~ "block (failed) session=sess-1"
    assert log =~ "allow (same_evidence)"
    assert log =~ "allow (passed)"

    {:ok, store} = GenServer.start(Store, path: opts[:store_path])
    events = Store.list_events(store, type: :verify)
    assert length(events) == 4
    served = Store.served_since(store, ~U[2000-01-01 00:00:00Z])

    assert Enum.map(served, & &1.text) == [
             "refused a stop: ./fail.sh failed",
             "refused a stop: ./fail.sh failed"
           ]

    assert hd(served).project_name == "proj"
    GenServer.stop(store)
  end

  test "after four refusals in a row it lets the session stop and escalates",
       %{project: project, opts: opts} do
    for n <- 1..4 do
      File.write!(Path.join(project, "edit.txt"), "#{n}")
      assert %{"decision" => "block"} = JSON.decode!(CLI.stop(input(project, n > 1), opts))
    end

    File.write!(Path.join(project, "edit.txt"), "5")
    assert CLI.stop(input(project, true), opts) == nil

    {:ok, store} = GenServer.start(Store, path: opts[:store_path])
    [latest | _] = Store.served_since(store, ~U[2000-01-01 00:00:00Z])

    assert latest.text ==
             "stopped refusing after 4 blocked stops: ./fail.sh still failing, needs you"

    GenServer.stop(store)

    # A new user turn (stop_hook_active false) starts a new chain.
    assert %{"reason" => r} = JSON.decode!(CLI.stop(input(project, false), opts))
    assert r =~ "blocked stop 1 of 4"
  end

  test "no checks file: allows and touches nothing", %{tmp: tmp, data: data, opts: opts} do
    bare = Path.join(tmp, "bare")
    File.mkdir_p!(bare)
    assert CLI.stop(input(bare, false), opts) == nil
    refute File.exists?(Path.join([data, "v4", "verify"]))
    refute File.exists?(opts[:store_path])
  end

  test "any error allows silently", %{opts: opts, project: project} do
    assert CLI.stop("not json", opts) == nil
    assert CLI.stop("[]", opts) == nil
    # An unwritable data dir must not break the hook either.
    assert CLI.stop(input(project, false), Keyword.put(opts, :data_dir, "/dev/null/x")) == nil
  end

  @tag capture_log: true
  test "a store that cannot open is skipped", %{project: project, opts: opts} do
    opts = Keyword.put(opts, :store_path, "/dev/null/observer.db")
    assert %{"decision" => "block"} = JSON.decode!(CLI.stop(input(project, false), opts))
  end
end
