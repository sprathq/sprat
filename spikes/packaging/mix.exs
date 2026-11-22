defmodule SpratSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprat_spike,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :inets, :crypto],
      mod: {SpratSpike.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.30"},
      {:req, "~> 0.5"},
      {:burrito, "~> 1.6"}
    ]
  end

  defp releases do
    [
      sprat_spike: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ],
      # ponytail: fallback path (docs/spec-v1.md §14 item 4) — a plain
      # release with ERTS bundled, native-built per host, no Burrito. See
      # docs/phase0/04-packaging-spike.md for why Burrito 1.6.0 doesn't work.
      sprat_spike_plain: [
        steps: [:assemble, :tar],
        include_erts: true
      ]
    ]
  end
end
