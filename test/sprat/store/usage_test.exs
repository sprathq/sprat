defmodule Sprat.Store.UsageTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Store.Usage

  describe "record/2" do
    test "stores cost as a Decimal string, never a float", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      {:ok, record} =
        Usage.record(store, %{
          task_id: task.id,
          mission_id: mission.id,
          provider: "anthropic",
          model: "claude-x",
          raw_payload: %{"usage" => %{"input_tokens" => 100}},
          input_tokens: 100,
          output_tokens: 50,
          cost: Decimal.new("0.0123"),
          pricing_version: "anthropic-2026-09-01",
          coverage: :reported
        })

      assert record.cost_decimal == "0.0123"

      [row] =
        Sprat.Store.fetch_all(store, "SELECT cost_decimal FROM usage_records WHERE id = ?1", [
          record.id
        ])

      assert row["cost_decimal"] == "0.0123"
    end

    test "raises if cost is given as a float" do
      assert_raise ArgumentError, ~r/must be a Decimal/, fn ->
        Sprat.Store.Usage.record_in_conn(nil, %{
          task_id: "t",
          mission_id: "m",
          provider: "anthropic",
          model: "x",
          raw_payload: %{},
          cost: 0.5,
          coverage: :reported
        })
      end
    end

    test "raises for an invalid coverage value" do
      assert_raise ArgumentError, ~r/invalid coverage/, fn ->
        Sprat.Store.Usage.record_in_conn(nil, %{
          task_id: "t",
          mission_id: "m",
          provider: "anthropic",
          model: "x",
          raw_payload: %{},
          coverage: :bogus
        })
      end
    end

    test "an interrupted call with no usage is recorded as estimated", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      {:ok, record} =
        Usage.record(store, %{
          task_id: task.id,
          mission_id: mission.id,
          provider: "anthropic",
          model: "claude-x",
          raw_payload: %{"partial" => true},
          input_tokens: 40,
          output_tokens: nil,
          cost: nil,
          coverage: :estimated
        })

      assert record.coverage == "estimated"
      assert record.cost_decimal == nil
    end
  end

  describe "totals/1" do
    test "sums leaf records, never sums of sums" do
      records = [
        %Usage{
          cost_decimal: "1.00",
          input_tokens: 10,
          output_tokens: 5,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        },
        %Usage{
          cost_decimal: "2.50",
          input_tokens: 20,
          output_tokens: 15,
          cache_read_tokens: 3,
          cache_write_tokens: nil
        }
      ]

      totals = Usage.totals(records)

      assert totals.calls == 2
      assert Decimal.equal?(totals.cost, Decimal.new("3.50"))
      assert totals.input_tokens == 30
      assert totals.output_tokens == 20
      assert totals.cache_read_tokens == 3
      assert totals.cache_write_tokens == nil
    end

    test "unknown never becomes zero: an all-nil field aggregates to nil, not 0" do
      records = [
        %Usage{
          cost_decimal: nil,
          input_tokens: nil,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        },
        %Usage{
          cost_decimal: nil,
          input_tokens: nil,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        }
      ]

      totals = Usage.totals(records)

      assert totals.cost == nil
      assert totals.input_tokens == nil
      assert totals.output_tokens == nil
      refute totals.cost == Decimal.new(0)
      refute totals.input_tokens == 0
    end

    test "a mix of known and unknown records still sums the known ones" do
      records = [
        %Usage{
          cost_decimal: "1.00",
          input_tokens: 10,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        },
        %Usage{
          cost_decimal: nil,
          input_tokens: nil,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        }
      ]

      totals = Usage.totals(records)

      assert Decimal.equal?(totals.cost, Decimal.new("1.00"))
      assert totals.input_tokens == 10
      assert totals.output_tokens == nil
    end

    test "empty list totals to nil fields and zero calls" do
      totals = Usage.totals([])

      assert totals == %{
               calls: 0,
               cost: nil,
               input_tokens: nil,
               output_tokens: nil,
               cache_read_tokens: nil,
               cache_write_tokens: nil
             }
    end
  end

  describe "by_task/2 and by_mission/2" do
    test "roundtrip through the DB and totals correctly", %{store: store} do
      {_session, mission, task} = fixture_chain(store)

      Enum.each([Decimal.new("0.10"), Decimal.new("0.20")], fn cost ->
        Usage.record(store, %{
          task_id: task.id,
          mission_id: mission.id,
          provider: "anthropic",
          model: "claude-x",
          raw_payload: %{},
          input_tokens: 10,
          cost: cost,
          coverage: :reported
        })
      end)

      totals = store |> Usage.by_task(task.id) |> Usage.totals()
      assert totals.calls == 2
      assert Decimal.equal?(totals.cost, Decimal.new("0.30"))

      mission_totals = store |> Usage.by_mission(mission.id) |> Usage.totals()
      assert mission_totals.calls == 2
    end
  end
end
