defmodule Sprat.Terminal.Zones.Debug do
  @moduledoc """
  The `Alt+d`/`d` Debug/audit overlay: Requests · Tools · Events · Costs ·
  Logs, one full-screen overlay in the same family as `Zones.Flow`
  (`Alt+f`) and `Zones.Settings` (`Alt+s`) — see their moduledocs for why
  this build renders overlays as annotated lists rather than a 2-D layout.

  Fed via `handle_view_update/2` with `%{requests:, tools:, events:,
  costs:, logs:}` (any subset) — every row already carries its own
  `detail_lines` (pre-formatted, already-redacted strings) where the
  design calls for a drill-down, because `render/4` must stay pure and a
  detail pane needs a blob-store read (`Sprat.Debug.request_detail/2` /
  `tool_detail/2`) that only `Terminal.ZonedRenderer` (which already does
  I/O to open the overlay in the first place) can do. `Enter` toggles the
  selected row's detail open/closed — pure state, no new fetch.

  Nothing here is synthesised: an empty tab says plainly what's missing
  (no requests yet, no tool calls yet, ...) rather than showing a fake
  zero — the same rule `Zones.Inspector`'s Usage tab already follows for
  §12's "unknown stays unknown".
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.ZoneFrame

  @tabs [:requests, :tools, :events, :costs, :logs]

  defstruct name: "Debug",
            tab_index: 0,
            selected: 0,
            expanded: false,
            requests: [],
            tools: [],
            events: [],
            costs: nil,
            logs: []

  @impl true
  def id, do: :debug

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {40, 10}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Debug")}

  @doc "Cycles the current tab :prev/:next (mirrors `Zones.Inspector.switch_tab/2`)."
  def switch_tab(%__MODULE__{} = state, dir) do
    n = length(@tabs)
    delta = if dir == :next, do: 1, else: -1
    %{state | tab_index: rem(state.tab_index + delta + n, n), selected: 0, expanded: false}
  end

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    %{
      state
      | requests: Map.get(view_model, :requests, state.requests),
        tools: Map.get(view_model, :tools, state.tools),
        events: Map.get(view_model, :events, state.events),
        costs: Map.get(view_model, :costs, state.costs),
        logs: Map.get(view_model, :logs, state.logs),
        selected: 0,
        expanded: false
    }
  end

  @impl true
  def render(%__MODULE__{} = state, rect, _focused?, _frame) do
    lines =
      [tab_bar(state), ""] ++
        body_lines(state) ++
        ["", "[/]/Alt+[/] tabs · Enter expand · Esc/Alt+d close"]

    ZoneFrame.wrap("Debug", true, rect, lines)
  end

  defp tab_bar(state) do
    word = current_tab(state) |> Atom.to_string() |> String.capitalize()
    "‹ #{word} › (#{state.tab_index + 1}/#{length(@tabs)})"
  end

  defp current_tab(%__MODULE__{tab_index: i}), do: Enum.at(@tabs, i)

  defp body_lines(state) do
    case current_tab(state) do
      :costs -> costs_lines(state.costs)
      :logs -> list_lines(state.logs, state, &log_line/1, "No log lines captured yet.")
      :requests -> list_lines(state.requests, state, &request_line/1, "No model calls yet.")
      :tools -> list_lines(state.tools, state, &tool_line/1, "No tool calls yet.")
      :events -> list_lines(state.events, state, &event_line/1, "No events yet.")
    end
  end

  defp list_lines([], _state, _fmt, empty_text), do: [empty_text]

  defp list_lines(items, state, fmt, _empty_text) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, idx} ->
      marker = if idx == state.selected, do: "▸ ", else: "  "
      row = marker <> fmt.(item)

      if idx == state.selected and state.expanded do
        [row | detail_lines(item)]
      else
        [row]
      end
    end)
  end

  defp detail_lines(%{detail_lines: lines}) when is_list(lines),
    do: Enum.map(lines, &("    " <> &1))

  defp detail_lines(_item), do: ["    (no detail available)"]

  defp request_line(%{usage: u} = row) do
    cost = money_or_unknown(u.cost_decimal && Decimal.new(u.cost_decimal))
    tokens = "in #{u.input_tokens || "?"} / out #{u.output_tokens || "?"}"
    stop = row.stop_reason || "unknown"

    "#{u.ended_at}  #{u.model}  #{tokens}  #{cost}  [#{u.coverage}]  stop:#{stop}#{failed_suffix(row)}"
  end

  defp failed_suffix(%{failed?: true}), do: "  FAILED"
  defp failed_suffix(_), do: ""

  defp tool_line(%{requested: req} = row) do
    ok = ok_word(row.ok?)
    "#{req.occurred_at}  #{row.name}  #{ok}"
  end

  defp ok_word(true), do: "ok"
  defp ok_word(false), do: "error"
  defp ok_word(nil), do: "no result recorded"

  defp event_line(%{event: event}), do: "#{event.seq}  #{event.occurred_at}  #{event.type}"

  defp log_line(line), do: line

  defp costs_lines(nil), do: ["cost: unknown — no usage records yet."]

  defp costs_lines(%{mission_totals: totals} = costs) do
    header = [
      "Mission total: #{money_or_unknown(totals.cost)}  (#{totals.calls} calls)",
      "  of which unavailable/estimated: #{costs.unknown_or_estimated} calls",
      "  pricing table: #{costs.pricing_version || "unknown"}",
      completeness_line(costs),
      "",
      "Per task (leaf records only — never a sum of sums):"
    ]

    header ++ Enum.map(costs.per_task, &task_cost_line/1)
  end

  defp completeness_line(%{unknown_or_estimated: 0}),
    do: "  complete: every call's cost is known."

  defp completeness_line(%{unknown_or_estimated: n}),
    do: "  partial: #{n} call(s) estimated or unavailable — total may be a lower bound."

  defp task_cost_line(%{task: task, totals: totals}),
    do: "  #{task.role} · #{task.objective}: #{money_or_unknown(totals.cost)}"

  defp money_or_unknown(nil), do: "unknown"
  defp money_or_unknown(%Decimal{} = d), do: "$#{Decimal.round(d, 4)}"

  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)

  defp items_for(state, :requests), do: state.requests
  defp items_for(state, :tools), do: state.tools
  defp items_for(state, :events), do: state.events
  defp items_for(state, :logs), do: state.logs
  defp items_for(_state, :costs), do: []

  @impl true
  def handle_key(%__MODULE__{} = state, event) do
    items = items_for(state, current_tab(state))

    case event do
      :up ->
        {%{state | selected: clamp(state.selected - 1, length(items)), expanded: false}, []}

      :down ->
        {%{state | selected: clamp(state.selected + 1, length(items)), expanded: false}, []}

      :enter ->
        {%{state | expanded: not state.expanded}, []}

      _other ->
        {state, []}
    end
  end
end
