defmodule SpratTerminalSpike.MixProject do
  use Mix.Project

  def project do
    [
      app: :sprat_terminal_spike,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:earmark, "~> 1.4"}]
  end

  # ponytail: escript gives a real TTY without `mix run` swallowing stdin (see docs/phase0 report).
  defp escript do
    [main_module: Sprat.Spike.CLI]
  end
end
