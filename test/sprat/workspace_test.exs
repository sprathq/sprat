defmodule Sprat.WorkspaceTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Events
  alias Sprat.Workspace

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])

    File.write!(Path.join(repo, "file.txt"), "line one\nline two\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "initial"])
    {base_revision, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
    base_revision = String.trim(base_revision)

    {:ok, repo: repo, base_revision: base_revision}
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end

  describe "create/4" do
    test "creates a worktree off the base revision, outside the user's checkout", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task} = fixture_chain(store)

      assert {:ok, workspace} =
               Workspace.create(repo, base_revision, task.id,
                 store: store,
                 session_id: session.id,
                 mission_id: mission.id
               )

      refute String.starts_with?(workspace.root, repo)
      assert File.exists?(Path.join(workspace.root, "file.txt"))
      assert workspace.branch == "sprat/#{task.id}"

      events = Events.by_task(store, task.id)
      assert Enum.any?(events, &(&1.type == "workspace.created"))
    end

    test "records a dirty user tree as an event and never touches it", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task} = fixture_chain(store)

      File.write!(Path.join(repo, "file.txt"), "UNCOMMITTED CHANGE\n")

      assert {:ok, _workspace} =
               Workspace.create(repo, base_revision, task.id,
                 store: store,
                 session_id: session.id,
                 mission_id: mission.id
               )

      # never reset/cleaned/stashed
      assert File.read!(Path.join(repo, "file.txt")) == "UNCOMMITTED CHANGE\n"

      events = Events.by_task(store, task.id)
      dirty_event = Enum.find(events, &(&1.type == "workspace.dirty_tree_recorded"))
      assert dirty_event
      assert dirty_event.payload =~ "file.txt"
    end

    test "refuses rather than guessing when the base revision cannot be resolved", %{
      store: store,
      repo: repo
    } do
      {session, _mission, task} = fixture_chain(store)

      assert {:error, {:unresolvable_base_revision, _}} =
               Workspace.create(repo, "not-a-real-revision", task.id,
                 store: store,
                 session_id: session.id
               )

      refute File.exists?(Path.join(Sprat.Store.Paths.worktrees_dir(), task.id))
    end
  end

  describe "integrate/3" do
    test "merges finished branches sequentially into the integration branch", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task_a} = fixture_chain(store)
      {_session2, _mission2, task_b} = fixture_chain(store, %{})
      {_session3, _mission3, int_task} = fixture_chain(store)

      {:ok, ws_a} =
        Workspace.create(repo, base_revision, task_a.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      {:ok, ws_b} =
        Workspace.create(repo, base_revision, task_b.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      {:ok, integration} =
        Workspace.create(repo, base_revision, int_task.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      File.write!(Path.join(ws_a.root, "a.txt"), "from a\n")
      git!(ws_a.root, ["add", "."])
      git!(ws_a.root, ["commit", "-q", "-m", "add a"])

      File.write!(Path.join(ws_b.root, "b.txt"), "from b\n")
      git!(ws_b.root, ["add", "."])
      git!(ws_b.root, ["commit", "-q", "-m", "add b"])

      assert {:ok, merged} =
               Workspace.integrate([ws_a, ws_b], integration,
                 store: store,
                 session_id: session.id
               )

      assert length(merged) == 2
      assert File.exists?(Path.join(integration.root, "a.txt"))
      assert File.exists?(Path.join(integration.root, "b.txt"))

      events = Events.by_mission(store, integration.mission_id)
      assert Enum.count(events, &(&1.type == "workspace.integrated")) == 2
    end

    test "surfaces a conflict instead of resolving it", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task_a} = fixture_chain(store)
      {_session2, _mission2, task_b} = fixture_chain(store, %{})
      {_session3, _mission3, int_task} = fixture_chain(store)

      {:ok, ws_a} =
        Workspace.create(repo, base_revision, task_a.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      {:ok, ws_b} =
        Workspace.create(repo, base_revision, task_b.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      {:ok, integration} =
        Workspace.create(repo, base_revision, int_task.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      File.write!(Path.join(ws_a.root, "file.txt"), "A's conflicting change\n")
      git!(ws_a.root, ["add", "."])
      git!(ws_a.root, ["commit", "-q", "-m", "a changes file.txt"])

      File.write!(Path.join(ws_b.root, "file.txt"), "B's conflicting change\n")
      git!(ws_b.root, ["add", "."])
      git!(ws_b.root, ["commit", "-q", "-m", "b changes file.txt"])

      assert {:error, {:conflict, conflicting_ws, output}, merged} =
               Workspace.integrate([ws_a, ws_b], integration,
                 store: store,
                 session_id: session.id
               )

      assert conflicting_ws.task_id == task_b.id
      assert output =~ "CONFLICT" or output =~ "conflict"
      assert length(merged) == 1

      # the integration worktree is left clean (merge --abort ran), not
      # half-merged
      {status, 0} = System.cmd("git", ["status", "--porcelain"], cd: integration.root)
      assert String.trim(status) == ""

      events = Events.by_mission(store, integration.mission_id)
      assert Enum.any?(events, &(&1.type == "workspace.conflict"))
    end
  end

  describe "diff/2" do
    test "returns the diff against base_revision for changes made in the worktree", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task} = fixture_chain(store)

      {:ok, workspace} =
        Workspace.create(repo, base_revision, task.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      File.write!(Path.join(workspace.root, "file.txt"), "line one\nline TWO changed\n")
      git!(workspace.root, ["add", "."])
      git!(workspace.root, ["commit", "-q", "-m", "change file"])

      assert {:ok, diff} = Workspace.diff(workspace)
      assert diff =~ "-line two"
      assert diff =~ "+line TWO changed"
    end

    test "returns an empty diff when nothing changed", %{repo: repo, base_revision: base_revision} do
      workspace = %Workspace{
        task_id: "t1",
        root: repo,
        branch: "main",
        base_revision: base_revision,
        project_path: repo
      }

      assert {:ok, ""} = Workspace.diff(workspace)
    end
  end

  describe "combine_diffs/1" do
    test "concatenates labeled diffs with headers, dropping blank/nil ones" do
      combined =
        Workspace.combine_diffs([
          {"task_1", "diff --git a/x b/x\n+added\n"},
          {"task_2", ""},
          {"task_3", nil},
          {"task_4", "diff --git a/y b/y\n-removed\n"}
        ])

      assert combined =~ "# task_1"
      assert combined =~ "+added"
      assert combined =~ "# task_4"
      assert combined =~ "-removed"
      refute combined =~ "# task_2"
      refute combined =~ "# task_3"
    end

    test "an empty list combines to an empty string" do
      assert Workspace.combine_diffs([]) == ""
    end
  end

  describe "cleanup/2" do
    test "removes a worktree only when called explicitly", %{
      store: store,
      repo: repo,
      base_revision: base_revision
    } do
      {session, mission, task} = fixture_chain(store)

      {:ok, workspace} =
        Workspace.create(repo, base_revision, task.id,
          store: store,
          session_id: session.id,
          mission_id: mission.id
        )

      assert File.exists?(workspace.root)
      assert :ok = Workspace.cleanup(workspace, store: store, session_id: session.id)
      refute File.exists?(workspace.root)

      events = Events.by_task(store, task.id)
      assert Enum.any?(events, &(&1.type == "workspace.cleaned"))
    end
  end
end
