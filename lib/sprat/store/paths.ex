defmodule Sprat.Store.Paths do
  @moduledoc """
  Platform data directory per docs/spec-v1.md §13 Storage layout:
  `~/Library/Application Support/sprat` on macOS, `$XDG_DATA_HOME/sprat`
  (default `~/.local/share/sprat`) on Linux.

  Resolution order (highest priority first) — see `resolve/1`:

    1. `SPRAT_DATA_DIR` (OS env var, checked at runtime) — an unconditional
       override, e.g. for a specific verification run.
    2. The `:sprat, :data_dir` application env (compile-time config
       override) — how `config/test.exs` keeps `mix test` off the real
       user data dir.
    3. An environment-derived default: `MIX_ENV=dev` (and any dev-flavored
       release build) gets its own `dev/` subdirectory, permanently
       separate from the real production path — a `mix release` (or `mix
       release sprat_rt`) built without `MIX_ENV=prod` must never be able
       to write to the same place as the shipped production build.
       `MIX_ENV=prod` gets the real platform directory, unchanged.

  Adapted from the packaging spike (spikes/packaging/lib/sprat_spike/paths.ex).
  """

  @app_name "sprat"

  # Mix.env/0 is a build-time-only API (the :mix app isn't part of a
  # release) — capture it as a compile-time constant instead of calling it
  # at runtime, so this stays release-safe. Same rationale as
  # `Sprat.Application.@env` (see lib/sprat/application.ex): a release
  # built with `MIX_ENV=dev mix release sprat_rt` bakes in `:dev` here at
  # compile time, and `resolve/1` uses that to pick the dev-only
  # subdirectory — no `Mix` module needed at runtime.
  @env Mix.env()

  @doc "Returns the app data directory, creating it (mode 0700) if needed."
  def data_dir do
    {dir, _reason} = data_dir_with_reason()
    dir
  end

  @doc """
  Returns `{dir, reason}` — the resolved data directory (created, mode
  0700, if needed) and a short, human-readable explanation of why, for
  `sprat doctor` to print. Resolves `@env` exactly once (a single call to
  `resolve/1`) so the directory reported and the directory actually
  created/chmod'd can never diverge, even if `SPRAT_DATA_DIR` or the
  `:sprat, :data_dir` app env were ever mutated between two separate
  resolutions in the same call.
  """
  def data_dir_with_reason do
    {dir, reason} = resolve(@env)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    {dir, reason}
  end

  @doc "Path to the main SQLite database file."
  def db_path, do: Path.join(data_dir(), "sprat.db")

  @doc "Path to the content-addressed blob store root."
  def blobs_dir, do: Path.join(data_dir(), "blobs/sha256")

  @doc """
  Root directory for build-phase git worktrees (docs/spec-v2.md §7: "under
  the project's data dir, never inside the user's checkout"). Each task
  gets its own subdirectory here, never inside the attached project's own
  working tree.
  """
  def worktrees_dir, do: Path.join(data_dir(), "worktrees")

  @doc """
  Root directory for from-scratch build targets (docs/spec-v2.md §7): a
  fresh scaffold has no existing git repo to pin a worktree's base
  revision to, so the scaffold stage first `git init`s an empty project
  here (one directory per mission, under the project's data dir — never
  the user's own checkout), then uses `Sprat.Workspace.create/4` exactly
  as any other build task would, pinned to that empty repo's own initial
  commit.
  """
  def projects_dir, do: Path.join(data_dir(), "projects")

  @doc """
  The pure resolution logic behind `data_dir/0`, taking `env` explicitly
  (`:dev` / `:test` / `:prod`) instead of reading `Mix.env()` internally,
  so it's directly testable under `mix test` (which always runs as
  `MIX_ENV=test` itself) for every other env value too — in particular,
  proving a `:dev` resolution can never land on the production path.

  Reads `SPRAT_DATA_DIR` and the `:sprat, :data_dir` application env at
  call time (both mockable in a test), and only falls back to computing
  the platform default from `env` once both are unset.
  """
  def resolve(env) do
    cond do
      dir = System.get_env("SPRAT_DATA_DIR") ->
        {dir, "SPRAT_DATA_DIR override"}

      dir = Application.get_env(:sprat, :data_dir) ->
        {dir, "config override"}

      env == :dev ->
        {Path.join(raw_data_dir(), "dev"), "dev build — separate from your production data"}

      env == :test ->
        # Belt-and-braces: config/test.exs always sets the `:sprat,
        # :data_dir` app env above, so this arm should be unreachable in
        # practice. It exists so that even a hypothetical boot path that
        # skips that config (e.g. `mix run` under a hand-rolled MIX_ENV=test
        # invocation) still can't fall through to the production directory.
        {Path.join(System.tmp_dir!(), "sprat-test-fallback"), "test — isolated fallback"}

      true ->
        {raw_data_dir(), "production"}
    end
  end

  defp raw_data_dir do
    case :os.type() do
      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", @app_name])

      {:unix, _linux} ->
        base = System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share")
        Path.join(base, @app_name)

      other ->
        raise "unsupported platform: #{inspect(other)}"
    end
  end
end
