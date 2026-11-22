defmodule Sprat.Observer.Accounts do
  @moduledoc """
  Finds the Claude config dirs (sessions to scan) and the accounts (dirs
  that can run Claude), once a minute, in its own process: finding them
  reads every running process's environment (`ps -E`), which must not hold
  up the engine. Publishes to `Sprat.Observer.Live` (`:accounts`).
  """

  use GenServer
  require Logger

  alias Sprat.Observer.{ConfigDirs, Live}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The last dirs found: `%{config_dirs, account_dirs}` or nil."
  def latest, do: Live.get(:accounts, :dirs)

  @impl true
  def init(opts) do
    send(self(), :scan)
    {:ok, %{opts: opts, last: nil}}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, Keyword.get(state.opts, :accounts_ms, 60_000))

    dirs = %{
      config_dirs: Keyword.get_lazy(state.opts, :config_dirs, &ConfigDirs.list/0),
      account_dirs:
        Keyword.get_lazy(state.opts, :account_dirs, fn ->
          if Keyword.has_key?(state.opts, :config_dirs),
            do: state.opts[:config_dirs],
            else: ConfigDirs.accounts()
        end)
    }

    Live.put(:accounts, :dirs, dirs)

    if state.last && dirs.account_dirs -- state.last.account_dirs != [] do
      Sprat.Activity.emit(:observer,
        text:
          "found another Claude account: " <>
            Enum.map_join(dirs.account_dirs -- state.last.account_dirs, ", ", &Path.basename/1),
        status: :info
      )
    end

    {:noreply, %{state | last: dirs}}
  rescue
    e ->
      Logger.error("sprat accounts: " <> Exception.message(e))
      {:noreply, state}
  end
end
