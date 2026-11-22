defmodule Sprat.Terminal.Zones.Conversation do
  @moduledoc """
  `❸ Conversation` (`docs/design/tui-zones.md` zone map): user messages and
  finished agent output, already rendered as Markdown by
  `Sprat.Session.Render`/`Sprat.Terminal.Transcript`/`Sprat.Terminal.Markdown`
  upstream — this zone only owns the scrollable buffer those lines land in
  (same shape as `Zones.Placeholder`, this codebase's copy-the-pattern
  reference) and is never itself responsible for Markdown rendering.

  Default focus zone (`Terminal.Focus.new/0` starts on index 2, which is
  `:conversation` in `Terminal.Layout.zone_ids/0`).
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Scrollback, ZoneFrame}

  defstruct name: "Conversation", scrollback: nil

  @impl true
  def id, do: :conversation

  @impl true
  def title(%__MODULE__{name: name}), do: name

  @impl true
  def min_size, do: {30, 6}

  @impl true
  def overlay_capable?, do: true

  @impl true
  def init(opts) do
    %__MODULE__{name: Keyword.get(opts, :name, "Conversation"), scrollback: Scrollback.new()}
  end

  @doc "Appends already-rendered transcript lines (what `commit/2` receives)."
  def append(%__MODULE__{} = state, lines) when is_list(lines) do
    %{state | scrollback: Scrollback.append(state.scrollback, lines)}
  end

  # First-run hint (task brief: "a brand-new real session shows an
  # entirely empty Conversation zone with no hint what to do") — rendered
  # only, never appended via `append/2`, so it can never end up in the
  # stored transcript and disappears the moment a real block lands
  # (`state.scrollback.lines == []` is exactly "nothing has ever landed
  # here yet").
  @first_run_hint [
    "Sprat plans and runs small research/analysis missions with you.",
    "",
    "Type what you want done below and press Enter to start.",
    "Press ? for the full key list."
  ]

  @impl true
  def render(%__MODULE__{scrollback: %{lines: []}} = state, rect, focused?, _frame) do
    lines =
      Scrollback.viewport(
        Scrollback.append(state.scrollback, @first_run_hint),
        max(rect.h - 2, 1)
      )

    ZoneFrame.wrap(state.name, focused?, rect, lines)
  end

  def render(%__MODULE__{} = state, rect, focused?, _frame) do
    lines = Scrollback.viewport(state.scrollback, max(rect.h - 2, 1))
    ZoneFrame.wrap(state.name, focused?, rect, lines)
  end

  @impl true
  def handle_key(%__MODULE__{} = state, event) do
    case event do
      :up -> {scroll(state, &Scrollback.line_up/1), []}
      :down -> {scroll(state, &Scrollback.line_down/1), []}
      :page_up -> {scroll(state, &Scrollback.page_up(&1, 20)), []}
      :page_down -> {scroll(state, &Scrollback.page_down(&1, 20)), []}
      :top -> {scroll(state, &Scrollback.top/1), []}
      :bottom -> {scroll(state, &Scrollback.bottom/1), []}
      _other -> {state, []}
    end
  end

  defp scroll(state, fun), do: %{state | scrollback: fun.(state.scrollback)}
end
