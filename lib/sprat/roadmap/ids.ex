defmodule Sprat.Roadmap.Ids do
  @moduledoc """
  Phase and item ids (spec-v4 §5.2). Phases are lettered `A`, `B`, … `Z`,
  `AA`, …; a phase that brings its own label (a spec's `Phase C`) keeps it
  when no earlier phase has taken it. Items are `<phase id>.<n>`, 1-based.
  """

  alias Sprat.Observer.Model.Phase

  @doc "The spreadsheet-style letter for a 0-based index."
  @spec letter(non_neg_integer()) :: String.t()
  def letter(index) when index < 26, do: <<?A + index>>
  def letter(index), do: letter(div(index, 26) - 1) <> letter(rem(index, 26))

  @doc """
  Gives every phase an id and every item `<phase id>.<n>`. A phase's existing
  id is kept if no earlier phase holds it; the rest get the next free letter.
  """
  @spec assign([Phase.t()]) :: [Phase.t()]
  def assign(phases) do
    reserved =
      phases |> Enum.map(& &1.id) |> Enum.filter(&(is_binary(&1) and &1 != "")) |> MapSet.new()

    {phases, _taken} =
      Enum.map_reduce(phases, MapSet.new(), fn p, taken ->
        id =
          if is_binary(p.id) and p.id != "" and not MapSet.member?(taken, p.id),
            do: p.id,
            else: next_free(MapSet.union(taken, reserved), 0)

        items =
          p.items
          |> Enum.with_index(1)
          |> Enum.map(fn {it, n} -> %{it | id: "#{id}.#{n}"} end)

        {%{p | id: id, items: items}, MapSet.put(taken, id)}
      end)

    phases
  end

  defp next_free(taken, i) do
    l = letter(i)
    if MapSet.member?(taken, l), do: next_free(taken, i + 1), else: l
  end
end
