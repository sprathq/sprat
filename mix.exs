defmodule Sprat.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprat,
      version: "0.4.7",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: releases()
    ]
  end

  # The release is named `sprat_rt` so that `mix release`'s generated
  # start script is `bin/sprat_rt`, leaving `bin/sprat` free for the
  # overlay script users actually type. Nobody runs `sprat_rt` by hand.
  defp releases do
    [
      sprat_rt: [
        applications: [sprat: :permanent],
        include_executables_for: [:unix]
      ]
    ]
  end

  # ponytail: no `mix escript.build` here — escripts don't bundle a NIF's
  # `priv/` directory (exqlite's precompiled sqlite3 NIF, confirmed by
  # trying it), so an escript can never start `Sprat.Store`. The real
  # entry point is the release path `test/tty/verify.sh` already builds
  # against (`mix release`, then `bin/sprat start`/`eval`) — see
  # `Sprat.CLI.main/1`, called as `bin/sprat eval
  # "Sprat.CLI.main(System.argv())"`.

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # :crypto is used throughout (id generation, content hashing) via
      # :crypto.strong_rand_bytes/1 and :crypto.hash/2 — harmless under
      # `mix`/`iex` (the erl VM already has it booted), but a `mix
      # release`'s boot script only starts applications it's told about,
      # so this was silently missing until exercised through a real
      # release (see docs/PAUSE.md-style note in the wiring report).
      extra_applications: [:logger, :crypto],
      mod: {Sprat.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:earmark, "~> 1.4"},
      {:exqlite, "~> 0.40"},
      {:decimal, "~> 2.0"},
      {:req, "~> 0.5"},
      {:tz, "~> 0.28"},
      {:stream_data, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
