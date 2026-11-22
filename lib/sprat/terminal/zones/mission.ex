defmodule Sprat.Terminal.Zones.Mission do
  @moduledoc """
  `❶ Mission` (`docs/design/tui-zones.md` zone map): stage checklist with
  per-stage elapsed time, budget meter, current mode. Fed entirely through
  `handle_view_update/2` — `Terminal.ZonedRenderer` routes `set_live/2`'s
  view model here (same `%{activity:, checklist:}` shape the old inline
  renderer already used, plus the optional `:budget`/`:mode`/`:name` keys
  this zone adds).

  Renders one of two layouts depending on the rect it's given, not on
  breakpoint metadata it doesn't have: `render_strip/2` (the narrow
  breakpoint's compact header-strip, exempted from `Terminal.Layout`'s
  min-size check) below `min_size/0`, `render_full/3` at or above it — see
  that implementation note in the design doc.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Animate, Glyphs, Screen, Theme, ZoneFrame}

  defstruct name: "Mission", activity: nil, checklist: nil, budget: nil, mode: nil

  @impl true
  def id, do: :mission

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {18, 6}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts) do
    %__MODULE__{name: Keyword.get(opts, :name, "Mission")}
  end

  @impl true
  def handle_view_update(%__MODULE__{} = state, view_model) when is_map(view_model) do
    %{
      state
      | activity: Map.get(view_model, :activity, state.activity),
        checklist: Map.get(view_model, :checklist, state.checklist),
        budget: Map.get(view_model, :budget, state.budget),
        mode: Map.get(view_model, :mode, state.mode),
        name: Map.get(view_model, :name, state.name)
    }
  end

  @impl true
  def render(%__MODULE__{} = state, rect, focused?, frame) do
    {min_w, min_h} = min_size()

    if rect.w < min_w or rect.h < min_h do
      lines = render_strip(state, rect)
      lines = Enum.take(lines, rect.h) ++ List.duplicate("", max(rect.h - length(lines), 0))
      Enum.map(lines, &Screen.text_cells(&1, rect.w, Screen.default_style()))
    else
      ZoneFrame.wrap(state.name, focused?, rect, render_full(state, frame))
    end
  end

  # -- narrow-breakpoint header strip ----------------------------------------

  defp render_strip(state, rect) do
    parts =
      [
        state.name,
        active_stage_word(state.checklist),
        budget_word(state.budget)
      ]
      |> Enum.reject(&is_nil/1)

    [Enum.join(parts, " · ")] |> Enum.take(rect.h)
  end

  # -- full layout (the title is drawn in ZoneFrame's border, not here) ------

  defp render_full(state, frame) do
    activity_lines(state.activity) ++
      checklist_lines(state.checklist, frame) ++
      [""] ++
      ["Budget"] ++
      budget_lines(state.budget) ++
      mode_lines(state.mode)
  end

  defp activity_lines(nil), do: []

  defp activity_lines(%{verb: verb} = activity) do
    ["#{verb}#{Glyphs.ellipsis(Glyphs.ascii?())} (#{Map.get(activity, :elapsed_s, 0)}s)"]
  end

  defp checklist_lines(nil, _frame), do: ["No checklist yet."]

  defp checklist_lines(%{stages: stages}, frame) do
    Enum.map(stages, fn {label, status} ->
      "#{checklist_marker(status, frame)} #{label}"
    end)
  end

  # `Theme.state/2`'s glyph is the atom `:spinner` for the running/active
  # states (the caller resolves the current frame via
  # `Terminal.Animate.spinner_frame/2` — see that function's doc) — using
  # the atom's `to_string/1` directly here printed the literal word
  # "spinner" in the checklist instead of a spinner glyph (found via a
  # tmux capture of the real demo; no pure snapshot test caught it because
  # every one of them called `render/4` with the checklist's non-:active
  # stages, or asserted on structure rather than the exact glyph text).
  defp checklist_marker(status, frame) do
    case Theme.state(checklist_state(status)).glyph do
      :spinner -> Animate.spinner_frame(frame)
      glyph -> glyph
    end
  end

  defp checklist_state(:done), do: :done
  defp checklist_state(:active), do: :active
  defp checklist_state(:failed), do: :failed
  defp checklist_state(:skipped), do: :skipped
  # A stage paused on `Orchestrator.settle_stage/13`'s `{:needs_approval,
  # ...}` clause (fetch approval) or `Mission.handle_approval/6` (the
  # Directions choice point) broadcasts its checklist entry as
  # `:waiting_on_user`, same atom the agent card already renders — falling
  # through to `:queued` here (its previous behaviour, since this clause
  # used to catch every status it didn't recognize) rendered the *dimmed
  # circle* for a stage that was actually running, which read as "not
  # started yet", the opposite of the truth. `Theme` already carries a
  # `waiting_on_user` state (glyph "?", word "waiting on you"); this just
  # stops discarding that atom before it gets there.
  defp checklist_state(:waiting_on_user), do: :waiting_on_user
  defp checklist_state(_), do: :queued

  defp active_stage_word(nil), do: nil

  defp active_stage_word(%{stages: stages}) do
    case Enum.find(stages, fn {_l, s} -> s == :active end) do
      {label, _} -> label
      nil -> nil
    end
  end

  defp budget_lines(nil), do: ["unknown — no usage recorded yet"]

  defp budget_lines(%{spent: spent, cap: cap}) when is_nil(spent) or is_nil(cap) do
    ["unknown — no usage recorded yet"]
  end

  defp budget_lines(%{spent: spent, cap: cap} = budget) do
    pct = budget_pct(spent, cap)
    ["#{dollars(spent)} / #{dollars(cap)}#{paused_suffix(budget)}", bar(pct) <> " #{pct}%"]
  end

  @doc """
  The one-line budget summary, shared with the footer so the two can never
  disagree. `nil` when no usage has been recorded: unknown is not zero
  (docs/spec-v1.md §12).
  """
  def budget_word(nil), do: nil
  def budget_word(%{spent: nil}), do: nil
  def budget_word(%{cap: nil}), do: nil

  def budget_word(%{spent: spent, cap: cap} = budget),
    do: "#{dollars(spent)}/#{dollars(cap)}#{paused_suffix(budget)}"

  # docs/spec-v1.md §12: "the mission enters `paused_budget`... the user
  # can raise the limit or export what exists" — the Orchestrator
  # broadcasts the mission's real state (`Sprat.Orchestrator`'s
  # `broadcast_budget/4`) as `:mission_status` on the same budget map, so
  # the screen agrees with the stored state instead of only a transient
  # system message. Absent on every other broadcast (`Map.get` default),
  # so untouched callers/tests keep seeing the plain "spent/cap" line.
  defp paused_suffix(budget) do
    if Map.get(budget, :mission_status) == "paused_budget", do: " — PAUSED (budget)", else: ""
  end

  defp budget_pct(spent, cap) do
    if Decimal.compare(cap, Decimal.new(0)) == :eq do
      0
    else
      spent
      |> Decimal.div(cap)
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
      |> min(100)
      |> max(0)
    end
  end

  defp bar(pct) do
    filled = div(pct * 10, 100)
    String.duplicate("▰", filled) <> String.duplicate("▱", 10 - filled)
  end

  @doc """
  Formats a real dollar amount honestly (docs/spec-v1.md §12 "honest
  measurement" — unknown stays unknown, never zero, and that same honesty
  applies to a nonzero amount rounding display to zero): a real run's
  $0.000676 call used to show as `$0.00` here and in the footer, which
  reads as "this cost nothing" when it plainly did not. A real nonzero
  amount under a cent shows as `<$0.01` instead of rounding away; `nil`
  ("unknown") is the caller's job — `budget_lines/1` and `budget_word/1`
  above only ever pass this a real `Decimal`.
  """
  def dollars(%Decimal{} = d) do
    zero = Decimal.new(0)

    cond do
      Decimal.compare(d, zero) == :eq -> "$0.00"
      Decimal.compare(Decimal.abs(d), Decimal.new("0.01")) == :lt -> "<$0.01"
      true -> "$" <> (Decimal.round(d, 2) |> Decimal.to_string())
    end
  end

  defp mode_lines(nil), do: []
  defp mode_lines(mode), do: ["", "Mode: #{mode}"]

  @impl true
  def handle_key(%__MODULE__{} = state, _event), do: {state, []}
end
