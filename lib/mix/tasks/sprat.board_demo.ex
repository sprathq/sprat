defmodule Mix.Tasks.Sprat.BoardDemo do
  @moduledoc """
  Runs the V4 board (the Pass, `docs/spec-v4.md` §10) full screen against
  demo data. Needs a real terminal. `q` or Ctrl+C quits.

      mix sprat.board_demo
      NO_COLOR=1 mix sprat.board_demo
      SPRAT_ASCII=1 mix sprat.board_demo
  """
  @shortdoc "Run the V4 board (the Pass) with demo data"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # The board owns the terminal itself; the app's own UI must never
    # start alongside it, so the app is loaded and configured, not started.
    Application.put_env(:sprat, :force_no_ui, true)
    Mix.Task.run("app.config")
    Sprat.Terminal.Board.Demo.run()
  end
end
