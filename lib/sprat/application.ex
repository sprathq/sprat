defmodule Sprat.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Mix.env/0 is a build-time-only API (the :mix app isn't part of a
  # release) — capture it as a compile-time constant instead of calling it
  # at runtime, so this stays release-safe (see docs/phase0/04-packaging-spike.md).
  @env Mix.env()

  @impl true
  def start(_type, _args) do
    halt_on_expected_startup_failure!()

    argv = release_argv()

    Sprat.LogHandler.install()

    children =
      [
        Sprat.Store,
        Sprat.Budget,
        Sprat.LogBuffer,
        Supervisor.child_spec({Registry, keys: :duplicate, name: Sprat.Session.PubSub.Registry},
          id: Sprat.Session.PubSub.Registry
        ),
        Supervisor.child_spec({Registry, keys: :unique, name: Sprat.Session.Registry},
          id: Sprat.Session.Registry
        ),
        Sprat.SessionSupervisor,
        Sprat.OrchestratorSupervisor | ui_children(argv)
      ] ++ release_children(argv)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sprat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Checks the database (unwritable data dir, a newer schema version than
  # this build understands, a corrupt file) before `Sprat.Store` becomes a
  # supervised child — a failure here would otherwise crash
  # `Supervisor.start_link/2` inside this very function, and since `:sprat`
  # boots as a `:permanent` application (see `mix.exs`), that takes the
  # whole VM down with it: a `Kernel pid terminated
  # (application_controller)` panic plus an `erl_crash.dump` written into
  # the user's cwd. `System.halt/1` (unlike raising, or letting the
  # Supervisor's child fail) never produces a crash dump and exits
  # immediately with no further code in this function running.
  #
  # `@env != :test`, same guard as `ui_children/1` above: `mix test`'s
  # data dir (`config/test.exs`) is deliberately STABLE across runs in the
  # same checkout, so it can carry a schema version left behind by a
  # different commit checked out earlier in this same worktree — a real,
  # not just theoretical, way for the top-level singleton `Sprat.Store`
  # to legitimately fail `precheck/1` under `mix test`. `System.halt/1`
  # there would kill the whole ExUnit process outright, with no test
  # failure report — strictly worse than this fix's starting point. Under
  # test, skip straight to the normal boot path and let a real failure
  # surface exactly as it always did: a visible exception inside
  # `Supervisor.start_link/2`/`Application.ensure_all_started/1`. Each
  # test's own, isolated `Sprat.Store` instances (`start_supervised!`
  # against their own temp files) are never affected either way — only
  # this singleton, application-supervised one is.
  defp halt_on_expected_startup_failure! do
    if @env != :test do
      case Sprat.Store.precheck() do
        :ok ->
          :ok

        {:error, message} ->
          IO.puts(:stderr, message)
          System.halt(1)
      end
    end
  end

  # The UI supervisor opens the controlling tty and puts it into raw mode,
  # so it must never start under `mix test` (no real terminal, would hang
  # reading /dev/stdin), when stdout isn't a real TTY (piped, CI, `-p`), or
  # when a non-interactive CLI command (`sprat doctor`, `sprat sessions
  # list|delete`, `sprat --plain`) has asked to skip it via the
  # `:sprat, :force_no_ui` app env — see `Sprat.CLI`. Also skipped whenever
  # this boot came from the `sprat` overlay script (`argv != nil`):
  # `Sprat.CLI.run_release/1` (started via `release_children/1` below)
  # brings up the UI itself, the same way `Sprat.CLI.main/1` already does
  # for every other launch path — starting it here too would race it.
  defp ui_children(argv) do
    if @env != :test and argv == nil and Sprat.Terminal.Mode.tty?() and
         not Application.get_env(:sprat, :force_no_ui, false) do
      [Sprat.UISupervisor]
    else
      []
    end
  end

  # `SPRAT_CLI_ARGV` is set only by `rel/overlays/bin/sprat` (an
  # `\x1e`-separated argv, since `bin/sprat start` — unlike `bin/sprat eval
  # "<code>"` — has no argument that carries Elixir code or args through
  # to the booted app) — never by `mix test`, `iex -S mix`, or a bare
  # `bin/sprat start`/`eval`, so every one of those existing launch paths
  # is untouched by any of this. `nil` means "not that path". Not NUL:
  # bash cannot hold a NUL byte in a variable at all, so a NUL-joined
  # argv silently collapsed every multi-arg invocation (`--resume <id>`,
  # `sessions delete <id>`) into one bogus token — found verifying this
  # build's Settings/Debug surfaces, see `rel/overlays/bin/sprat`.
  defp release_argv do
    case System.get_env("SPRAT_CLI_ARGV") do
      nil -> nil
      encoded -> String.split(encoded, "\x1e", trim: true)
    end
  end

  defp release_children(nil), do: []

  defp release_children(argv) do
    [
      Supervisor.child_spec({Task, fn -> Sprat.CLI.run_release(argv) end},
        id: Sprat.CLI.ReleaseEntry,
        restart: :temporary
      )
    ]
  end
end
