defmodule Sprat.Agent.Tools.Files do
  @moduledoc """
  `read_file`, `glob`, `grep` (docs/spec-v1.md §9): local read, "only
  within the attached repository root; symlinks resolved and checked;
  `.env*`, keys and files matched by `.gitignore`-style deny patterns
  blocked."

  Every path — including every symlink target along the way — is resolved
  to a real, absolute path and checked to still be inside `root`'s own
  real path before anything is read. `context` for every function here is
  `%{root: root_path}`.

  `ponytail:` deny-pattern matching is basename/simple-glob (`*`, `**`),
  not full `.gitignore` semantics (no negation, no directory-scoped
  rules) — the spec asks for "`.gitignore`-style", not a `.gitignore`
  parser, and the default list below covers the actual named cases
  (`.env*`, keys). Extend `@default_deny_patterns` if a real deny rule
  needs more.
  """

  @default_deny_patterns [
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "id_rsa",
    "id_rsa.*",
    "id_ed25519",
    "id_ed25519.*",
    "*.p12",
    "*.pfx",
    "credentials.json",
    "*.gitignore",
    ".git/**"
  ]

  @max_grep_matches 200
  @max_file_bytes 1_000_000
  @max_attachable_files 5_000

  @doc """
  Every regular file under `root`, deny-pattern/symlink-checked, capped
  at #{@max_attachable_files} entries — the composer's `@`-completion list
  (`Sprat.Terminal.Composer`'s `files:` option), snapshotted once at UI
  start rather than re-globbed per keystroke. `nil` root (no project
  attached) returns `[]`.
  """
  def attachable_files(nil), do: []

  def attachable_files(root) do
    case glob(root, "**/*") do
      {:ok, paths} -> Enum.take(paths, @max_attachable_files)
      {:error, _} -> []
    end
  end

  @doc """
  `attachable_files/1` without blocking the caller: returns immediately and
  sends `{:attachable_files, paths}` to `pid` when the walk finishes.

  Scanning a real project is not cheap — this repo takes 4.6s, because
  `Path.wildcard/2` walks `_build` and `deps` before anything filters them —
  and doing it in the renderer's `init/1` delayed the first paint by that
  long. Four terminal checks failed against a shell prompt because the app
  had not drawn yet.
  """
  def attachable_files_async(nil, _pid), do: :ok

  def attachable_files_async(root, pid) do
    Task.start(fn -> send(pid, {:attachable_files, attachable_files(root)}) end)
    :ok
  end

  @doc "Reads a file's contents, or `{:error, reason}` if it escapes `root`, is denied, or can't be read."
  def read_file(root, path) do
    with {:ok, real} <- safe_path(root, path) do
      case File.read(real) do
        {:ok, content} when byte_size(content) > @max_file_bytes ->
          {:ok, binary_part(content, 0, @max_file_bytes) <> "\n...[truncated]"}

        {:ok, content} ->
          {:ok, content}

        {:error, reason} ->
          {:error, "could not read #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc "Filenames under `root` matching `pattern` (a `Path.wildcard/1` glob, relative to `root`), deny-filtered and symlink-checked."
  def glob(root, pattern) do
    with {:ok, real_root} <- realpath(root) do
      real_root
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: false)
      |> Enum.reject(&build_artifact?/1)
      |> Enum.filter(&File.regular?/1)
      |> Enum.filter(fn abs ->
        match?({:ok, _}, safe_path(root, Path.relative_to(abs, real_root)))
      end)
      |> Enum.map(&Path.relative_to(&1, real_root))
      |> then(&{:ok, &1})
    end
  end

  @doc "Lines matching `regex` (a string, compiled with `Regex.compile/1`) across every allowed text file under `root`. Returns `{:ok, [%{path:, line:, text:}]}`, capped at #{@max_grep_matches} matches."
  def grep(root, pattern) do
    with {:ok, regex} <- Regex.compile(pattern),
         {:ok, paths} <- glob(root, "**/*") do
      matches =
        paths
        |> Enum.reject(&binary_file?(root, &1))
        |> Enum.flat_map(&grep_file(root, &1, regex))
        |> Enum.take(@max_grep_matches)

      {:ok, matches}
    end
  end

  defp grep_file(root, rel_path, regex) do
    case read_file(root, rel_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, n} -> %{path: rel_path, line: n, text: line} end)

      {:error, _} ->
        []
    end
  end

  defp binary_file?(root, rel_path) do
    case safe_path(root, rel_path) do
      {:ok, real} ->
        case File.open(real, [:read], fn f -> IO.binread(f, 1024) end) do
          {:ok, chunk} when is_binary(chunk) -> String.contains?(chunk, <<0>>)
          _ -> true
        end

      {:error, _} ->
        true
    end
  end

  @doc """
  Like `safe_path/2`, but `candidate_path` is already absolute (or
  root-joined) rather than root-relative, and a path that resolves
  *outside* `root` is reported rather than rejected — `Sprat.Attachments`'
  `@`-attach (spec: "the path must be inside the project root or
  explicitly given ... a path outside the project root is confirmed once,
  not silently read") needs the same symlink-resolution and deny-pattern
  checks `read_file` uses, just without `read_file`'s root confinement.
  Returns `{:ok, real, :in_root | :outside_root}` or `{:error, reason}`
  (`reason` is one of `safe_path/2`'s: `:invalid_path`, `:denied_pattern`,
  `:symlink_loop`, or a `File.posix` error atom).
  """
  def safe_path_for(root, candidate_path) do
    with :ok <- reject_nul(candidate_path),
         {:ok, real_root} <- realpath(root),
         {:ok, real} <- realpath(candidate_path),
         :ok <- reject_denied(root, real) do
      if within_root?(real, real_root),
        do: {:ok, real, :in_root},
        else: {:ok, real, :outside_root}
    end
  end

  # -- sandboxing -------------------------------------------------------------

  @doc false
  def safe_path(root, path) do
    with :ok <- reject_nul(path),
         {:ok, real_root} <- realpath(root),
         {:ok, real} <- realpath(Path.join(real_root, path)),
         :ok <- reject_outside_root(real, real_root),
         :ok <- reject_denied(root, real) do
      {:ok, real}
    end
  end

  defp reject_nul(path) do
    if String.contains?(path, "\0"), do: {:error, :invalid_path}, else: :ok
  end

  defp reject_outside_root(real, real_root) do
    if within_root?(real, real_root), do: :ok, else: {:error, :path_escapes_root}
  end

  defp reject_denied(root, real) do
    if denied?(root, real), do: {:error, :denied_pattern}, else: :ok
  end

  defp within_root?(real, real_root),
    do: real == real_root or String.starts_with?(real, real_root <> "/")

  defp denied?(_root, real) do
    basename = Path.basename(real)
    rel = real

    Enum.any?(@default_deny_patterns, fn pattern ->
      glob_match?(pattern, basename) or glob_match?(pattern, rel)
    end)
  end

  # Nothing under these is evidence, and walking them is most of the cost of
  # a scan: this repo's `_build` and `deps` alone are tens of thousands of
  # files.
  @skip_dirs ~w(_build deps node_modules .git .elixir_ls cover .worktrees)

  defp build_artifact?(path) do
    path |> Path.split() |> Enum.any?(&(&1 in @skip_dirs))
  end

  defp glob_match?(pattern, subject) do
    regex_src =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(~r/^#{regex_src}$/, subject) or
      (String.ends_with?(pattern, "/**") and
         String.starts_with?(subject, String.trim_trailing(pattern, "/**") <> "/"))
  end

  # Resolves every path segment that exists as a symlink to its target, so
  # a symlink escape (a link inside `root` pointing outside it) is caught
  # before the file underneath it is ever opened. A segment that doesn't
  # exist yet is kept literal (falls through to `do_realpath`'s `:enoent`
  # clause), so callers get a normal "not found" instead of a sandbox
  # error for a plain typo.
  # `File.lstat/1` on a full path only tells us about the final segment —
  # an intermediate segment that's a symlink resolves transparently at the
  # OS level, which is exactly the escape this sandbox exists to catch
  # (`root/link_to_outside/file`). So this walks the path one segment at a
  # time from `/`, resolving (and recursively re-walking) every symlink it
  # meets, rather than lstat-ing the joined path once.
  defp realpath(path, depth \\ 0)
  defp realpath(_path, depth) when depth > 40, do: {:error, :symlink_loop}

  defp realpath(path, depth) do
    path |> Path.expand() |> Path.split() |> walk("", depth)
  end

  defp walk([], acc, _depth), do: {:ok, acc}

  defp walk([seg | rest], acc, depth) do
    candidate = join_segment(acc, seg)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(candidate) do
          {:ok, target} ->
            resolved_target =
              if Path.type(target) == :absolute, do: target, else: Path.join(acc, target)

            case realpath(resolved_target, depth + 1) do
              {:ok, real_target} -> walk(rest, real_target, depth)
              error -> error
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, _stat} ->
        walk(rest, candidate, depth)

      {:error, :enoent} ->
        # Doesn't exist (yet): keep every remaining segment literal (a
        # symlink can't live under a path that doesn't exist), so callers
        # get a normal "not found" instead of a sandbox error for a typo.
        {:ok, Enum.reduce(rest, candidate, &join_segment(&2, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_segment("", "/"), do: "/"
  defp join_segment(acc, seg), do: Path.join(acc, seg)
end
