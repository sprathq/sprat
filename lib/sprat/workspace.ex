defmodule Sprat.Workspace do
  @moduledoc """
  One git worktree per build task (docs/spec-v2.md §7 / spec-full.md §16).

  Non-negotiable rules, enforced here rather than merely documented:

    * Every worktree lives under `Sprat.Store.Paths.worktrees_dir/0` — the
      project's data dir, **never** inside the user's own checkout.
    * The user's uncommitted changes (`git status --porcelain` in the
      *original* checkout) are recorded as an event before anything else
      runs, and this module never resets, cleans, stashes, or checks out
      over that working tree. Every git command this module issues that
      touches the user's checkout is `git worktree add`/`remove` only —
      the operations `git` itself designed to be side-effect-free against
      the primary working tree.
    * `create/3` pins to an **explicit base revision** the caller supplies
      (a commit SHA, not a branch name a concurrent checkout could
      conflict with) and refuses outright — never guesses, never forces —
      if that revision can't be resolved cleanly.
    * `integrate/2` merges finished task branches into an integration
      branch **sequentially** and **surfaces conflicts**; it never
      attempts a resolution.
    * `cleanup/2` is explicit-only. Nothing here ever removes a worktree
      as a side effect of failure — a failed worktree is left exactly as
      it is for inspection.
    * Every operation is recorded as an event carrying the git command,
      its exit code, and its output (§7 "Every operation is an event").

  `opts` accepted by every function here: `:store` (default
  `Sprat.Store`), `:session_id` (required — events are keyed by session).
  """

  alias Sprat.Store.{Events, Paths}

  defstruct [:task_id, :mission_id, :root, :branch, :base_revision, :project_path]

  @type t :: %__MODULE__{
          task_id: String.t(),
          mission_id: String.t() | nil,
          root: String.t(),
          branch: String.t(),
          base_revision: String.t(),
          project_path: String.t()
        }

  @doc """
  Creates a worktree for `task_id` off `base_revision`, on a branch named
  for the task (`sprat/<task_id>`), under
  `Sprat.Store.Paths.worktrees_dir/0`.

  Order of operations, per §7 — nothing before step 1 touches git at all:

    1. `git status --porcelain` against `project_path` (the user's actual
       checkout) is captured and recorded as a
       `"workspace.dirty_tree_recorded"` event, unconditionally, before
       anything else. This is a read; it is never acted on to reset,
       stash, or clean anything.
    2. `base_revision` is resolved with `git rev-parse --verify`. If it
       doesn't resolve, `create/3` refuses — `{:error,
       {:unresolvable_base_revision, output}}` — rather than falling back
       to `HEAD` or any other guess.
    3. `git worktree add <path> -b <branch> <base_revision>` is run. Its
       command, exit code and output are recorded as
       `"workspace.created"` (success) or `"workspace.create_failed"`.

  Returns `{:ok, %__MODULE__{}}` or `{:error, reason}`.
  """
  def create(project_path, base_revision, task_id, opts \\ []) do
    store = Keyword.get(opts, :store, Sprat.Store)
    session_id = Keyword.fetch!(opts, :session_id)
    mission_id = Keyword.get(opts, :mission_id)

    with :ok <- record_dirty_tree(store, session_id, mission_id, task_id, project_path),
         :ok <- verify_base_revision(project_path, base_revision) do
      do_create(store, session_id, mission_id, task_id, project_path, base_revision)
    end
  end

  defp record_dirty_tree(store, session_id, mission_id, task_id, project_path) do
    {output, exit_code} = run_git(project_path, ["status", "--porcelain"])

    Events.append(store, session_id, "workspace.dirty_tree_recorded", %{
      mission_id: mission_id,
      task_id: task_id,
      payload: %{
        "project_path" => project_path,
        "dirty" => String.trim(output) != "",
        "porcelain_output" => output,
        "exit_code" => exit_code
      }
    })

    :ok
  end

  defp verify_base_revision(project_path, base_revision) do
    case run_git(project_path, ["rev-parse", "--verify", base_revision]) do
      {_output, 0} -> :ok
      {output, _} -> {:error, {:unresolvable_base_revision, String.trim(output)}}
    end
  end

  defp do_create(store, session_id, mission_id, task_id, project_path, base_revision) do
    root = Path.join(Paths.worktrees_dir(), task_id)
    branch = "sprat/#{task_id}"
    args = ["worktree", "add", root, "-b", branch, base_revision]

    File.mkdir_p!(Paths.worktrees_dir())
    {output, exit_code} = run_git(project_path, args)

    event_payload = %{
      "command" => "git",
      "args" => args,
      "cwd" => project_path,
      "exit_code" => exit_code,
      "output" => output,
      "worktree_root" => root,
      "branch" => branch,
      "base_revision" => base_revision
    }

    if exit_code == 0 do
      Events.append(store, session_id, "workspace.created", %{
        mission_id: mission_id,
        task_id: task_id,
        payload: event_payload
      })

      {:ok,
       %__MODULE__{
         task_id: task_id,
         mission_id: mission_id,
         root: root,
         branch: branch,
         base_revision: base_revision,
         project_path: project_path
       }}
    else
      Events.append(store, session_id, "workspace.create_failed", %{
        mission_id: mission_id,
        task_id: task_id,
        payload: event_payload
      })

      {:error, {:worktree_add_failed, output}}
    end
  end

  @doc """
  Merges each of `workspaces` (a list of `%__MODULE__{}`, already ordered
  by the caller — "sequentially" per §7 means one at a time, in a
  meaningful order, not concurrently) into `integration_workspace` (itself
  a `%__MODULE__{}`, typically created with `create/3` off the same base
  revision the tasks branched from).

  Stops at the first conflict: aborts that merge
  (`git merge --abort`, the one git-provided way back to a clean tree —
  never a hand-rolled resolution) and returns
  `{:error, {:conflict, workspace, output}, merged}`, where `merged` is
  the list of workspaces that merged cleanly before the conflict. Every
  attempt — clean or conflicting — is recorded as
  `"workspace.integrated"` or `"workspace.conflict"`.

  Returns `{:ok, merged}` when every workspace merges cleanly.
  """
  def integrate(workspaces, integration_workspace, opts \\ [])

  def integrate([], _integration_workspace, _opts), do: {:ok, []}

  def integrate(workspaces, integration_workspace, opts) do
    store = Keyword.get(opts, :store, Sprat.Store)
    session_id = Keyword.fetch!(opts, :session_id)

    do_integrate(workspaces, integration_workspace, store, session_id, [])
  end

  defp do_integrate([], _integration_workspace, _store, _session_id, merged) do
    {:ok, Enum.reverse(merged)}
  end

  defp do_integrate([ws | rest], integration_workspace, store, session_id, merged) do
    args = ["merge", "--no-ff", "--no-edit", ws.branch]
    {output, exit_code} = run_git(integration_workspace.root, args)

    payload = %{
      "command" => "git",
      "args" => args,
      "cwd" => integration_workspace.root,
      "exit_code" => exit_code,
      "output" => output,
      "merged_branch" => ws.branch
    }

    if exit_code == 0 do
      Events.append(store, session_id, "workspace.integrated", %{
        mission_id: integration_workspace.mission_id,
        task_id: ws.task_id,
        payload: payload
      })

      do_integrate(rest, integration_workspace, store, session_id, [ws | merged])
    else
      run_git(integration_workspace.root, ["merge", "--abort"])

      Events.append(store, session_id, "workspace.conflict", %{
        mission_id: integration_workspace.mission_id,
        task_id: ws.task_id,
        payload: payload
      })

      {:error, {:conflict, ws, output}, Enum.reverse(merged)}
    end
  end

  @doc """
  Removes a worktree. **Explicit only** — never called automatically on
  failure (§7: "Failed worktrees are kept for inspection, cleaned on an
  explicit policy"). `opts` may include `:force` (`true` to remove a
  worktree with uncommitted changes in it — the task's own changes, not
  the user's; still never used on the user's primary checkout, which this
  module never targets).
  """
  def cleanup(%__MODULE__{} = workspace, opts \\ []) do
    store = Keyword.get(opts, :store, Sprat.Store)
    session_id = Keyword.fetch!(opts, :session_id)
    force? = Keyword.get(opts, :force, false)

    args = ["worktree", "remove"] ++ if(force?, do: ["--force"], else: []) ++ [workspace.root]
    {output, exit_code} = run_git(workspace.project_path, args)

    Events.append(store, session_id, "workspace.cleaned", %{
      mission_id: workspace.mission_id,
      task_id: workspace.task_id,
      payload: %{
        "command" => "git",
        "args" => args,
        "cwd" => workspace.project_path,
        "exit_code" => exit_code,
        "output" => output
      }
    })

    if exit_code == 0, do: :ok, else: {:error, output}
  end

  @doc """
  `git diff <base_revision>` against the current working tree — the
  Inspector's Diff tab (docs/spec-v2.md §11) reads this instead of
  shelling out itself ("the renderer never runs anything"). Read-only:
  unlike `create/3`, `integrate/3` and `cleanup/2` it never touches the
  worktree and doesn't append an event of its own either — a diff *view*
  isn't a build operation the way those are, and the caller already knows
  which workspace it's diffing without a log lookup.

  Returns `{:ok, diff_text}` (`""` means no changes against the base) or
  `{:error, output}`.
  """
  def diff(%__MODULE__{} = workspace, opts \\ []) do
    args = ["diff"] ++ Keyword.get(opts, :git_args, []) ++ [workspace.base_revision]

    case run_git(workspace.root, args) do
      {output, 0} -> {:ok, output}
      {output, _exit_code} -> {:error, output}
    end
  end

  @doc """
  Combines `labeled_diffs` (a list of `{label, diff_text}` pairs, one per
  task workspace) into the single "combined" bundle the Diff tab shows
  alongside each per-task diff. Pure text work — no git, no IO — so it
  stays with `diff/2` rather than duplicated in the (pure) terminal layer.
  Blank/`nil` diffs (nothing changed in that task) are dropped rather than
  padding the bundle with empty sections.
  """
  def combine_diffs(labeled_diffs) do
    labeled_diffs
    |> Enum.reject(fn {_label, text} -> text in [nil, ""] end)
    |> Enum.map_join("\n\n", fn {label, text} -> "# #{label}\n#{text}" end)
  end

  # Explicit argument array only — never a shell string built from any
  # caller-supplied value (same rule §7 states for the shell tool; this
  # module drives git the same way).
  defp run_git(cwd, args) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
