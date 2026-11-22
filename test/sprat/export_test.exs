defmodule Sprat.ExportTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Export
  alias Sprat.Store.{Artifacts, Missions, Sessions, Tasks, Usage}

  defp deliver(store, mission_id) do
    Artifacts.write(store, mission_id, %{
      type: :validation_plan,
      owning_role: "researcher",
      content: %{"experiments" => [%{"assumption" => "x"}]},
      created_by: "researcher"
    })
  end

  test "usage.csv totals match Sprat.Store.Usage.totals/1 over the same records", %{store: store} do
    {:ok, session} = Sessions.create(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "usage totals"})
    {:ok, task} = Tasks.create(store, mission.id, %{role: "researcher", objective: "research"})
    deliver(store, mission.id)

    {:ok, _} =
      Usage.record(store, %{
        mission_id: mission.id,
        task_id: task.id,
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "call_1",
        raw_payload: %{},
        input_tokens: 1000,
        output_tokens: 200,
        cost: Decimal.new("0.0123"),
        coverage: "reported",
        pricing_version: "test-1",
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    {:ok, _} =
      Usage.record(store, %{
        mission_id: mission.id,
        task_id: task.id,
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "call_2",
        raw_payload: %{},
        input_tokens: 500,
        output_tokens: 100,
        cost: Decimal.new("0.0056"),
        coverage: "reported",
        pricing_version: "test-1",
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    dir = Path.join(System.tmp_dir!(), "sprat-export-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, mission_dir} = Export.run(store, session.id, dir)

    expected = Usage.totals(Usage.by_mission(store, mission.id))

    [_header, row] =
      mission_dir |> Path.join("usage.csv") |> File.read!() |> String.trim() |> String.split("\n")

    [_stage, _role, calls, cost_usd, input_tokens, output_tokens | _] =
      row |> String.split(",") |> Enum.map(&String.trim(&1, "\""))

    assert String.to_integer(calls) == expected.calls
    assert Decimal.equal?(Decimal.new(cost_usd), expected.cost)
    assert String.to_integer(input_tokens) == expected.input_tokens
    assert String.to_integer(output_tokens) == expected.output_tokens
  end

  test "an unknown-coverage usage record shows as unknown in usage.md, never a fake zero", %{
    store: store
  } do
    {:ok, session} = Sessions.create(store)
    {:ok, mission} = Missions.create(store, session.id, %{objective: "unknown coverage"})
    {:ok, task} = Tasks.create(store, mission.id, %{role: "researcher", objective: "research"})
    deliver(store, mission.id)

    {:ok, _} =
      Usage.record(store, %{
        mission_id: mission.id,
        task_id: task.id,
        provider: "openai",
        model: "gpt-5-nano",
        request_id: "call_1",
        raw_payload: %{},
        cost: nil,
        coverage: "unavailable",
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    dir = Path.join(System.tmp_dir!(), "sprat-export-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, mission_dir} = Export.run(store, session.id, dir)

    usage_md = mission_dir |> Path.join("usage.md") |> File.read!()
    assert usage_md =~ "unknown"
    refute usage_md =~ "$0.00"
  end

  describe "unhappy paths" do
    test "no mission at all", %{store: store} do
      {:ok, session} = Sessions.create(store)
      assert {:error, message} = Export.run(store, session.id, System.tmp_dir!())
      assert message =~ "No mission"
    end

    test "mission still running, nothing delivered yet", %{store: store} do
      {:ok, session} = Sessions.create(store)
      {:ok, _mission} = Missions.create(store, session.id, %{objective: "x"})
      assert {:error, message} = Export.run(store, session.id, System.tmp_dir!())
      assert message =~ "still running"
    end

    test "mission failed before writing anything", %{store: store} do
      {:ok, session} = Sessions.create(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "x"})
      {:ok, _} = Missions.transition(store, mission.id, :failed, %{session_id: session.id})
      assert {:error, message} = Export.run(store, session.id, System.tmp_dir!())
      assert message =~ "failed"
    end

    test "mission delivered with a skipped stage still exports, README says how many", %{
      store: store
    } do
      {:ok, session} = Sessions.create(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "x"})

      Artifacts.write(store, mission.id, %{
        type: :research_memo,
        owning_role: "researcher",
        content: %{"incomplete" => true, "reason" => "skipped"},
        created_by: "researcher"
      })

      deliver(store, mission.id)

      dir =
        Path.join(System.tmp_dir!(), "sprat-export-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(dir) end)
      assert {:ok, mission_dir} = Export.run(store, session.id, dir)
      assert File.read!(Path.join(mission_dir, "README.md")) =~ "1 stage(s) skipped"
    end
  end
end
