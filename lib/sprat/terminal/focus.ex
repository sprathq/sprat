defmodule Sprat.Terminal.Focus do
  @moduledoc """
  The focus ring, INSERT/NAV modes, and key routing (`docs/design/tui-zones.md`
  "Focus and keys"). Pure reducer, same shape as `Terminal.Keybindings`:
  `handle_key/3` takes an event and a context and returns `{new_focus,
  action}`, never touches IO. `Terminal.ZonedRenderer` is the only caller —
  it dispatches on `action` and calls into the focused zone's
  `handle_key/2` for `{:route_zone, event}`.

  Division of labour with `Terminal.Keybindings` (reused unchanged): Esc
  (interrupt / edit-earlier), Ctrl+C (interrupt / exit), Ctrl+D (exit) and
  the Shift+Tab permission-mode cycle are still `Keybindings`'s job and are
  checked by `ZonedRenderer` *before* handing an event to this module —
  Focus only owns *zone and mode* navigation (the design's "Tab" row down
  to "`m`"), not the interrupt/exit chords already correct in the old
  renderer.

  ## Chords (work in both INSERT and NAV — the design's "escape hatch")

  `Alt+1`…`Alt+6` jump to a zone by its zone-map number; `Alt+n`/`Alt+p`
  move next/previous; `Alt+[`/`Alt+]` switch the Inspector tab; `Alt+f`
  opens the flow overlay; `Alt+v`/`Alt+V` page the *focused* zone down/up.
  These arrive as `{:alt, char}` events — see the `Terminal.Keys` addition
  this build made for them.
  """

  alias Sprat.Terminal.Layout

  defstruct ring: Layout.zone_ids(), index: 2, mode: :insert

  @type mode :: :insert | :nav
  @type action ::
          :none
          | :route_composer
          | {:route_zone, term()}
          | {:route_zone_and_mode, term(), mode()}
          | {:mode, mode()}
          | {:global, term()}

  @type t :: %__MODULE__{ring: [atom()], index: non_neg_integer(), mode: mode()}

  @doc "A fresh focus ring, starting on Conversation (index 2) in INSERT mode, as the design's mockup shows."
  def new(opts \\ []) do
    %__MODULE__{
      ring: Keyword.get(opts, :ring, Layout.zone_ids()),
      mode: Keyword.get(opts, :mode, :insert)
    }
  end

  def current(%__MODULE__{ring: ring, index: i}), do: Enum.at(ring, i)

  def next(%__MODULE__{} = f), do: %{f | index: rem(f.index + 1, length(f.ring))}
  def prev(%__MODULE__{} = f), do: %{f | index: rem(f.index - 1 + length(f.ring), length(f.ring))}

  def jump(%__MODULE__{} = f, zone_id) do
    case Enum.find_index(f.ring, &(&1 == zone_id)) do
      nil -> f
      idx -> %{f | index: idx}
    end
  end

  @doc "now_ms unused today (kept for parity with Keybindings.dispatch/4 and a likely future double-tap chord)."
  @spec handle_key(t(), Sprat.Terminal.Keys.event(), map()) :: {t(), action()}
  def handle_key(%__MODULE__{} = focus, event, _ctx \\ %{}) do
    case chord(event) do
      {:jump, n} -> {jump(focus, Enum.at(focus.ring, n - 1) || current(focus)), :none}
      :next -> {next(focus), :none}
      :prev -> {prev(focus), :none}
      {:global, intent} -> {focus, {:global, intent}}
      nil -> mode_dispatch(focus, event)
    end
  end

  # -- chords: both modes -----------------------------------------------------

  defp chord({:alt, d}) when d in ~w(1 2 3 4 5 6), do: {:jump, String.to_integer(d)}
  defp chord({:alt, "n"}), do: :next
  defp chord({:alt, "p"}), do: :prev
  defp chord({:alt, "["}), do: {:global, {:inspector_tab, :prev}}
  defp chord({:alt, "]"}), do: {:global, {:inspector_tab, :next}}
  defp chord({:alt, "f"}), do: {:global, :open_flow_overlay}
  defp chord({:alt, "s"}), do: {:global, :open_settings_overlay}
  defp chord({:alt, "d"}), do: {:global, :open_debug_overlay}
  defp chord({:alt, "v"}), do: {:global, {:page_zone, :down}}
  defp chord({:alt, "V"}), do: {:global, {:page_zone, :up}}
  defp chord(_event), do: nil

  # -- mode-specific ------------------------------------------------------------

  defp mode_dispatch(%{mode: :insert} = focus, :esc), do: {%{focus | mode: :nav}, {:mode, :nav}}
  defp mode_dispatch(%{mode: :insert} = focus, _event), do: {focus, :route_composer}

  defp mode_dispatch(%{mode: :nav} = focus, event) do
    case event do
      :tab ->
        {next(focus), :none}

      :shift_tab ->
        {prev(focus), :none}

      {:char, d} when d in ~w(1 2 3 4 5 6) ->
        {jump(focus, Enum.at(focus.ring, String.to_integer(d) - 1)), :none}

      :up ->
        {focus, {:route_zone, :up}}

      :down ->
        {focus, {:route_zone, :down}}

      {:char, "j"} ->
        {focus, {:route_zone, :down}}

      {:char, "k"} ->
        {focus, {:route_zone, :up}}

      :page_up ->
        {focus, {:route_zone, :page_up}}

      :page_down ->
        {focus, {:route_zone, :page_down}}

      {:char, "g"} ->
        {focus, {:route_zone, :top}}

      {:char, "G"} ->
        {focus, {:route_zone, :bottom}}

      {:char, " "} ->
        {focus, {:route_zone, :space}}

      :enter ->
        {%{focus | mode: :insert}, {:route_zone_and_mode, :enter, :insert}}

      {:char, "["} ->
        {focus, {:global, {:inspector_tab, :prev}}}

      {:char, "]"} ->
        {focus, {:global, {:inspector_tab, :next}}}

      :esc ->
        {jump(focus, :conversation), :none}

      {:char, "i"} ->
        {%{focus | mode: :insert}, {:mode, :insert}}

      {:char, "/"} ->
        {%{focus | mode: :insert}, {:global, :open_command_menu}}

      {:char, "f"} ->
        {focus, {:global, :open_flow_overlay}}

      {:char, "s"} ->
        {focus, {:global, :open_settings_overlay}}

      {:char, "d"} ->
        {focus, {:global, :open_debug_overlay}}

      {:char, "o"} ->
        {focus, {:global, :open_pager}}

      {:char, "m"} ->
        {focus, {:global, :toggle_mouse}}

      {:char, "?"} ->
        {focus, {:global, :help}}

      _other ->
        {focus, {:route_zone, event}}
    end
  end
end
