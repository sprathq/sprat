defmodule Sprat.Observer.ProjectsTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Projects

  defp fake(responses) do
    fn "git", args -> Map.get(responses, args, {"fatal: not a git repository", 128}) end
  end

  test "main checkout" do
    cmd =
      fake(%{
        [
          "-C",
          "/r/app",
          "rev-parse",
          "--show-toplevel",
          "--git-common-dir",
          "--abbrev-ref",
          "HEAD"
        ] => {"/r/app\n.git\nmain\n", 0}
      })

    assert Projects.resolve("/r/app", cmd: cmd) == %{
             root: "/r/app",
             branch: "main",
             worktree?: false
           }
  end

  test "subdirectory with an absolute common dir" do
    cmd =
      fake(%{
        [
          "-C",
          "/r/app/lib",
          "rev-parse",
          "--show-toplevel",
          "--git-common-dir",
          "--abbrev-ref",
          "HEAD"
        ] => {"/r/app\n/r/app/.git\nmain\n", 0}
      })

    assert %{root: "/r/app", worktree?: false} = Projects.resolve("/r/app/lib", cmd: cmd)
  end

  test "worktree resolves to the main repo" do
    cwd = "/r/app/.worktrees/feat"

    cmd =
      fake(%{
        ["-C", cwd, "rev-parse", "--show-toplevel", "--git-common-dir", "--abbrev-ref", "HEAD"] =>
          {"#{cwd}\n/r/app/.git\nfeat/x\n", 0}
      })

    assert Projects.resolve(cwd, cmd: cmd) == %{root: "/r/app", branch: "feat/x", worktree?: true}
  end

  test "non-git dir is its own root" do
    assert Projects.resolve("/tmp/x", cmd: fake(%{})) == %{
             root: "/tmp/x",
             branch: nil,
             worktree?: false
           }
  end

  test "repo with no commits yet" do
    cmd =
      fake(%{
        ["-C", "/r/new", "rev-parse", "--show-toplevel", "--git-common-dir"] =>
          {"/r/new\n.git\n", 0}
      })

    assert Projects.resolve("/r/new", cmd: cmd) == %{
             root: "/r/new",
             branch: nil,
             worktree?: false
           }
  end

  test "detached HEAD has no branch" do
    cmd =
      fake(%{
        [
          "-C",
          "/r/app",
          "rev-parse",
          "--show-toplevel",
          "--git-common-dir",
          "--abbrev-ref",
          "HEAD"
        ] => {"/r/app\n.git\nHEAD\n", 0}
      })

    assert %{branch: nil} = Projects.resolve("/r/app", cmd: cmd)
  end

  test "resolve_cached memoises" do
    parent = self()

    cmd = fn "git", args ->
      send(parent, :called)
      {"/r/app\n.git\nmain\n", if(length(args) == 7, do: 0, else: 1)}
    end

    {r, cache} = Projects.resolve_cached(%{}, "/r/app", cmd: cmd)
    {^r, ^cache} = Projects.resolve_cached(cache, "/r/app", cmd: cmd)
    assert_received :called
    refute_received :called
  end

  test "commits_since parses log lines" do
    sep = "\x1f"

    out =
      Enum.join(
        [
          Enum.join(
            [
              "aaa",
              "2026-11-23T10:00:00+00:00",
              "refs/heads/feat",
              "HEAD -> feat, origin/feat",
              "Add thing"
            ],
            sep
          ),
          Enum.join(
            ["bbb", "2026-11-22T09:00:00+01:00", "refs/heads/main", "", "Fix | pipes"],
            sep
          ),
          "garbage"
        ],
        "\n"
      )

    cmd = fn "git",
             ["-C", "/r/app", "log", "--all", "--source", "--since=2026-11-20T00:00:00Z", _] ->
      {out, 0}
    end

    assert [
             %{
               sha: "aaa",
               at: ~U[2026-11-23 10:00:00Z],
               subject: "Add thing",
               branches: ["feat", "origin/feat"]
             },
             %{
               sha: "bbb",
               at: ~U[2026-11-22 08:00:00Z],
               subject: "Fix | pipes",
               branches: ["main"]
             }
           ] = Projects.commits_since("/r/app", ~U[2026-11-20 00:00:00Z], cmd: cmd)

    assert Projects.commits_since("/x", ~U[2026-11-20 00:00:00Z], cmd: fake(%{})) == []
  end

  test "dirty?" do
    assert Projects.dirty?("/r", cmd: fn "git", _ -> {" M lib/a.ex\n", 0} end)
    refute Projects.dirty?("/r", cmd: fn "git", _ -> {"", 0} end)
    refute Projects.dirty?("/r", cmd: fn "git", _ -> {"fatal", 128} end)
  end

  @tag :tmp_dir
  test "against a real git repo and worktree", %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    git = fn args -> {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) end
    git.(["init", "-q", "-b", "main"])
    git.(["config", "user.email", "t@example.com"])
    git.(["config", "user.name", "T"])
    File.write!(Path.join(repo, "a.txt"), "a")
    git.(["add", "."])
    git.(["commit", "-q", "-m", "first"])
    wt = Path.join(dir, "wt")
    git.(["worktree", "add", "-q", "-b", "feat", wt])

    real_repo = repo |> resolve_real()

    assert %{root: ^real_repo, branch: "main", worktree?: false} =
             Projects.resolve(repo) |> real_root()

    assert %{root: ^real_repo, branch: "feat", worktree?: true} =
             Projects.resolve(wt) |> real_root()

    refute Projects.dirty?(repo)
    File.write!(Path.join(repo, "b.txt"), "b")
    assert Projects.dirty?(repo)

    assert [%{subject: "first", branches: branches}] =
             Projects.commits_since(repo, DateTime.add(DateTime.utc_now(), -3600))

    assert "main" in branches
  end

  # macOS tmp dirs live behind the /var -> /private/var symlink.
  defp resolve_real(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp real_root(%{root: root} = r), do: %{r | root: resolve_real(root)}
end
