defmodule Sprat.Agent.Tools.WriteFileTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.WriteFile
  alias Sprat.Store.Events

  setup %{tmp_dir: tmp_dir} do
    worktree = Path.join(tmp_dir, "worktree")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(worktree)
    File.mkdir_p!(outside)
    {:ok, worktree: worktree, outside: outside}
  end

  defp context(worktree, extra \\ %{}) do
    Map.merge(%{worktree_root: worktree, granted: %{workspace_write: true}}, extra)
  end

  describe "call/2" do
    test "writes a file inside the worktree", %{worktree: worktree} do
      assert {:ok, %{"bytes_written" => 5}} =
               WriteFile.call(%{"path" => "hello.txt", "content" => "world"}, context(worktree))

      assert File.read!(Path.join(worktree, "hello.txt")) == "world"
    end

    test "creates parent directories as needed", %{worktree: worktree} do
      assert {:ok, _} =
               WriteFile.call(
                 %{"path" => "a/b/c.txt", "content" => "x"},
                 context(worktree)
               )

      assert File.read!(Path.join(worktree, "a/b/c.txt")) == "x"
    end

    test "refuses without the workspace_write grant, as approval, not an error string", %{
      worktree: worktree
    } do
      ctx = %{worktree_root: worktree, granted: %{workspace_write: false}}

      assert {:needs_approval, %{action: "workspace_write"}} =
               WriteFile.call(%{"path" => "hello.txt", "content" => "x"}, ctx)

      refute File.exists?(Path.join(worktree, "hello.txt"))
    end

    test "refuses a path escaping the worktree with .. as a hard error, never a prompt", %{
      worktree: worktree,
      outside: outside
    } do
      File.write!(Path.join(outside, "victim.txt"), "original")

      rel = Path.join(["..", Path.basename(outside), "victim.txt"])

      assert {:error, %{"kind" => "path_denied"}} =
               WriteFile.call(%{"path" => rel, "content" => "pwned"}, context(worktree))

      assert File.read!(Path.join(outside, "victim.txt")) == "original"
    end

    test "treats a literal absolute path argument as root-relative, never as the real outside path",
         %{worktree: worktree, outside: outside} do
      abs = Path.join(outside, "abs.txt")
      assert {:ok, _} = WriteFile.call(%{"path" => abs, "content" => "x"}, context(worktree))

      # never written at the real outside path
      refute File.exists?(abs)
      # written under the worktree instead (Path.join semantics strip the
      # leading "/", the same way Files.safe_path/2 always has)
      assert File.exists?(Path.join(worktree, String.trim_leading(abs, "/")))
    end

    test "refuses a symlink inside the worktree pointing outside it", %{
      worktree: worktree,
      outside: outside
    } do
      File.write!(Path.join(outside, "victim.txt"), "original")
      link = Path.join(worktree, "escape")
      File.ln_s!(outside, link)

      assert {:error, %{"kind" => "path_denied"}} =
               WriteFile.call(
                 %{"path" => "escape/victim.txt", "content" => "pwned"},
                 context(worktree)
               )

      assert File.read!(Path.join(outside, "victim.txt")) == "original"
    end

    test "records a diff summary event", %{worktree: worktree, store: store} do
      {session, mission, task} = fixture_chain(store)

      ctx =
        context(worktree, %{
          store: store,
          session_id: session.id,
          mission_id: mission.id,
          task_id: task.id
        })

      {:ok, _} = WriteFile.call(%{"path" => "f.txt", "content" => "one\ntwo\n"}, ctx)

      events = Events.by_task(store, task.id)
      write_event = Enum.find(events, &(&1.type == "tool.write_file"))
      assert write_event
      assert write_event.payload =~ "\"lines_after\":3"
    end
  end
end
