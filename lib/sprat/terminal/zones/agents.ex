defmodule Sprat.Terminal.Zones.Agents do
  @moduledoc """
  `❷ Agents` (`docs/design/tui-zones.md` zone map): one collapsed card per
  role instance, plus the 3-column message-flow gutter on the left, driven
  by `Terminal.MessageFlow`.

  Fed via `handle_view_update/2` with `%{agents: [agent], messages: [message]}`
  — see `Terminal.MessageFlow` for the `message` shape and
  `Terminal.ZonedRenderer`'s `set_agents/2`/`add_message/2` for who sends
  it — `add_message/2` is the one that stamps a message's `:frame` (from
  the renderer's own `Terminal.Animate` clock), never the caller. An
  `agent` is `%{id:, role:, label:, state:, elapsed_s:, tokens:,
  activity:}` — `role` and `state` are `Terminal.Theme` role/state atoms.

  `Up`/`Down` moves the selection; `Enter` emits `{:open_detail, {:agent,
  agent}}` and `Space` emits `{:toggle_pin, {:agent, agent}}` — both the
  *same* `{:agent, agent_map}` shape (not just the id: found the hard way
  — sending only `agent.id` here crashed `Zones.Detail.render/4`, which
  expects a map, the moment Space was pressed) — `Zones.Detail` then keeps
  either one live itself (see its `handle_view_update/2`) by matching on
  `agent.id` against every later `%{agents: [...]}` push, so an expanded
  card's counters/activity keep moving rather than freezing at open time.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Animate, Glyphs, MessageFlow, Theme, ZoneFrame}

  defstruct name: "Agents", agents: [], messages: [], selected: 0

  @impl true
  def id, do: :agents

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {18, 4}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Agents")}

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    agents = Map.get(view_model, :agents, state.agents)

    %{
      state
      | agents: agents,
        messages: Map.get(view_model, :messages, state.messages),
        selected: clamp(state.selected, length(agents))
    }
  end

  @impl true
  def render(%__MODULE__{agents: []} = state, rect, focused?, _frame) do
    ZoneFrame.wrap(state.name, focused?, rect, ["No agents yet."])
  end

  def render(%__MODULE__{} = state, rect, focused?, frame) do
    ids = Enum.map(state.agents, & &1.id)
    gutter = MessageFlow.gutter(state.messages, ids, frame, Animate.enabled?())
    # The design mock's card is two lines (icon/role/state/elapsed, then an
    # indented current-activity line) — drop the activity line for every
    # card at once when there isn't room for all of them, rather than
    # dropping it card-by-card (which would read as arbitrary): "drop line
    # 2 first when space is tight" per the design brief.
    inner_h = max(rect.h - 2, 0)
    show_activity? = length(state.agents) * 2 <= inner_h

    lines =
      state.agents
      |> Enum.with_index()
      |> Enum.flat_map(fn {agent, idx} ->
        card_lines(agent, idx, idx == state.selected, gutter, frame, show_activity?)
      end)

    ZoneFrame.wrap(state.name, focused?, rect, lines)
  end

  defp card_lines(agent, idx, selected?, gutter, frame, show_activity?) do
    # The flow gutter only marks a card's *first* line — a burst spanning
    # several agents' activity (second) lines would show as a dashed
    # rather than solid connector; ponytail: acceptable at this card
    # density, revisit if a real multi-hop burst reads as broken rather
    # than just thin.
    gutter_cell = gutter_glyph(gutter, idx)
    role = Theme.role(agent.role)
    state = Theme.state(agent.state)
    state_glyph = if state.glyph == :spinner, do: Animate.spinner_frame(frame), else: state.glyph
    marker = if selected?, do: Glyphs.selected_marker(Glyphs.ascii?()), else: " "

    line1 =
      "#{gutter_cell} #{marker}#{role.glyph} #{agent.label} #{state_glyph} #{card_word(agent.state)}#{elapsed_word(agent)}"

    case {show_activity?, agent.activity} do
      {true, activity} when is_binary(activity) and activity != "" -> [line1, "  ⎿ #{activity}"]
      _ -> [line1]
    end
  end

  # A card's collapsed row (~20 usable columns once the border, gutter and
  # role glyph are accounted for) has no room for `Terminal.Theme`'s full
  # descriptive words ("waiting on a tool" is 18 characters on its own) —
  # `Zones.Detail`'s expanded view and `Zones.Inspector`'s Messages tab
  # still use `Theme.state/2`'s own `.word` in full; this is a
  # card-specific short form, still one distinct word per state (the
  # design's "colour always pairs with a glyph and a word" rule doesn't
  # require the *longest* word), matching the design mock's own compact
  # card ("⏸ idle", "✓ done", "⠙ 1m02" — elapsed instead of a state
  # phrase for the running states).
  defp card_word(:idle), do: "idle"
  defp card_word(:receiving), do: "new"
  defp card_word(:active), do: "active"
  defp card_word(:running), do: "active"
  defp card_word(:waiting_on_tool), do: "tool"
  defp card_word(:waiting_on_user), do: "you?"
  defp card_word(:blocked), do: "blocked"
  defp card_word(:failed), do: "failed"
  defp card_word(:done), do: "done"
  defp card_word(:queued), do: "queued"
  defp card_word(:paused), do: "paused"

  defp elapsed_word(%{elapsed_s: s}) when is_integer(s), do: " #{s}s"
  defp elapsed_word(_), do: ""

  defp gutter_glyph(nil, _idx), do: " "

  defp gutter_glyph(%{rows: rows, recipient: recipient, label: label}, idx) do
    cond do
      idx == recipient -> label
      idx in rows -> "│"
      true -> " "
    end
  end

  @impl true
  def handle_key(%__MODULE__{agents: agents} = state, :up) do
    {%{state | selected: clamp(state.selected - 1, length(agents))}, []}
  end

  def handle_key(%__MODULE__{agents: agents} = state, :down) do
    {%{state | selected: clamp(state.selected + 1, length(agents))}, []}
  end

  def handle_key(%__MODULE__{agents: []} = state, :enter), do: {state, []}

  def handle_key(%__MODULE__{} = state, :enter) do
    agent = Enum.at(state.agents, state.selected)
    {state, [{:open_detail, {:agent, agent}}]}
  end

  def handle_key(%__MODULE__{agents: []} = state, :space), do: {state, []}

  def handle_key(%__MODULE__{} = state, :space) do
    agent = Enum.at(state.agents, state.selected)
    {state, [{:toggle_pin, {:agent, agent}}]}
  end

  def handle_key(%__MODULE__{} = state, _event), do: {state, []}

  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)
end
