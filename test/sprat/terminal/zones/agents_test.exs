defmodule Sprat.Terminal.Zones.AgentsTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Agents
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{22, 8}, {18, 4}, {60, 20}]

  defp agents do
    [
      %{
        id: "pm",
        role: :pm,
        label: "PM",
        state: :idle,
        elapsed_s: nil,
        tokens: nil,
        activity: nil
      },
      %{
        id: "r1",
        role: :researcher,
        label: "Researcher·1",
        state: :active,
        elapsed_s: 62,
        tokens: 1200,
        activity: "fetching reddit"
      }
    ]
  end

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells" do
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents(), messages: []})

    for {w, h} <- @widths do
      rows = Agents.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "an empty agent list renders an honest empty state, not fake cards" do
    state = Agents.init([])
    rows = Agents.render(state, %{x: 0, y: 0, w: 30, h: 5}, false, 0)
    assert rows_to_text(rows) =~ "No agents yet."
  end

  test "every card shows the agent's state word (colour is never the only signal)" do
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents(), messages: []})
    text = Agents.render(state, %{x: 0, y: 0, w: 40, h: 6}, false, 0) |> rows_to_text()
    assert text =~ "idle"
    assert text =~ "active"
  end

  test "Enter emits {:open_detail, {:agent, selected_agent}} for the selected card" do
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents(), messages: []})
    {_state, intents} = Agents.handle_key(state, :enter)
    assert [{:open_detail, {:agent, %{id: "pm"}}}] = intents
  end

  test "Down then Enter selects the second card" do
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents(), messages: []})
    {state, []} = Agents.handle_key(state, :down)
    {_state, intents} = Agents.handle_key(state, :enter)
    assert [{:open_detail, {:agent, %{id: "r1"}}}] = intents
  end

  test "Space emits {:toggle_pin, {:agent, agent}} for the selected card — the same shape Enter's {:open_detail, _} uses, not just the id (Zones.Detail expects a map; sending only the id crashed it)" do
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents(), messages: []})
    {_state, intents} = Agents.handle_key(state, :space)
    assert [{:toggle_pin, {:agent, %{id: "pm"}}}] = intents
  end

  test "the gutter shows a message travelling from sender to recipient" do
    agents = agents()
    messages = [%{from: "pm", to: "r1", type: :assignment, frame: 0}]
    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents, messages: messages})
    text = Agents.render(state, %{x: 0, y: 0, w: 40, h: 6}, false, 1) |> rows_to_text()
    assert text =~ "✉"
  end
end
