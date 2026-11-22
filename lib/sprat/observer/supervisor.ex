defmodule Sprat.Observer.Supervisor do
  @moduledoc """
  The observers (spec-v5 §3): everything that looks at the machine, each in
  its own process, publishing to `Sprat.Observer.Live` for the engine.

      Observer.Supervisor (rest_for_one)
      ├─ Live                  the published tables
      ├─ SessionRegistry, ProjectRegistry
      ├─ SessionSupervisor     SessionServer × N (one per session)
      ├─ ProjectSupervisor     ProjectServer × N (one per project)
      ├─ Accounts              config dirs and accounts, every minute
      ├─ Cmux                  the surface map, every 15 s
      └─ Sessions              the session registry, every 2 s

  rest_for_one: losing the tables restarts everything after them; a crash
  in one observer restarts it and those started after it, never the engine.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      Sprat.Observer.Live,
      Supervisor.child_spec({Registry, keys: :unique, name: Sprat.Observer.SessionRegistry},
        id: Sprat.Observer.SessionRegistry
      ),
      Supervisor.child_spec({Registry, keys: :unique, name: Sprat.Observer.ProjectRegistry},
        id: Sprat.Observer.ProjectRegistry
      ),
      Supervisor.child_spec({DynamicSupervisor, name: Sprat.Observer.SessionSupervisor},
        id: Sprat.Observer.SessionSupervisor
      ),
      Supervisor.child_spec({DynamicSupervisor, name: Sprat.Observer.ProjectSupervisor},
        id: Sprat.Observer.ProjectSupervisor
      ),
      {Sprat.Observer.Accounts, opts},
      {Sprat.Observer.Cmux, opts},
      {Sprat.Observer.Sessions, opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
