defmodule SpratSpike.Application do
  @moduledoc """
  Entry point for the Burrito-wrapped release.

  This is a one-shot CLI, not a long-running server: `start/2` runs the
  command and halts the VM, per Burrito's application-entry-point contract
  (see README "Application Entry Point").
  """

  use Application

  alias SpratSpike.CLI

  @impl true
  def start(_type, _args) do
    if running_as_burrito_binary?() do
      exit_code = CLI.main(Burrito.Util.Args.argv())
      System.halt(exit_code)
    else
      # ponytail: `mix test`/`mix run` boot this Application too, and a CLI
      # exit here would kill the dev session. Only run-and-halt inside the
      # Burrito-wrapped binary; otherwise start an idle supervisor so
      # `mix test`, `iex -S mix` etc. keep working.
      Supervisor.start_link([], strategy: :one_for_one, name: SpratSpike.Supervisor)
    end
  end

  defp running_as_burrito_binary? do
    Code.ensure_loaded?(Burrito.Util) and Burrito.Util.running_standalone?()
  end
end
