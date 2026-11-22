defmodule Mix.Tasks.Sprat.Demo do
  @moduledoc """
  Runs the terminal UI demo against a real terminal. See `mix help
  sprat.demo`.

      mix sprat.demo          # the old inline renderer's demo
      mix sprat.demo --zones  # the zoned UI: layout, focus, modes, scroll, spinner
  """
  @shortdoc "Run the Sprat terminal UI demo"

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    if "--zones" in args do
      Sprat.Demo.run_zones()
    else
      Sprat.Demo.run()
    end
  end
end
