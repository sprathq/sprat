defmodule Sprat.VerifyTest do
  use ExUnit.Case, async: true

  alias Sprat.Verify

  defp ctx(overrides) do
    Map.merge(
      %{
        checks: ["mix test", "mix format --check-formatted"],
        results: [],
        blocks_so_far: 0,
        max_blocks: 4,
        changed_since_last_block?: true
      },
      Map.new(overrides)
    )
  end

  defp pass(cmd), do: %{command: cmd, exit: 0, status: :passed, tail: "ok"}
  defp fail(cmd, out, code \\ 1), do: %{command: cmd, exit: code, status: :failed, tail: out}

  describe "decide/2" do
    test "allows when every check passed" do
      results = [pass("mix test"), pass("mix format --check-formatted")]
      assert Verify.decide(%{"stop_hook_active" => false}, ctx(results: results)) == :allow
    end

    test "allows when there are no checks (Verify is opt-in)" do
      assert Verify.decide(%{}, ctx(checks: [], results: [])) == :allow
    end

    test "blocks with the failing check, its exit code, failing lines and one next action" do
      out = """
      Compiling 3 files
      ....
        1) test books a class (BookingTest)
           Assertion with == failed
           code:  assert booked == true
      Finished in 0.2 seconds
      5 tests, 1 failure
      """

      results = [fail("mix test", out, 2), pass("mix format --check-formatted")]

      assert {:block, reason} =
               Verify.decide(%{"stop_hook_active" => false}, ctx(results: results))

      assert reason =~ "Sprat: not done yet — 1 of 2 checks failed (blocked stop 1 of 4)."
      assert reason =~ "`mix test`: FAILED (exit 2)"
      assert reason =~ "Assertion with == failed"
      assert reason =~ "5 tests, 1 failure"
      refute reason =~ "Compiling 3 files"
      assert reason =~ "Next: make `mix test` pass"
      assert reason =~ "`mix format --check-formatted` (exit 0)"
      assert length(Regex.scan(~r/^Next:/m, reason)) == 1
      refute reason =~ ~r/try harder/i
    end

    test "quotes at most 15 failing lines in all" do
      out = Enum.map_join(1..40, "\n", &"error #{&1}")
      results = [fail("a", out), fail("b", out), fail("c", out)]
      {:block, reason} = Verify.decide(%{}, ctx(checks: ~w(a b c), results: results))
      assert length(Regex.scan(~r/^   error/m, reason)) <= 15
      assert reason =~ "3 of 3 checks failed"
      assert reason =~ "Next: fix `a` first"
    end

    test "falls back to the last lines when nothing looks like a failure" do
      out = Enum.map_join(1..30, "\n", &"line #{&1}")
      {:block, reason} = Verify.decide(%{}, ctx(checks: ["x"], results: [fail("x", out)]))
      assert reason =~ "line 30"
      refute reason =~ "line 1\n"
    end

    test "never blocks twice on the same evidence" do
      results = [fail("mix test", "1 failure")]
      input = %{"stop_hook_active" => true}

      assert Verify.decide(
               input,
               ctx(results: results, blocks_so_far: 1, changed_since_last_block?: false)
             ) ==
               :allow

      assert Verify.allow_without_running(
               input,
               ctx(blocks_so_far: 1, changed_since_last_block?: false)
             ) ==
               :same_evidence

      assert {:block, reason} =
               Verify.decide(
                 input,
                 ctx(results: results, blocks_so_far: 1, changed_since_last_block?: true)
               )

      assert reason =~ "blocked stop 2 of 4"
    end

    test "allows once the ceiling on blocked stops is spent" do
      results = [fail("mix test", "1 failure")]
      c = ctx(results: results, blocks_so_far: 4)
      assert Verify.decide(%{"stop_hook_active" => true}, c) == :allow
      assert Verify.allow_without_running(%{"stop_hook_active" => true}, c) == :max_blocks
    end

    test "a check that could not start never blocks on its own" do
      broken = %{command: "nope", exit: nil, status: :error, tail: "command not found: nope"}
      assert Verify.decide(%{}, ctx(checks: ["nope"], results: [broken])) == :allow

      {:block, reason} =
        Verify.decide(%{}, ctx(checks: ["nope", "x"], results: [broken, fail("x", "error")]))

      assert reason =~ "Could not run (the owner's to fix in .sprat/checks, not yours): `nope`."
    end

    test "a timed-out check blocks" do
      t = %{command: "slow", exit: nil, status: :timed_out, tail: "killed after 300s"}
      {:block, reason} = Verify.decide(%{}, ctx(checks: ["slow"], results: [t]))
      assert reason =~ "`slow`: TIMED OUT (killed after 300s)"
    end
  end

  describe "parse_checks/1 and load_checks/1" do
    @tag :tmp_dir
    test "one command per line, comments and blanks skipped", %{tmp_dir: dir} do
      assert Verify.load_checks(dir) == []
      File.mkdir_p!(Path.join(dir, ".sprat"))

      File.write!(
        Verify.checks_path(dir),
        "# header\n\nmix test\n  # indented comment\nmix format --check-formatted\n"
      )

      assert Verify.load_checks(dir) == ["mix test", "mix format --check-formatted"]
    end
  end

  describe "run_checks/3" do
    @tag :tmp_dir
    test "runs real commands in the given directory, without a shell", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "marker"), "here")

      [ok, bad, pipe, missing] =
        Verify.run_checks(dir, ["true", "false", "ls marker | wc", "no-such-cmd-sprat"])

      assert %{status: :passed, exit: 0} = ok
      assert %{status: :failed, exit: 1} = bad
      # No shell: `|` is an argument to ls, which fails.
      assert %{status: :failed} = pipe
      assert %{status: :error, tail: "command not found: no-such-cmd-sprat"} = missing

      [ls] = Verify.run_checks(dir, ["ls"])
      assert ls.tail =~ "marker"
    end

    @tag :tmp_dir
    test "kills a check at its timeout", %{tmp_dir: dir} do
      [r] = Verify.run_checks(dir, ["sleep 5"], timeout_ms: 300)
      assert r.status == :timed_out
    end

    test "checks past the budget are not run" do
      runner = fn _argv, _dir, _t -> Process.sleep(30) && {"ok", 0} end
      [a, b] = Verify.run_checks("/", ["a", "b"], budget_ms: 1_020, runner: runner)
      assert a.status == :passed
      # 1_020 - ~30ms leaves under the 1 s floor for the second check.
      assert b.status == :not_run
    end

    test "uses the injected runner with the split argv" do
      me = self()

      runner = fn argv, dir, _t ->
        send(me, {:ran, argv, dir})
        {"boom", 3}
      end

      [r] = Verify.run_checks("/proj", [~s(mix test "test/a b.exs")], runner: runner)
      assert_received {:ran, ["mix", "test", "test/a b.exs"], "/proj"}
      assert %{exit: 3, status: :failed, tail: "boom"} = r
    end
  end

  describe "fingerprint/1" do
    test "changes with the working tree, nil outside git" do
      dir = Path.join(System.tmp_dir!(), "sprat-verify-fp-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      assert Verify.fingerprint(dir) == nil
      {_, 0} = System.cmd("git", ["init", "-q", dir])
      empty = Verify.fingerprint(dir)
      assert is_binary(empty)
      File.write!(Path.join(dir, "a.txt"), "1")
      one = Verify.fingerprint(dir)
      assert one != empty
      assert Verify.fingerprint(dir) == one
      git = &System.cmd("git", ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" | &1])
      {_, 0} = git.(["add", "."])
      {_, 0} = git.(["commit", "-qm", "a"])
      committed = Verify.fingerprint(dir)
      File.write!(Path.join(dir, "a.txt"), "2")
      assert Verify.fingerprint(dir) != committed
    end
  end
end
