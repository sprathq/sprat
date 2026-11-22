defmodule Sprat.Terminal.Zones.Inspector do
  @moduledoc """
  `❹ Inspector` (`docs/design/tui-zones.md` zone map): tabs Evidence ·
  Tasks · Runs · Diff · Usage · Events · Messages · Artifacts (spec-v1.md
  §10's required views, plus Messages — the design's "audit view" of §9
  message envelopes — Artifacts, staged-workflow's versioned deliverables
  — and Runs/Diff, the build phase's evidence (docs/spec-v2.md §11):
  "Inspector — a Diff tab (per task and combined), a Runs tab (every
  execution with its exit code)"). `[`/`]`
  are intercepted by `Terminal.Focus` as the global `{:inspector_tab, dir}`
  chord before they ever reach `handle_key/2` (see that module) —
  `Terminal.ZonedRenderer`'s `apply_global/2` calls `switch_tab/2` here.

  Fed via `handle_view_update/2` with `%{sources:, tasks:, runs:, diffs:,
  usage:, events:, messages:, artifacts:}` (any subset — unset keys keep
  their previous value). `usage` is the `%{cost:, input_tokens:, ...}`
  shape `Sprat.Store.Usage.totals/1` already returns; per spec-v1.md §12
  every field renders literally as `unknown` when `nil`, never `0`.

  `runs` is `Sprat.Store.Runs.by_mission/2`'s list of `%Sprat.Store.Runs{}`
  (or `by_mission_with_output/2`'s maps, once Detail opens one — see its
  moduledoc). `diffs` is a list of `%{task_id:, label:, diff:}` maps —
  `Sprat.Workspace.diff/2` and `.combine_diffs/1`'s output, one entry per
  task plus a `label: "combined"` entry — this zone never runs `git`
  itself.

  Where a tab has no data, the empty state names what's actually missing
  rather than showing a decorative placeholder (the task brief's "a real
  session with no agents must render correctly and empty, not fake").
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Diff, Glyphs, ZoneFrame}

  @tabs [:evidence, :tasks, :runs, :diff, :usage, :events, :messages, :artifacts]

  defstruct name: "Inspector",
            tab_index: 0,
            selected: 0,
            sources: [],
            tasks: [],
            runs: [],
            diffs: [],
            usage: nil,
            events: [],
            messages: [],
            artifacts: []

  @impl true
  def id, do: :inspector

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {18, 6}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Inspector")}

  @doc "Cycles the current tab :prev/:next, resetting the selection."
  def switch_tab(%__MODULE__{} = state, dir) do
    n = length(@tabs)
    delta = if dir == :next, do: 1, else: -1
    %{state | tab_index: rem(state.tab_index + delta + n, n), selected: 0}
  end

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    %{
      state
      | sources: Map.get(view_model, :sources, state.sources),
        tasks: Map.get(view_model, :tasks, state.tasks),
        runs: Map.get(view_model, :runs, state.runs),
        diffs: Map.get(view_model, :diffs, state.diffs),
        usage: Map.get(view_model, :usage, state.usage),
        events: Map.get(view_model, :events, state.events),
        messages: Map.get(view_model, :messages, state.messages),
        artifacts: Map.get(view_model, :artifacts, state.artifacts),
        selected: 0
    }
  end

  @impl true
  def render(%__MODULE__{} = state, rect, focused?, _frame) do
    ZoneFrame.wrap(state.name, focused?, rect, [tab_bar(state) | body_lines(state)])
  end

  # A row of all 5 tab names ("[Evidence] Tasks Usage Events Messages")
  # doesn't fit the Inspector's own column width and was cutting mid-word
  # ("Usag") — show only the selected tab, with arrows hinting there are
  # more either side (`[` / `]` or the `{:inspector_tab, dir}` chord
  # cycles), same shape a carousel/breadcrumb uses when it can't show
  # every option at once.
  defp tab_bar(state) do
    {left, right} = Glyphs.tab_arrows(Glyphs.ascii?())
    word = current_tab(state) |> Atom.to_string() |> String.capitalize()
    "#{left} #{word} #{right} (#{state.tab_index + 1}/#{length(@tabs)})"
  end

  defp body_lines(state) do
    tab = current_tab(state)
    items = items_for(state, tab)

    if items == [] do
      [empty_state(tab)]
    else
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        marker =
          if idx == state.selected, do: "#{Glyphs.selected_marker(Glyphs.ascii?())} ", else: "  "

        marker <> item_line(tab, item)
      end)
    end
  end

  defp current_tab(%__MODULE__{tab_index: i}), do: Enum.at(@tabs, i)

  defp items_for(state, :evidence), do: state.sources
  defp items_for(state, :tasks), do: state.tasks
  defp items_for(state, :runs), do: state.runs
  defp items_for(state, :diff), do: state.diffs
  defp items_for(state, :events), do: state.events
  defp items_for(state, :messages), do: state.messages
  defp items_for(state, :artifacts), do: state.artifacts
  defp items_for(state, :usage), do: usage_lines(state.usage)

  defp empty_state(:evidence), do: "No sources recorded yet."
  defp empty_state(:tasks), do: "No tasks yet."
  defp empty_state(:runs), do: "No runs recorded for this mission yet."
  defp empty_state(:diff), do: "No diffs recorded for this mission yet."
  defp empty_state(:usage), do: "usage: unknown — no usage records yet."
  defp empty_state(:events), do: "No events yet."
  defp empty_state(:messages), do: "No agent messages recorded in this session yet."
  defp empty_state(:artifacts), do: "No artifacts written yet."

  defp item_line(:evidence, source), do: "#{source.title || source.url}"
  defp item_line(:tasks, task), do: "#{task.role} · #{task.objective} [#{task.status}]"
  defp item_line(:events, event), do: "#{event.occurred_at}  #{event.type}"

  defp item_line(:runs, run) do
    {glyph, word} = Glyphs.run_status(run.exit_code, Glyphs.ascii?())
    cmd = Enum.join([run.command | run.args], " ")
    "#{glyph} #{word} · #{run.purpose} · #{cmd} · #{run.duration_ms}ms#{run_flags(run)}"
  end

  defp item_line(:diff, entry) do
    {added, removed} = Diff.counts(entry.diff)
    "#{entry.label} — +#{added} -#{removed}"
  end

  defp item_line(:messages, message),
    do: "#{message[:at] || "?"}  #{message.from} -> #{message.to}  #{message.type}"

  defp item_line(:artifacts, a) do
    summary = Sprat.Export.Markdown.summary(a.type, Map.get(a, :content))
    stale = if Map.get(a, :stale), do: " [STALE]", else: ""
    "#{a.type} v#{a.latest_version} (#{a.owning_role})#{stale} — #{summary}"
  end

  defp item_line(:usage, line), do: line

  defp run_flags(run) do
    flags =
      []
      |> maybe_flag(run.truncated, "truncated")
      |> maybe_flag(run.network, "network")

    case flags do
      [] -> ""
      list -> " · " <> Enum.join(list, ", ")
    end
  end

  defp maybe_flag(list, true, label), do: list ++ [label]
  defp maybe_flag(list, _falsy, _label), do: list

  # -- usage (spec-v1.md §12: unknown stays unknown, never zero) --------------

  defp usage_lines(nil), do: []

  defp usage_lines(totals) do
    [
      "calls:   #{unknown_or(totals.calls)}",
      "cost:    #{money_or_unknown(totals.cost)}",
      "input:   #{tokens_or_unknown(totals.input_tokens)}",
      "output:  #{tokens_or_unknown(totals.output_tokens)}",
      "cache:   read #{tokens_or_unknown(totals.cache_read_tokens)} · write #{tokens_or_unknown(totals.cache_write_tokens)}"
    ]
  end

  defp unknown_or(nil), do: "unknown"
  defp unknown_or(n), do: to_string(n)

  defp tokens_or_unknown(nil), do: "unknown"
  defp tokens_or_unknown(n), do: "#{n} tokens"

  defp money_or_unknown(nil), do: "unknown"
  defp money_or_unknown(%Decimal{} = d), do: "$#{Decimal.round(d, 2)}"

  @impl true
  def handle_key(%__MODULE__{} = state, event) do
    items = items_for(state, current_tab(state))

    case event do
      :up -> {%{state | selected: clamp(state.selected - 1, length(items))}, []}
      :down -> {%{state | selected: clamp(state.selected + 1, length(items))}, []}
      :enter -> open(state, items)
      _other -> {state, []}
    end
  end

  defp open(state, []), do: {state, []}

  defp open(state, items) do
    tab = current_tab(state)
    {state, [{:open_detail, {tab, Enum.at(items, state.selected)}}]}
  end

  defp clamp(_index, 0), do: 0
  defp clamp(index, count), do: index |> max(0) |> min(count - 1)
end
