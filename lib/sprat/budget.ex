defmodule Sprat.Budget do
  @moduledoc """
  Reservations and hard enforcement for the per-mission money cap
  (docs/spec-v1.md §12). "The reservation is held in the single
  Orchestrator process and released when the call's usage arrives" — this
  `GenServer` *is* that process for budget purposes; it holds only
  in-flight reservations (transient, lost on restart is fine per the
  spec's recovery story), never `spent`, which is always read fresh from
  `Sprat.Store.Usage` so it can never drift from the ledger of record.

  Caps are set per mission with `set_cap/3`. A mission with no cap set
  admits no calls — callers must decide the cap first (§12: "first mission
  in a project: the user is asked to confirm a budget").

  Price-unknown rule (§7 owner decision #3): `reserve/3` with a `nil`
  `worst_case_cost` never checks money at all and always returns
  `{:error, :price_unknown}` — a money cap cannot be enforced against a
  model whose price isn't known, so the caller (`Sprat.Agent.Loop`) must
  fall back to its own time/call/token limits instead of a Budget
  reservation.
  """

  use GenServer

  alias Sprat.Store.Usage

  defstruct [:store, caps: %{}, reservations: %{}]

  @warn_percent 80

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sets (or replaces) the hard cap for `mission_id`, as a `Decimal`."
  def set_cap(server \\ __MODULE__, mission_id, %Decimal{} = cap) do
    GenServer.call(server, {:set_cap, mission_id, cap})
  end

  @doc """
  Reserves `worst_case_cost` (a `Decimal`, or `nil` if the model's price is
  unknown) against `mission_id`'s cap. Returns:

    * `{:ok, ref}` — reserved; settle or release it when the call finishes
    * `{:error, :price_unknown}` — no cap check was possible at all
    * `{:error, :no_cap_set}`
    * `{:error, {:would_exceed_cap, %{spent:, reserved:, cap:}}}`
  """
  def reserve(server \\ __MODULE__, mission_id, worst_case_cost)
  def reserve(_server, _mission_id, nil), do: {:error, :price_unknown}

  def reserve(server, mission_id, %Decimal{} = worst_case_cost) do
    GenServer.call(server, {:reserve, mission_id, worst_case_cost})
  end

  @doc "Releases `ref` without recording any spend (the call never happened, or failed before any usage)."
  def release(server \\ __MODULE__, ref), do: GenServer.call(server, {:release, ref})

  @doc """
  Settles `ref`: the reservation is dropped. Actual cost is already in
  `usage_records` by the time this is called (the caller records usage via
  `Sprat.Store.Usage.record/2` first) — settling just stops double-counting
  the reservation on top of the now-real spend.
  """
  def settle(server \\ __MODULE__, ref), do: GenServer.call(server, {:release, ref})

  @doc """
  Current status for `mission_id`: `%{cap:, spent:, reserved:, percent_used:, warn?:, exceeded?:}`.
  `spent` is `nil` (unknown) rather than zero if no usage records exist yet
  and none can be computed — matches `Sprat.Store.Usage.totals/1`'s
  "unknown stays unknown" rule.
  """
  def status(server \\ __MODULE__, mission_id), do: GenServer.call(server, {:status, mission_id})

  # -- server -------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, %__MODULE__{store: Keyword.get(opts, :store, Sprat.Store)}}
  end

  @impl true
  def handle_call({:set_cap, mission_id, cap}, _from, state) do
    {:reply, :ok, put_in(state.caps[mission_id], cap)}
  end

  def handle_call({:reserve, mission_id, worst_case_cost}, _from, state) do
    case Map.get(state.caps, mission_id) do
      nil ->
        {:reply, {:error, :no_cap_set}, state}

      cap ->
        spent = spent(state, mission_id)
        reserved = reserved_total(state, mission_id)
        projected = spent |> Decimal.add(reserved) |> Decimal.add(worst_case_cost)

        if Decimal.compare(projected, cap) == :gt do
          {:reply, {:error, {:would_exceed_cap, %{spent: spent, reserved: reserved, cap: cap}}},
           state}
        else
          ref = make_ref()
          state = put_in(state.reservations[ref], {mission_id, worst_case_cost})
          {:reply, {:ok, ref}, state}
        end
    end
  end

  def handle_call({:release, ref}, _from, state) do
    {:reply, :ok, %{state | reservations: Map.delete(state.reservations, ref)}}
  end

  def handle_call({:status, mission_id}, _from, state) do
    cap = Map.get(state.caps, mission_id)
    spent = spent(state, mission_id)
    reserved = reserved_total(state, mission_id)

    percent_used =
      case {spent, cap} do
        {nil, _} ->
          nil

        {_, nil} ->
          nil

        {s, c} ->
          s |> Decimal.add(reserved) |> Decimal.div(c) |> Decimal.mult(100) |> Decimal.to_float()
      end

    status = %{
      cap: cap,
      spent: spent,
      reserved: reserved,
      percent_used: percent_used,
      warn?: percent_used != nil and percent_used >= @warn_percent,
      exceeded?: percent_used != nil and percent_used >= 100
    }

    {:reply, status, state}
  end

  defp spent(state, mission_id) do
    case Usage.by_mission(state.store, mission_id) |> Usage.totals() do
      %{cost: nil} -> Decimal.new(0)
      %{cost: cost} -> cost
    end
  end

  defp reserved_total(state, mission_id) do
    state.reservations
    |> Enum.filter(fn {_ref, {mid, _cost}} -> mid == mission_id end)
    |> Enum.map(fn {_ref, {_mid, cost}} -> cost end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end
end
