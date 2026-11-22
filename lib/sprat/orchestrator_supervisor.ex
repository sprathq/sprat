defmodule Sprat.OrchestratorSupervisor do
  @moduledoc "DynamicSupervisor placeholder for future per-mission Orchestrator processes; currently unused since Sprat.Orchestrator.start/5 runs as an unlinked Task, matching Sprat.Mission's pattern."
  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
