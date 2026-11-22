defmodule Sprat.Terminal.Layout do
  @moduledoc """
  Pure breakpoint layout (`docs/design/tui-zones.md` "Responsive layout"):
  `compute/3` is a function of terminal size and the current focus only —
  `{width, height, layout_state} -> %{zone_id => rect}` — no process, no
  side effect, snapshot-testable with no terminal.

  Zone ids are the six from the design's zone map: `:mission`, `:agents`,
  `:conversation`, `:inspector`, `:detail`, `:composer`. `:footer` is a rect
  too (not a zone — it never takes focus).

  A zone that would render below its `min_size/0` (from `Terminal.Zone`) is
  never placed with a too-small rect: it's dropped from `:zones` and added
  to `:overlays` instead, exactly as the design's breakpoint table
  describes ("Zones never shrink below a legible minimum; they drop to
  overlay instead").
  """

  @type rect :: %{x: non_neg_integer(), y: non_neg_integer(), w: pos_integer(), h: pos_integer()}
  @type layout :: %{
          breakpoint: :wide | :medium | :narrow | :single,
          zones: %{atom() => rect()},
          overlays: [atom()],
          footer: rect()
        }

  @footer_h 1
  @composer_h 3
  @composer_max_h 8
  @header_strip_h 3

  @min_sizes %{
    mission: {18, 6},
    agents: {18, 4},
    conversation: {30, 6},
    inspector: {18, 6},
    detail: {18, 4},
    composer: {20, @composer_h}
  }

  def min_size(zone_id), do: Map.fetch!(@min_sizes, zone_id)

  @doc "Rows the composer box needs for `lines` of text, bounded by the screen."
  def composer_height(lines, rows) when is_integer(lines) do
    wanted = max(lines, 1) + 2
    ceiling = min(@composer_max_h, max(div(rows, 3), @composer_h))
    wanted |> max(@composer_h) |> min(ceiling)
  end

  @doc """
  `layout_state` carries what's needed beyond raw size: `:focused` (the
  zone id used to pick which single zone fills the screen under the
  `< 80 cols or < 24 rows` breakpoint).
  """
  def compute(cols, rows, layout_state \\ %{}) when cols > 0 and rows > 0 do
    focused = Map.get(layout_state, :focused, :conversation)
    footer = %{x: 0, y: rows - @footer_h, w: cols, h: @footer_h}

    # The composer grows with its content instead of clipping it: a
    # three-line paste in a fixed three-row box left the caret on the last
    # line with everything above it invisible. Bounded so it can never eat
    # the conversation.
    composer_h = composer_height(Map.get(layout_state, :composer_lines, 1), rows)
    content_h = max(rows - @footer_h - composer_h, 1)
    composer = %{x: 0, y: rows - @footer_h - composer_h, w: cols, h: composer_h}

    {breakpoint, zones} =
      cond do
        cols < 80 or rows < 24 -> single_zone(cols, rows, footer, focused)
        cols >= 120 -> three_column(cols, content_h)
        cols >= 100 -> two_column(cols, content_h)
        true -> single_column(cols, content_h)
      end

    zones = if breakpoint == :single, do: zones, else: Map.put(zones, :composer, composer)

    # The narrow breakpoint's Mission "header strip" is a deliberately
    # compact *summary* rendering, not the zone at its normal size — the
    # design calls it out explicitly ("collapsible header strip") as
    # distinct from Mission's usual min_size. Exempting it from the
    # min-size check is what makes the strip actually appear instead of
    # silently overlaying itself away at every narrow width (found by
    # running the demo in tmux at 90x30 — no automated test caught it,
    # since none had checked *content*, only that some zone was placed).
    {exempt, checked} =
      if breakpoint == :narrow, do: Map.split(zones, [:mission]), else: {%{}, zones}

    placed = Map.merge(exempt, drop_undersized(checked))
    overlays = zone_ids() -- Map.keys(placed)

    %{breakpoint: breakpoint, zones: placed, overlays: overlays, footer: footer}
  end

  # -- >= 120: three columns: [mission/agents] [conversation] [inspector/detail] --

  defp three_column(cols, content_h) do
    # 26, not 22: every zone now draws its own border (`Terminal.ZoneFrame`)
    # which eats 2 columns of interior width — 22 was tuned before borders
    # existed and left barely any room for a role glyph + label + state
    # glyph + word side by side (found by capturing a real tmux pane and
    # seeing state words truncated to one or two letters).
    # 30/28, not 26: Agents' two-line card (role + instance + state word +
    # elapsed on line 1) still needs more room than 26 gives once the
    # border and gutter column are accounted for (found via a real tmux
    # capture: "Researcher·1 ⋯ too…" was still being cut mid-word).
    left_w = 30
    right_w = 28
    center_w = max(cols - left_w - right_w - 2, 10)
    mission_h = max(div(content_h * 2, 5), 4)
    agents_h = max(content_h - mission_h, 3)
    inspector_h = max(div(content_h * 3, 5), 4)
    detail_h = max(content_h - inspector_h, 3)

    zones = %{
      mission: %{x: 0, y: 0, w: left_w, h: mission_h},
      agents: %{x: 0, y: mission_h, w: left_w, h: agents_h},
      conversation: %{x: left_w + 1, y: 0, w: center_w, h: content_h},
      inspector: %{x: left_w + center_w + 2, y: 0, w: right_w, h: inspector_h},
      detail: %{x: left_w + center_w + 2, y: inspector_h, w: right_w, h: detail_h}
    }

    {:wide, zones}
  end

  # -- 100..119: two columns: [mission/agents] [conversation]; inspector/detail overlay --

  defp two_column(cols, content_h) do
    left_w = 28
    center_w = max(cols - left_w - 1, 10)
    mission_h = max(div(content_h * 2, 5), 4)
    agents_h = max(content_h - mission_h, 3)

    zones = %{
      mission: %{x: 0, y: 0, w: left_w, h: mission_h},
      agents: %{x: 0, y: mission_h, w: left_w, h: agents_h},
      conversation: %{x: left_w + 1, y: 0, w: center_w, h: content_h}
    }

    {:medium, zones}
  end

  # -- 80..99: single column conversation, mission/agents collapsed to a header strip --

  defp single_column(cols, content_h) do
    strip_h = min(@header_strip_h, max(content_h - 4, 0))
    conv_h = max(content_h - strip_h, 4)

    zones =
      if strip_h > 0 do
        %{
          mission: %{x: 0, y: 0, w: cols, h: strip_h},
          conversation: %{x: 0, y: strip_h, w: cols, h: conv_h}
        }
      else
        %{conversation: %{x: 0, y: 0, w: cols, h: content_h}}
      end

    {:narrow, zones}
  end

  # -- < 80 cols or < 24 rows: one zone at a time, full screen --

  defp single_zone(cols, rows, footer, focused) do
    h = max(rows - footer.h, 1)
    {:single, %{focused => %{x: 0, y: 0, w: cols, h: h}}}
  end

  defp drop_undersized(zones) do
    Enum.reduce(zones, %{}, fn {id, rect}, placed ->
      {min_w, min_h} = Map.get(@min_sizes, id, {1, 1})
      if rect.w >= min_w and rect.h >= min_h, do: Map.put(placed, id, rect), else: placed
    end)
  end

  @doc "Every zone id this layout knows about, in the design's zone-map order."
  def zone_ids, do: [:mission, :agents, :conversation, :inspector, :detail, :composer]
end
