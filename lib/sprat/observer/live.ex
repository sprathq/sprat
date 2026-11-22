defmodule Sprat.Observer.Live do
  @moduledoc """
  The observers' published view of the machine (spec-v5 §3): ETS tables
  each observer process writes and the engine reads without a call, so the
  engine never waits on an observer and an observer never waits on the
  engine.

  This process only owns the tables. It starts first under
  `Sprat.Observer.Supervisor` (rest_for_one): if it dies, the tables go and
  every observer restarts and fills them again.

    * `:accounts` — `:dirs` => `%{config_dirs, account_dirs}`
    * `:cmux` — `:latest` => `{surfaces, status}`
    * `:sessions` — `:sessions` => sid => session; `:pids` => live pids
    * `:tails` — sid => `Sprat.Observer.Tail`
    * `:roadmaps` — root => roadmap cache entry
  """

  use GenServer

  @tables [:accounts, :cmux, :sessions, :tails, :roadmaps]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    for t <- @tables,
        do: :ets.new(name(t), [:set, :public, :named_table, read_concurrency: true])

    {:ok, %{}}
  end

  def put(table, key, value) do
    :ets.insert(name(table), {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def get(table, key, default \\ nil) do
    case :ets.lookup(name(table), key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  defp name(t), do: :"sprat_live_#{t}"
end
