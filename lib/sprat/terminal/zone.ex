defmodule Sprat.Terminal.Zone do
  @moduledoc """
  The behaviour every content zone implements (`docs/design/tui-zones.md`
  zone map: Mission, Agents, Conversation, Inspector, Detail — stage 2 —
  plus the real `Zones.Composer` and the demo `Zones.Placeholder` shipped
  here in stage 1).

  ## Seams for stage 2

  - **Identity**: `id/0` is the atom `Terminal.Layout` and `Terminal.Focus`
    key the zone by (must be one of `Terminal.Layout.zone_ids/0`).
    `min_size/0` is the `{w, h}` below which `Terminal.Layout` drops the
    zone to an overlay instead of shrinking it. `overlay_capable?/0` says
    whether the zone can ever be shown as an overlay (all can, in this
    design — kept as an explicit callback so a future zone can opt out).
  - **Purity**: `render/4` is a pure function — `state` in, cell rows out,
    no IO, so it's snapshot-testable with no terminal (`Terminal.Screen`
    turns the returned rows into a diffable frame). Build a row with
    `Screen.text_cells/3`; every row must be exactly `rect.w` cells and
    there must be exactly `rect.h` rows (short output is treated as blank
    padding by `Terminal.Screen.put_rows/3`, but zones should still return
    the right count so snapshot tests are meaningful).
  - **Keys**: `handle_key/2` receives every key event routed to the zone —
    NAV-mode navigation once the zone has focus, or a chord's target zone
    even out of focus (e.g. `Alt+f` opening the flow overlay). Returns
    `{new_state, intents}`; an intent is any term `Terminal.ZonedRenderer`
    forwards to the session/shell layer (mirrors `Terminal.Keybindings`'s
    existing intent vocabulary — `{:submit, text}` and friends). A key the
    zone doesn't handle returns `{state, []}` — the renderer then shows the
    NAV footer hint per the design's key table ("Unhandled keys in NAV
    must not silently vanish").
  - **Session updates**: stage 2 zones receive session view-model updates
    via the optional `handle_view_update/2` callback (default: ignore) —
    the same shape `Sprat.Session.Subscriber` already forwards to the old
    `Sprat.Terminal.Renderer` (`commit/2`'s block lines, `set_live/2`'s
    view model). `Terminal.ZonedRenderer` calls it exactly where
    `Sprat.Terminal.Renderer` today calls `commit`/`set_live` — see its
    moduledoc.
  - **Requesting focus / opening Detail**: a zone asks for focus or asks
    to open something in the Detail zone by returning an intent from
    `handle_key/2` — `{:focus, zone_id}` and `{:open_detail, term}} are the
    two intents `Terminal.Focus` and `Terminal.ZonedRenderer` already
    understand; stage 2's Agents/Inspector zones emit them from `Enter`.
  - **Animation frames**: `render/4`'s last argument is the current
    `Terminal.Animate` frame counter (only advancing while something is
    running — see that module). A zone's spinner/gutter/meter animation is
    a pure function of `(state, frame)`, exactly like `Terminal.Animate`
    itself, so it can be snapshot-tested by calling `render/4` with a fixed
    frame number rather than sleeping.
  """

  alias Sprat.Terminal.Screen

  @type rect :: Sprat.Terminal.Layout.rect()
  @type state :: term()
  @type cell :: Screen.cell()

  @callback id() :: atom()
  @callback title(state()) :: String.t()
  @callback min_size() :: {pos_integer(), pos_integer()}
  @callback overlay_capable?() :: boolean()
  @callback init(keyword()) :: state()
  @callback render(state(), rect(), focused? :: boolean(), frame :: non_neg_integer()) :: [
              [cell()]
            ]
  @callback handle_key(state(), Sprat.Terminal.Keys.event()) :: {state(), [term()]}
  @callback handle_view_update(state(), term()) :: state()

  @optional_callbacks handle_view_update: 2

  @doc "Default no-op for the optional `handle_view_update/2` — most zones ignore stage-2 view models until they exist."
  def ignore_view_update(state, _view_model), do: state
end
