defmodule Sprat.Observer.Projects do
  @moduledoc """
  Resolves a session's `cwd` to its project (spec §3, §4.3): a git
  repository, with worktrees resolving to the main repository. Plus the git
  facts the detector needs: commits since a time, dirty state.

  Every function takes `opts[:cmd]`, a `(cmd, args) -> {output, exit_status}`
  runner (defaults to `System.cmd/3`), so tests need no real repository.
  """

  @type resolved :: %{root: String.t(), branch: String.t() | nil, worktree?: boolean()}
  @type cache :: %{optional(String.t()) => resolved()}

  @doc "Resolves `cwd` to `%{root, branch, worktree?}`. A non-git dir is its own root."
  @spec resolve(String.t(), keyword()) :: resolved()
  def resolve(cwd, opts \\ []) do
    run = runner(opts)

    lines =
      case run.("git", [
             "-C",
             cwd,
             "rev-parse",
             "--show-toplevel",
             "--git-common-dir",
             "--abbrev-ref",
             "HEAD"
           ]) do
        {out, 0} ->
          String.split(out, "\n", trim: true)

        _ ->
          # e.g. a repo with no commits yet: HEAD does not resolve.
          case run.("git", ["-C", cwd, "rev-parse", "--show-toplevel", "--git-common-dir"]) do
            {out, 0} -> String.split(out, "\n", trim: true)
            _ -> []
          end
      end

    case lines do
      [top, common | rest] ->
        common = Path.expand(common, cwd)
        root = if Path.basename(common) == ".git", do: Path.dirname(common), else: top

        branch =
          case rest do
            [b | _] when b != "HEAD" -> b
            _ -> nil
          end

        %{root: root, branch: branch, worktree?: Path.expand(top) != Path.expand(root)}

      _ ->
        # A folder above the repo (e.g. `sprat.dev/` holding `sprat/` and
        # `sprat_web/`, where only one is the product): when exactly one child
        # is a git repo with docs, that repo is the project.
        case child_repo(cwd, opts) do
          nil -> %{root: cwd, branch: nil, worktree?: false}
          child -> resolve(child, opts)
        end
    end
  end

  defp child_repo(cwd, opts) do
    if Keyword.get(opts, :descend, true) do
      repos =
        cwd
        |> Path.join("*/.git")
        |> Path.wildcard(match_dot: true)
        |> Enum.map(&Path.dirname/1)
        |> Enum.filter(&(Sprat.Roadmap.Sources.discover(&1, []) != []))

      case repos do
        [one] -> one
        _ -> nil
      end
    end
  end

  @doc """
  Memoised `resolve/2`: returns the result and the updated cache. Branches
  change, so callers drop the cache when they want fresh branch names.
  """
  @spec resolve_cached(cache(), String.t(), keyword()) :: {resolved(), cache()}
  def resolve_cached(cache, cwd, opts \\ []) do
    case Map.fetch(cache, cwd) do
      {:ok, r} ->
        {r, cache}

      :error ->
        r = resolve(cwd, opts)
        {r, Map.put(cache, cwd, r)}
    end
  end

  @sep "\x1f"

  @doc """
  Commits on any branch since `since`, newest first:
  `[%{sha, at, subject, branches}]`. `branches` are the ref that reached the
  commit (`--source`) plus any local branch pointing at it.
  """
  @spec commits_since(String.t(), DateTime.t(), keyword()) :: [map()]
  def commits_since(root, %DateTime{} = since, opts \\ []) do
    run = runner(opts)

    args = [
      "-C",
      root,
      "log",
      "--all",
      "--source",
      "--since=#{DateTime.to_iso8601(since)}",
      "--format=%H#{@sep}%cI#{@sep}%S#{@sep}%D#{@sep}%s"
    ]

    case run.("git", args) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.flat_map(&commit_line/1)
      _ -> []
    end
  end

  defp commit_line(line) do
    case String.split(line, @sep, parts: 5) do
      [sha, at, source, decor, subject] ->
        at =
          case DateTime.from_iso8601(at) do
            {:ok, dt, _} -> dt
            _ -> nil
          end

        [%{sha: sha, at: at, subject: subject, branches: branches(source, decor)}]

      _ ->
        []
    end
  end

  defp branches(source, decor) do
    decorated =
      decor
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.replace_prefix(&1, "HEAD -> ", ""))
      |> Enum.reject(&(&1 == "HEAD" or String.starts_with?(&1, "tag: ")))

    [source | decorated]
    |> Enum.map(&short_ref/1)
    |> Enum.reject(&(&1 in ["", "HEAD"]))
    |> Enum.uniq()
  end

  defp short_ref("refs/heads/" <> b), do: b
  defp short_ref("refs/remotes/" <> b), do: b
  defp short_ref(b), do: b

  @doc "True when the working tree at `path` has uncommitted changes. Non-git: false."
  @spec dirty?(String.t(), keyword()) :: boolean()
  def dirty?(path, opts \\ []) do
    case runner(opts).("git", ["-C", path, "status", "--porcelain"]) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  defp runner(opts), do: Keyword.get(opts, :cmd, &default_cmd/2)

  defp default_cmd(cmd, args) do
    Sprat.Cmd.run(cmd, args, timeout: 15_000)
  rescue
    _ -> {"", 127}
  end
end
