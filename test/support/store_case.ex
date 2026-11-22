defmodule Sprat.StoreCase do
  @moduledoc """
  Starts an isolated `Sprat.Store` against a fresh temp file per test, so
  every test in `test/sprat/store/` can run `async: true` with no shared
  DB or data dir. Registers a fixture builder for the session/mission/task
  chain most Store tests need.
  """

  use ExUnit.CaseTemplate

  alias Sprat.Store.{Missions, Sessions, Tasks}

  using do
    quote do
      import Sprat.StoreCase
    end
  end

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "sprat-store-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    db_path = Path.join(tmp_dir, "test.db")

    name = :"store_#{System.unique_integer([:positive])}"
    {:ok, pid} = Sprat.Store.start_link(name: name, db_path: db_path)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, store: pid, store_name: name, tmp_dir: tmp_dir}
  end

  @doc "Creates a session/mission/task chain, returning `{session, mission, task}`."
  def fixture_chain(store, attrs \\ %{}) do
    {:ok, session} = Sessions.create(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "test objective"})

    {:ok, task} =
      Tasks.create(store, mission.id, %{
        role: attrs[:role] || "researcher",
        objective: attrs[:objective] || "test task"
      })

    {session, mission, task}
  end
end
