defmodule Sprat.Roadmap.Position do
  @moduledoc """
  Where a project stands on its roadmap (spec-v4 §5.3). Pure.

    * the active phase is the first phase with an item not done (a blocked
      item is not done);
    * the active item is that phase's first item neither done nor blocked,
      or its first blocked item when every open item is blocked;
    * done/total counts the active phase (the whole roadmap when all is done);
    * last progress is the newest progress event;
    * velocity is items done (`:tick` / `:done` events) per active day over
      the last 14 days, where an active day is a day with any progress event.
  """

  alias Sprat.Observer.Model.{Phase, Position, Roadmap}

  @window_days 14
  @done_kinds [:tick, :done]

  @type event :: %{
          required(:kind) => atom(),
          required(:at) => DateTime.t(),
          optional(atom()) => term()
        }

  @spec compute(Roadmap.t(), [event()], DateTime.t()) :: Position.t()
  def compute(%Roadmap{} = rm, events, now) do
    {last_at, last_kind} = last_progress(events)
    velocity = velocity(events, now)
    base = %Position{last_progress_at: last_at, last_progress_kind: last_kind, velocity: velocity}

    case active_phase(rm) do
      nil ->
        items = Enum.flat_map(rm.phases, & &1.items)
        total = length(items)
        %{base | done: total, total: total, all_done?: total > 0}

      %Phase{} = phase ->
        item =
          Enum.find(phase.items, &(&1.state not in [:done, :blocked])) ||
            Enum.find(phase.items, &(&1.state == :blocked))

        %{
          base
          | phase_id: phase.id,
            phase_title: phase.title,
            item_id: item && item.id,
            item_text: item && item.text,
            done: Enum.count(phase.items, &(&1.state == :done)),
            total: length(phase.items)
        }
    end
  end

  @doc "The first phase with an item not done, or nil."
  @spec active_phase(Roadmap.t()) :: Phase.t() | nil
  def active_phase(%Roadmap{phases: phases}),
    do: Enum.find(phases, fn p -> Enum.any?(p.items, &(&1.state != :done)) end)

  @doc "The active phase's id, or nil."
  @spec active_phase_id(Roadmap.t()) :: String.t() | nil
  def active_phase_id(rm) do
    case active_phase(rm) do
      nil -> nil
      p -> p.id
    end
  end

  defp last_progress([]), do: {nil, nil}

  defp last_progress(events) do
    e = Enum.max_by(events, & &1.at, DateTime)
    {e.at, e.kind}
  end

  defp velocity(events, now) do
    since = DateTime.add(now, -@window_days * 86_400, :second)

    recent =
      Enum.filter(events, fn e ->
        DateTime.compare(e.at, since) != :lt and DateTime.compare(e.at, now) != :gt
      end)

    active_days = recent |> Enum.map(&DateTime.to_date(&1.at)) |> Enum.uniq() |> length()

    done =
      recent
      |> Enum.filter(&(&1.kind in @done_kinds))
      |> Enum.uniq_by(&(Map.get(&1, :item_id) || make_ref()))
      |> length()

    if active_days == 0, do: 0.0, else: Float.round(done / active_days, 2)
  end
end
