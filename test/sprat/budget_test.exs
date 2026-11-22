defmodule Sprat.BudgetTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Budget
  alias Sprat.Store.Usage

  setup %{store: store, store_name: store_name} do
    {:ok, budget} =
      Budget.start_link(name: :"budget_#{System.unique_integer([:positive])}", store: store)

    {session, mission, task} = fixture_chain(store)

    %{
      budget: budget,
      store: store,
      store_name: store_name,
      session: session,
      mission: mission,
      task: task
    }
  end

  test "reserve/settle keeps spend within cap", %{budget: budget, mission: mission} do
    Budget.set_cap(budget, mission.id, Decimal.new("5.00"))
    assert {:ok, ref} = Budget.reserve(budget, mission.id, Decimal.new("2.00"))
    assert :ok = Budget.settle(budget, ref)
    status = Budget.status(budget, mission.id)
    assert Decimal.equal?(status.reserved, Decimal.new(0))
  end

  test "refuses a reservation that would exceed the cap", %{budget: budget, mission: mission} do
    Budget.set_cap(budget, mission.id, Decimal.new("1.00"))

    assert {:error, {:would_exceed_cap, _}} =
             Budget.reserve(budget, mission.id, Decimal.new("2.00"))
  end

  test "no cap set refuses every reservation", %{budget: budget, mission: mission} do
    assert {:error, :no_cap_set} = Budget.reserve(budget, mission.id, Decimal.new("0.01"))
  end

  test "price unknown (nil worst case) never checks money and always errors", %{
    budget: budget,
    mission: mission
  } do
    Budget.set_cap(budget, mission.id, Decimal.new("5.00"))
    assert {:error, :price_unknown} = Budget.reserve(budget, mission.id, nil)
  end

  test "release drops a reservation without counting it as spend", %{
    budget: budget,
    mission: mission
  } do
    Budget.set_cap(budget, mission.id, Decimal.new("1.00"))
    {:ok, ref} = Budget.reserve(budget, mission.id, Decimal.new("0.90"))
    :ok = Budget.release(budget, ref)
    assert {:ok, _ref2} = Budget.reserve(budget, mission.id, Decimal.new("0.90"))
  end

  test "spent is read from real usage records, never duplicated state", %{
    budget: budget,
    mission: mission,
    task: task,
    store: store
  } do
    Budget.set_cap(budget, mission.id, Decimal.new("5.00"))

    Usage.record(store, %{
      task_id: task.id,
      mission_id: mission.id,
      provider: "openai",
      model: "gpt-4.1-mini",
      raw_payload: %{},
      coverage: "reported",
      cost: Decimal.new("3.00")
    })

    status = Budget.status(budget, mission.id)
    assert Decimal.equal?(status.spent, Decimal.new("3.00"))

    assert {:error, {:would_exceed_cap, _}} =
             Budget.reserve(budget, mission.id, Decimal.new("2.50"))

    assert {:ok, _ref} = Budget.reserve(budget, mission.id, Decimal.new("2.00"))
  end

  test "warns at 80%, exceeded at 100%", %{
    budget: budget,
    mission: mission,
    task: task,
    store: store
  } do
    Budget.set_cap(budget, mission.id, Decimal.new("10.00"))

    Usage.record(store, %{
      task_id: task.id,
      mission_id: mission.id,
      provider: "openai",
      model: "gpt-4.1-mini",
      raw_payload: %{},
      coverage: "reported",
      cost: Decimal.new("8.00")
    })

    status = Budget.status(budget, mission.id)
    assert status.warn?
    refute status.exceeded?

    {:ok, _ref} = Budget.reserve(budget, mission.id, Decimal.new("2.00"))
    status2 = Budget.status(budget, mission.id)
    assert status2.exceeded?
  end

  test "concurrent reservations against a tight cap never overspend", %{
    budget: budget,
    mission: mission
  } do
    Budget.set_cap(budget, mission.id, Decimal.new("1.00"))

    results =
      1..20
      |> Task.async_stream(fn _ -> Budget.reserve(budget, mission.id, Decimal.new("0.10")) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    oks = Enum.count(results, &match?({:ok, _}, &1))
    # cap $1.00 at $0.10 each admits at most 10, regardless of race timing —
    # the single-GenServer-mailbox serialization is what makes this exact.
    assert oks == 10
  end
end
