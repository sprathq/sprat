defmodule Sprat.CLI.V4 do
  @moduledoc """
  The V4 commands (spec-v4): `sprat` (the Pass board), `sprat serve`,
  `sprat status`, `sprat brief`, `sprat mcp`, `sprat install-agent`.
  The research product (V1/V2) stays reachable as `sprat legacy`.
  """

  alias Sprat.Engine
  alias Sprat.Engine.Runtime

  @doc "Opens the board: a client of `sprat serve` when it runs, else with its own engine."
  def board do
    opts =
      case Runtime.daemon_pid() do
        nil ->
          {:ok, _} = Runtime.start_engine()
          [snapshot_fun: fn -> Engine.snapshot() end, command_fun: &Engine.command/1]

        _pid ->
          remote_or_files()
      end

    Sprat.Terminal.BoardApp.run(opts)
  end

  # A daemon with a socket pushes every change (spec-v5 §6); one from before
  # the socket is read through its snapshot file and command spool.
  defp remote_or_files do
    case Sprat.Engine.Remote.start(path: Runtime.socket_path()) do
      {:ok, _} ->
        [
          snapshot_fun: fn -> Sprat.Engine.Remote.snapshot() || Runtime.client_snapshot() end,
          command_fun: &Sprat.Engine.Remote.command/1,
          subscribe: &Sprat.Engine.Remote.listen/1
        ]

      {:error, _} ->
        [snapshot_fun: &Runtime.client_snapshot/0, command_fun: &Runtime.client_command/1]
    end
  end

  def serve do
    case Runtime.serve() do
      {:error, :already_running} -> exit({:shutdown, 1})
      other -> other
    end
  end

  def status do
    snap = (Runtime.daemon_pid() && Runtime.client_snapshot()) || Runtime.passive_snapshot()
    Enum.each(Runtime.status_lines(snap), &IO.puts/1)

    case Enum.count(snap.tickets, &(&1.owner == :yours)) do
      0 -> :ok
      n -> IO.puts("\n#{n} need you · run `sprat` to see them")
    end
  end

  def brief do
    snap = (Runtime.daemon_pid() && Runtime.client_snapshot()) || Runtime.passive_snapshot()

    text =
      Sprat.Brief.compose(%{
        now: snap.now,
        projects: snap.projects,
        findings: Enum.map(snap.tickets, & &1.finding) |> Enum.reject(&is_nil/1),
        served: snap.served,
        pm_spend: snap.header.pm_spend
      })

    IO.puts(text)
  end

  def mcp, do: Sprat.PM.MCPServer.main()

  def install_agent do
    # Prefer the stable `sprat` on PATH (~/.local/bin/sprat from the
    # installer, $(brew --prefix)/bin/sprat from Homebrew): the release
    # directory itself changes with every upgrade.
    bin =
      case {System.find_executable("sprat"), System.get_env("RELEASE_ROOT")} do
        {path, _} when is_binary(path) -> path
        {nil, rel} when is_binary(rel) -> Path.join([rel, "bin", "sprat"])
        _ -> "sprat"
      end

    path = Runtime.launchd_path()
    plist = Runtime.launchd_plist(bin)
    IO.puts("Writing #{path}:\n\n#{plist}")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, plist)
    IO.puts("Load it now with:  launchctl load -w #{path}")
    IO.puts("Remove it with:    launchctl unload -w #{path} && rm #{path}")
  end
end
