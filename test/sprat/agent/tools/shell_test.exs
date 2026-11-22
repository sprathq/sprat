defmodule Sprat.Agent.Tools.ShellTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.Shell
  alias Sprat.Store.{Blob, Runs}

  setup %{tmp_dir: tmp_dir} do
    worktree = Path.join(tmp_dir, "worktree")
    File.mkdir_p!(worktree)
    {:ok, worktree: worktree}
  end

  defp context(store, mission, task, worktree, extra \\ %{}) do
    Map.merge(
      %{
        worktree_root: worktree,
        granted: %{shell: true, network_install: true},
        store: store,
        mission_id: mission.id,
        task_id: task.id
      },
      extra
    )
  end

  describe "call/2" do
    test "runs an allow-listed executable with an explicit argument array", %{
      store: store,
      worktree: worktree
    } do
      {_session, mission, task} = fixture_chain(store)

      assert {:ok, %{"exit_code" => 0, "output" => output}} =
               Shell.call(
                 %{"command" => "git", "args" => ["--version"], "purpose" => "other"},
                 context(store, mission, task, worktree)
               )

      assert output =~ "git version"
    end

    test "refuses a command not on the allow list, by name, without running it", %{
      store: store,
      worktree: worktree
    } do
      {_session, mission, task} = fixture_chain(store)

      assert {:error, %{"kind" => "executable_denied", "message" => message}} =
               Shell.call(
                 %{"command" => "rm", "args" => ["-rf", "/"], "purpose" => "other"},
                 context(store, mission, task, worktree)
               )

      assert message =~ "rm"
      assert Runs.by_task(store, task.id) == []
    end

    test "refuses an executable name containing a path separator", %{
      store: store,
      worktree: worktree
    } do
      {_session, mission, task} = fixture_chain(store)

      assert {:error, %{"kind" => "executable_denied"}} =
               Shell.call(
                 %{"command" => "../../bin/sh", "args" => [], "purpose" => "other"},
                 context(store, mission, task, worktree)
               )
    end

    test "an argument array is never interpreted by a shell", %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)
      marker = Path.join(worktree, "should_not_exist")

      # if this string were ever handed to `sh -c`, it would create the
      # marker file; as a literal argv[1] to `git`, it's just a bad
      # revision name that fails cleanly.
      assert {:error, %{"kind" => "nonzero_exit"}} =
               Shell.call(
                 %{
                   "command" => "git",
                   "args" => ["rev-parse", "; touch #{marker} #"],
                   "purpose" => "other"
                 },
                 context(store, mission, task, worktree)
               )

      refute File.exists?(marker)
    end

    test "needs the shell grant before running anything", %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)
      ctx = context(store, mission, task, worktree, %{granted: %{shell: false}})

      assert {:needs_approval, %{action: "shell"}} =
               Shell.call(
                 %{"command" => "git", "args" => ["--version"], "purpose" => "other"},
                 ctx
               )

      assert Runs.by_task(store, task.id) == []
    end

    test "an install purpose needs the network_install grant separately from shell", %{
      store: store,
      worktree: worktree
    } do
      {_session, mission, task} = fixture_chain(store)

      ctx =
        context(store, mission, task, worktree, %{
          granted: %{shell: true, network_install: false}
        })

      assert {:needs_approval, %{action: "network_install"}} =
               Shell.call(
                 %{"command" => "git", "args" => ["--version"], "purpose" => "install"},
                 ctx
               )
    end

    test "records run evidence: command, cwd, exit code, duration, blob hash, sandbox strength, purpose",
         %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)

      assert {:ok, _} =
               Shell.call(
                 %{"command" => "git", "args" => ["--version"], "purpose" => "health_check"},
                 context(store, mission, task, worktree)
               )

      [run] = Runs.by_task(store, task.id)
      assert run.command == "git"
      assert run.args == ["--version"]
      assert run.cwd == worktree
      assert run.exit_code == 0
      assert is_integer(run.duration_ms)
      assert run.sandbox_strength == "partial"
      assert run.purpose == "health_check"
      assert run.network == false
      assert {:ok, blob} = Blob.get(run.output_blob_hash)
      assert blob =~ "git version"
    end

    test "an install run is recorded with network: true", %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)

      {:ok, _} =
        Shell.call(
          %{"command" => "git", "args" => ["--version"], "purpose" => "install"},
          context(store, mission, task, worktree)
        )

      [run] = Runs.by_task(store, task.id)
      assert run.network == true
    end

    test "output over the cap is truncated and flagged", %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)

      script = Path.join(worktree, "big.sh")
      File.write!(script, "#!/bin/sh\nyes x | head -c 500000\n")
      File.chmod!(script, 0o755)

      ctx = context(store, mission, task, worktree, %{allowed_executables: ["sh"]})

      assert {:ok, %{"truncated" => true, "output" => output}} =
               Shell.call(%{"command" => "sh", "args" => [script], "purpose" => "other"}, ctx)

      assert output =~ "[truncated]"
      assert byte_size(output) < 500_000

      [run] = Runs.by_task(store, task.id)
      assert run.truncated == true
    end

    test "a secret in captured output is redacted before storage and before the model sees it",
         %{store: store, worktree: worktree} do
      {_session, mission, task} = fixture_chain(store)

      ctx =
        context(store, mission, task, worktree, %{
          allowed_executables: ["sh"],
          secrets: ["sk-super-secret-value"]
        })

      assert {:ok, %{"output" => output}} =
               Shell.call(
                 %{
                   "command" => "sh",
                   "args" => ["-c", "echo sk-super-secret-value"],
                   "purpose" => "other"
                 },
                 ctx
               )

      refute output =~ "sk-super-secret-value"
      assert output =~ "[REDACTED]"

      [run] = Runs.by_task(store, task.id)
      {:ok, blob} = Blob.get(run.output_blob_hash)
      refute blob =~ "sk-super-secret-value"
    end

    test "a timeout kills the process tree, including a grandchild the child spawns", %{
      store: store,
      worktree: worktree
    } do
      {_session, mission, task} = fixture_chain(store)

      marker = Path.join(worktree, "grandchild_alive")

      # parent (sh) spawns a child (sh) that spawns a grandchild (sh) that
      # sleeps well past the timeout and touches `marker` on a loop, so we
      # can tell whether it's still running after the kill.
      script = """
      sh -c 'sh -c "while true; do touch #{marker}; sleep 0.1; done" &
      wait'
      """

      script_path = Path.join(worktree, "spawn_tree.sh")
      File.write!(script_path, script)
      File.chmod!(script_path, 0o755)

      ctx = context(store, mission, task, worktree, %{allowed_executables: ["sh"]})

      assert {:error, %{"kind" => "timeout"}} =
               Shell.call(
                 %{
                   "command" => "sh",
                   "args" => [script_path],
                   "purpose" => "other",
                   "timeout_ms" => 300
                 },
                 ctx
               )

      # give the grandchild a moment to have proven itself alive (or not)
      mtime_at_kill =
        case File.stat(marker) do
          {:ok, %File.Stat{mtime: mtime}} -> mtime
          {:error, _} -> nil
        end

      Process.sleep(1_000)

      mtime_after_wait =
        case File.stat(marker) do
          {:ok, %File.Stat{mtime: mtime}} -> mtime
          {:error, _} -> nil
        end

      assert mtime_at_kill == mtime_after_wait,
             "marker file kept being touched after the timeout — the grandchild is still alive"

      [run] = Runs.by_task(store, task.id)
      assert run.purpose == "other"
    end
  end
end
