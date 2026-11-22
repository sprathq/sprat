defmodule Mix.Tasks.Sprat.Mcp do
  @shortdoc "Runs Sprat's PM tool server (MCP over stdio)"
  @moduledoc "Runs `Sprat.PM.MCPServer` on stdio without starting the application."
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile", ["--no-deps-check"])
    Sprat.PM.MCPServer.main()
  end
end
