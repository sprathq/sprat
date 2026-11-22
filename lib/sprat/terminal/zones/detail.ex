defmodule Sprat.Terminal.Zones.Detail do
  @moduledoc """
  `❺ Detail` (`docs/design/tui-zones.md` zone map): whatever was opened via
  the `{:open_detail, term}` intent (an expanded agent, a source, a task,
  an event, a message payload) — `Terminal.ZonedRenderer` intercepts that
  intent (and `{:toggle_pin, term}`) and calls `open/2`/`toggle_pin/2`
  here directly rather than forwarding it to the intent subscriber, since
  Detail is the one place in this codebase that understands it.

  ## Eviction

  `open/2` always just replaces the single unpinned "preview" slot — it is
  never itself evicted *for* something else, so pinning is the only path
  that can ever displace a pinned card, and the design's rule ("never
  evict a pinned card while an unpinned one could be evicted instead") is
  true by construction: the unpinned preview is evicted on every `open/2`
  regardless, before a pinned card is ever touched. `pinned` is bounded to
  `@capacity` entries, oldest (by pin order, a monotonic counter — not
  wall clock) evicted first when a new pin would overflow it.

  ponytail: `@capacity` is a constant rather than derived from the zone's
  actual rendered height (that would need `Terminal.Layout`'s rect
  threaded through the intent-dispatch path, not just `render/4`) — 4
  roughly matches how many cards fit in a typical Detail rect. Revisit
  with a real rect-driven capacity if pinning routinely overflows or
  underflows the visible space in practice.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Diff, Glyphs, ZoneFrame}

  @capacity 4
  @max_card_lines 20
  # Diffs are naturally denser than an artifact's prose card — a few
  # changed files is easily 60-80 lines — so this cap is looser than
  # `@max_card_lines`; still capped, per spec-v2.md §11, never unbounded.
  @max_diff_lines 60

  defstruct name: "Detail", open: nil, pinned: [], next_id: 0

  @impl true
  def id, do: :detail

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {18, 4}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts), do: %__MODULE__{name: Keyword.get(opts, :name, "Detail")}

  @doc """
  Refreshes any open/pinned `{:agent, agent}` entry whose id matches one in
  `agents`, so an expanded agent's counters and stream tail keep moving
  instead of staying a still frame from the moment it was opened —
  `Terminal.ZonedRenderer` routes the same `%{agents: [...]}` view model
  `Zones.Agents`/`Zones.Flow` get here too. Anything else opened (a
  source, task, event, message) is left alone: those have no separate
  "live" feed in this build.
  """
  @impl true
  def handle_view_update(%__MODULE__{} = state, %{agents: agents}) when is_list(agents) do
    by_id = Map.new(agents, &{&1.id, &1})

    %{
      state
      | open: refresh_item(state.open, by_id),
        pinned: Enum.map(state.pinned, &refresh_entry(&1, by_id))
    }
  end

  def handle_view_update(%__MODULE__{} = state, _view_model), do: state

  defp refresh_item({:agent, %{id: id}} = item, by_id) do
    case Map.fetch(by_id, id) do
      {:ok, agent} -> {:agent, agent}
      :error -> item
    end
  end

  defp refresh_item(item, _by_id), do: item

  defp refresh_entry(%{item: item} = entry, by_id), do: %{entry | item: refresh_item(item, by_id)}

  @doc "Opens `item` as the unpinned preview, replacing whatever was previewed before. Never touches `pinned`."
  def open(%__MODULE__{} = state, item), do: %{state | open: item}

  @doc "Pins `item` if not already pinned, else unpins it. See moduledoc for eviction."
  def toggle_pin(%__MODULE__{} = state, item) do
    if Enum.any?(state.pinned, &same_item?(&1.item, item)) do
      %{state | pinned: Enum.reject(state.pinned, &same_item?(&1.item, item))}
    else
      pin(state, item)
    end
  end

  defp pin(%__MODULE__{} = state, item) do
    entry = %{item: item, pinned_at: state.next_id}

    pinned =
      (state.pinned ++ [entry])
      |> Enum.sort_by(& &1.pinned_at)
      |> evict(@capacity)

    %{state | pinned: pinned, next_id: state.next_id + 1}
  end

  defp evict(pinned, capacity) when length(pinned) <= capacity, do: pinned
  defp evict(pinned, capacity), do: Enum.drop(pinned, length(pinned) - capacity)

  @impl true
  def render(%__MODULE__{open: nil, pinned: []} = state, rect, focused?, _frame) do
    ZoneFrame.wrap(state.name, focused?, rect, ["Nothing selected."])
  end

  def render(%__MODULE__{} = state, rect, focused?, _frame) do
    cards =
      Enum.map(state.pinned, & &1.item) ++
        if state.open && not Enum.any?(state.pinned, &same_item?(&1.item, state.open)),
          do: [state.open],
          else: []

    lines = Enum.flat_map(cards, &card_lines(&1, state))
    ZoneFrame.wrap(state.name, focused?, rect, lines)
  end

  defp card_lines(item, state) do
    pin_word = if Enum.any?(state.pinned, &same_item?(&1.item, item)), do: " [pinned]", else: ""
    [title_line(item) <> pin_word | item_body_lines(item)] ++ [""]
  end

  # `{:agent, agent_map}` items are compared by id, not full map equality —
  # `Zones.Detail.handle_view_update/2` replaces the *map* inside an
  # open/pinned agent item on every live refresh, so the exact map a
  # `Space` keypress captures has already drifted from whatever was
  # pinned earlier for the same agent (different `elapsed_s`/`tokens`) —
  # `==` would treat those as two different items and let the same agent
  # be "pinned" twice, or fail to unpin at all. Every other item kind
  # (source, task, event, message) has no live refresh, so plain equality
  # is still correct for those.
  defp same_item?({:agent, %{id: id}}, {:agent, %{id: id}}), do: true
  defp same_item?({:agent, _}, {:agent, _}), do: false
  defp same_item?(a, b), do: a == b

  defp title_line({:agent, agent}), do: "Agent: #{agent.label}"
  defp title_line({:evidence, source}), do: "Source: #{source.title || source.url}"
  defp title_line({:tasks, task}), do: "Task: #{task.role}"
  defp title_line({:events, event}), do: "Event: #{event.type}"
  defp title_line({:messages, message}), do: "Message: #{message.type}"
  defp title_line({:artifacts, a}), do: "Artifact: #{a.type} v#{a.latest_version}"
  defp title_line({:runs, run}), do: "Run: #{run.purpose} · #{run.command}"
  defp title_line({:diff, entry}), do: "Diff: #{entry.label}"
  defp title_line(other), do: inspect(other)

  defp item_body_lines({:agent, agent}) do
    [
      "  state: #{agent.state}",
      "  elapsed: #{elapsed_word(agent.elapsed_s)}  tokens: #{agent.tokens || "unknown"}",
      "  #{agent.activity || "no current activity"}"
    ] ++ stream_tail_lines(agent)
  end

  defp item_body_lines({:evidence, source}) do
    ["  #{source.url}", "  type: #{source.source_type}  retrieved: #{source.retrieved_at}"]
  end

  defp item_body_lines({:tasks, task}) do
    ["  #{task.objective}", "  status: #{task.status}  attempt: #{task.attempt}"]
  end

  defp item_body_lines({:events, event}) do
    ["  #{event.occurred_at}", "  #{inspect(event.payload)}"]
  end

  defp item_body_lines({:messages, message}) do
    ["  #{message.from} -> #{message.to}", "  #{Map.get(message, :summary, "")}"]
  end

  # Renders as Markdown, not `inspect/1` on raw JSON (docs/spec-v1.md
  # §19) — `Sprat.Export.Markdown` is pure (no store access), so this
  # needs `:content` already attached to the item, which
  # `Sprat.Orchestrator`'s Inspector broadcast does via
  # `Sprat.Store.Artifacts.by_mission_with_content/2`. Long artifacts are
  # truncated here rather than handed to `$PAGER`: a real pager spawn
  # would race `Sprat.Terminal.Input`'s raw-stdin reader for the same tty
  # (see `Sprat.Session.Commands.open_artifact/3`'s comment on the same
  # deferred hazard) — `/export` is the honest way to get the full
  # artifact onto disk today.
  defp item_body_lines({:artifacts, a}) do
    content = Map.get(a, :content)
    lines = a.type |> Sprat.Export.Markdown.render(content) |> content_lines()
    truncate_body(lines)
  end

  # Run output (docs/spec-v2.md §11 "the captured output from the blob
  # store, scrollable, with the truncation notice shown when there is
  # one"). `run` is expected to already carry `:output` (resolved by
  # `Sprat.Store.Runs.by_mission_with_output/2` — this module is pure, no
  # store access, same split `{:artifacts, _}` has for `:content`). Secrets
  # are redacted before the output is ever written to the blob store
  # (`Agent.Tools.Shell`/`Store.Redact`); this only ever renders what it's
  # handed, never a second redaction pass — see the honesty rule in
  # docs/spec-v2.md §11.
  defp item_body_lines({:runs, run}) do
    {_glyph, word} = Glyphs.run_status(run.exit_code, Glyphs.ascii?())

    [
      "  #{run.command} #{Enum.join(run.args, " ")}",
      "  cwd: #{run.cwd}",
      "  exit: #{exit_code_word(run.exit_code)} (#{word})  duration: #{run.duration_ms}ms",
      "  sandbox: #{run.sandbox_strength}  network: #{yes_no_unknown(run.network)}"
    ] ++ truncation_notice(run) ++ ["", "  output:"] ++ output_lines(run)
  end

  defp item_body_lines({:diff, entry}) do
    case entry.diff do
      blank when blank in [nil, ""] ->
        ["  no changes against the base revision"]

      text ->
        text |> Diff.render(@max_diff_lines) |> Enum.map(&("  " <> &1))
    end
  end

  defp item_body_lines(_other), do: []

  defp exit_code_word(nil), do: "unknown"
  defp exit_code_word(code), do: to_string(code)

  defp yes_no_unknown(true), do: "yes"
  defp yes_no_unknown(false), do: "no"
  defp yes_no_unknown(_other), do: "unknown"

  defp truncation_notice(%{truncated: true}), do: ["  ⚠ output truncated at capture time"]
  defp truncation_notice(_run), do: []

  defp output_lines(%{output: output}) when is_binary(output) and output != "" do
    output |> String.split("\n") |> Enum.map(&("  " <> &1)) |> truncate_body()
  end

  defp output_lines(%{output: ""}), do: ["  (no output captured)"]
  defp output_lines(_run), do: ["  (output not available)"]

  defp content_lines(text), do: text |> String.split("\n") |> Enum.map(&"  #{&1}")

  defp truncate_body(lines) when length(lines) <= @max_card_lines, do: lines

  defp truncate_body(lines) do
    Enum.take(lines, @max_card_lines) ++
      ["  … #{length(lines) - @max_card_lines} more line(s) — /export writes the full bundle"]
  end

  # `"unknowns"` (the "s" suffix stuck straight onto the literal word
  # "unknown") read like a typo, not spec-v1.md §12's intended "the word
  # unknown, never a fake zero" — the suffix only belongs on a real number.
  defp elapsed_word(nil), do: "unknown"
  defp elapsed_word(s) when is_integer(s), do: "#{s}s"

  # Optional — most agent maps won't carry it (no real stream source yet
  # feeds one), so an honest blank rather than a fake "streaming..." line
  # when it's absent.
  defp stream_tail_lines(%{stream_tail: lines}) when is_list(lines) and lines != [] do
    ["  ⋮"] ++ Enum.map(lines, &("  " <> &1))
  end

  defp stream_tail_lines(_agent), do: []

  @impl true
  def handle_key(%__MODULE__{open: nil} = state, :esc), do: {state, []}
  def handle_key(%__MODULE__{} = state, :esc), do: {%{state | open: nil}, []}
  def handle_key(%__MODULE__{} = state, _event), do: {state, []}
end
