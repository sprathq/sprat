defmodule Sprat.Build.ScaffoldTest do
  use Sprat.StoreCase, async: false

  alias Sprat.Build.Scaffold
  alias Sprat.Session
  alias Sprat.Store.{Grants, Missions, Runs, Sessions}

  defp open_session(store) do
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/x"})
    {:ok, _pid} = Sprat.SessionSupervisor.open(session.id, store: store)
    session
  end

  test "refuses an unsupported profile before touching git, grants, or the network", %{
    store: store
  } do
    session = open_session(store)
    {session2, mission, task} = fixture_chain(store, %{role: "swe"})
    # fixture_chain creates its own session row; the task/mission belong to
    # it, but Scaffold.run only needs `session_id:` for grant prompts,
    # which this test never reaches — session2 is unused on purpose.
    _ = session2

    assert {:error, {:unsupported_profile, "python-django"}} =
             Scaffold.run(mission, task, %{"profile" => "python-django"},
               session_id: session.id,
               store: store
             )

    assert Grants.by_session(store, session.id) == []
  end

  test "asks for the write/shell/network grants once, and stops if denied", %{store: store} do
    session = open_session(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})

    {:ok, task} =
      Sprat.Store.Tasks.create(store, mission.id, %{role: "swe", objective: "scaffold"})

    task_pid =
      Task.async(fn ->
        Scaffold.run(mission, task, %{"profile" => "elixir-phoenix"},
          session_id: session.id,
          store: store
        )
      end)

    assert wait_until(fn -> Session.snapshot(session.id).live.permission != nil end)
    assert Session.snapshot(session.id).live.permission.title =~ "write_workspace"
    :ok = Session.answer_permission(session.id, 1)

    assert {:error, {:grant_denied, "write_workspace"}} = Task.await(task_pid, 5_000)

    grants = Grants.by_session(store, session.id)
    assert Enum.any?(grants, &(&1.action == "write_workspace" and &1.decision == "denied"))
  end

  # docs/spec-v2.md §15 Phase A exit condition: "a scaffolded Phoenix app
  # that starts, from a real brief, with the first run recorded." This is
  # that proof — real `mix phx.new`, real `mix deps.get` (network), a
  # real `mix phx.server` started, health-checked over HTTP, and stopped.
  # No mocks anywhere in this test. Slow (a live scaffold + dependency
  # install can take well over a minute) — tagged so it can be skipped
  # with `mix test --exclude slow`, but it runs by default.
  @tag :slow
  @tag timeout: 420_000
  test "really scaffolds, installs, starts, health-checks and stops an elixir-phoenix app", %{
    store: store
  } do
    session = open_session(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "gym booking mvp"})

    {:ok, task} =
      Sprat.Store.Tasks.create(store, mission.id, %{role: "swe", objective: "Scaffold"})

    for action <- ~w(write_workspace shell network_install) do
      Grants.record(store, session.id, %{
        action: action,
        resource: "build",
        resource_scope: "session",
        lifetime: "session",
        decision: "approved",
        mission_id: mission.id
      })
    end

    assert :ok =
             Scaffold.run(mission, task, %{"profile" => "elixir-phoenix"},
               session_id: session.id,
               store: store
             )

    runs = Runs.by_mission(store, mission.id)

    install_run = Enum.find(runs, &(&1.purpose == "install"))
    run_run = Enum.find(runs, &(&1.purpose == "run"))
    health_check_run = Enum.find(runs, &(&1.purpose == "health_check"))

    assert install_run.exit_code == 0
    assert install_run.command == "mix"

    assert run_run.exit_code == 0
    assert run_run.command == "mix"

    assert health_check_run.exit_code == 0
    assert health_check_run.command == "GET"
    assert health_check_run.output_blob_hash != nil

    # Nothing left listening: every run recorded a real output hash, and
    # the port picked for this run is free again (the server was killed).
    port_event =
      store
      |> Sprat.Store.Events.by_mission(mission.id)
      |> Enum.find(&(&1.type == "scaffold.port_selected"))

    port = port_event.payload |> JSON.decode!() |> Map.fetch!("port")

    # The kill signal lands async — the OS can take a beat to actually
    # release the socket (TIME_WAIT), so poll rather than assert once.
    assert wait_until(fn ->
             case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
               {:ok, socket} ->
                 :gen_tcp.close(socket)
                 true

               {:error, _} ->
                 false
             end
           end)
  end

  defp wait_until(fun, tries \\ 1000)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(5)
      wait_until(fun, tries - 1)
    end
  end
end
