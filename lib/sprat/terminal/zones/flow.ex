defmodule Sprat.Terminal.Zones.Flow do
  @moduledoc """
  The `f`/`Alt+f` message-flow overlay (`docs/design/tui-zones.md`
  "Message passing between agents" §3): who talks to whom, how much, and
  what just moved, built on `Terminal.MessageFlow`'s `edges/1`/`edge_lit?/2`.

  ponytail: renders as an annotated list (edge volumes + recent messages +
  a text sparkline) at every size, rather than the mockup's 2-D node
  graph — a real graph layout (node placement, edge routing around other
  nodes) is a lot of geometry for a screen that's read, not admired, and
  the design's own "degrade to a simple list when too small" fallback is
  *this* rendering. Upgrade to real node placement if the flat list proves
  hard to read with many roles.

  Fed via `handle_view_update/2` with the same `%{agents:, messages:}`
  shape `Zones.Agents` gets.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{MessageFlow, ZoneFrame}

  defstruct name: "Message flow", agents: [], messages: []

  @impl true
  def id, do: :flow

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {40, 10}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Message flow")}

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    %{
      state
      | agents: Map.get(view_model, :agents, state.agents),
        messages: Map.get(view_model, :messages, state.messages)
    }
  end

  @impl true
  def render(%__MODULE__{} = state, rect, _focused?, frame) do
    labels = Map.new(state.agents, &{&1.id, &1.label})

    lines =
      edge_lines(state.messages, labels, frame) ++
        [""] ++
        ["recent:"] ++
        recent_lines(state.messages, labels) ++
        [""] ++
        [sparkline_line(state.messages)] ++
        ["[a]ll  [t]ype filter  esc close"]

    ZoneFrame.wrap(header_title(state), true, rect, lines)
  end

  defp header_title(state), do: "Message flow — #{length(state.messages)} messages"

  defp edge_lines([], _labels, _frame), do: ["No traffic yet."]

  defp edge_lines(messages, labels, frame) do
    messages
    |> MessageFlow.edges()
    |> Enum.take(8)
    |> Enum.map(fn edge ->
      lit = if MessageFlow.edge_lit?(edge, frame), do: " *", else: ""
      "  #{label(labels, edge.from)} -> #{label(labels, edge.to)}  x#{edge.count}#{lit}"
    end)
  end

  defp recent_lines([], _labels), do: ["  (none)"]

  defp recent_lines(messages, labels) do
    messages
    |> Enum.reverse()
    |> Enum.take(10)
    |> Enum.map(fn m ->
      "  #{Map.get(m, :at, "?")}  #{label(labels, m.from)} -> #{label(labels, m.to)}  #{m.type}"
    end)
  end

  defp label(labels, id), do: Map.get(labels, id, to_string(id))

  @spark_glyphs ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

  defp sparkline_line([]), do: "traffic  (none yet)"

  defp sparkline_line(messages) do
    bars =
      messages
      |> Enum.chunk_every(max(div(length(messages), 20), 1))
      |> Enum.map(&length/1)
      |> then(fn counts -> counts |> Enum.map(&bar_glyph(&1, Enum.max(counts))) end)
      |> Enum.join()

    "traffic  #{bars}"
  end

  defp bar_glyph(_count, 0), do: hd(@spark_glyphs)

  defp bar_glyph(count, max_count) do
    idx = min(round(count / max_count * (length(@spark_glyphs) - 1)), length(@spark_glyphs) - 1)
    Enum.at(@spark_glyphs, idx)
  end

  @impl true
  def handle_key(%__MODULE__{} = state, _event), do: {state, []}
end
