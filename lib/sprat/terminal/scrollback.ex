defmodule Sprat.Terminal.Scrollback do
  @moduledoc """
  Bounded per-zone line buffer (`docs/design/tui-zones.md`: "Sprat owns a
  scroll buffer per zone (PgUp/PgDn, `g`/`G`, wheel)" — the mitigation for
  losing the terminal's own scrollback on the alternate screen). Every
  content zone (`Terminal.Zone` implementations) is expected to keep one of
  these in its state for whatever it lists.

  Pure data structure, no process: `append/2` bounds to `max_lines`
  (default 10,000, `:max_lines` at `new/1`), `viewport/2` reads a
  bottom-anchored window unless scrolled up, and `line_up/1`..`bottom/1`
  move that window. `search/2` finds every matching line and `next_match/1`/
  `prev_match/1` walk between them, scrolling the viewport to each.
  """

  defstruct lines: [], max_lines: 10_000, offset: 0, matches: [], match_index: -1

  @type t :: %__MODULE__{}

  def new(opts \\ []), do: %__MODULE__{max_lines: Keyword.get(opts, :max_lines, 10_000)}

  @doc "Appends one line or a list of lines. Scrolls back to the bottom, like a real terminal receiving output."
  def append(%__MODULE__{} = sb, line) when is_binary(line), do: append(sb, [line])

  def append(%__MODULE__{} = sb, new_lines) when is_list(new_lines) do
    lines = trim_to(sb.lines ++ new_lines, sb.max_lines)
    %{sb | lines: lines, offset: 0}
  end

  def clear(%__MODULE__{} = sb), do: %{sb | lines: [], offset: 0, matches: [], match_index: -1}

  @doc "Exactly `height` lines, bottom-anchored unless scrolled up by `offset`; blank-padded at the top when short."
  def viewport(%__MODULE__{} = sb, height) when height > 0 do
    total = length(sb.lines)
    bottom = max(total - sb.offset, 0)
    top = max(bottom - height, 0)
    visible = Enum.slice(sb.lines, top, bottom - top)
    List.duplicate("", max(height - length(visible), 0)) ++ visible
  end

  def line_up(%__MODULE__{} = sb), do: move(sb, 1)
  def line_down(%__MODULE__{} = sb), do: move(sb, -1)
  def half_page_up(%__MODULE__{} = sb, height), do: move(sb, max(div(height, 2), 1))
  def half_page_down(%__MODULE__{} = sb, height), do: move(sb, -max(div(height, 2), 1))
  def page_up(%__MODULE__{} = sb, height), do: move(sb, max(height - 1, 1))
  def page_down(%__MODULE__{} = sb, height), do: move(sb, -max(height - 1, 1))
  def top(%__MODULE__{} = sb), do: %{sb | offset: max(length(sb.lines) - 1, 0)}
  def bottom(%__MODULE__{} = sb), do: %{sb | offset: 0}

  defp move(%__MODULE__{} = sb, delta) do
    max_offset = max(length(sb.lines) - 1, 0)
    %{sb | offset: sb.offset |> Kernel.+(delta) |> max(0) |> min(max_offset)}
  end

  @doc "Substring search over all lines. Jumps the viewport to the first match, if any."
  def search(%__MODULE__{} = sb, ""), do: %{sb | matches: [], match_index: -1}

  def search(%__MODULE__{} = sb, needle) do
    matches =
      sb.lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _i} -> String.contains?(line, needle) end)
      |> Enum.map(&elem(&1, 1))

    %{sb | matches: matches, match_index: if(matches == [], do: -1, else: 0)} |> goto_match()
  end

  def next_match(%__MODULE__{matches: []} = sb), do: sb

  def next_match(%__MODULE__{} = sb),
    do: %{sb | match_index: rem(sb.match_index + 1, length(sb.matches))} |> goto_match()

  def prev_match(%__MODULE__{matches: []} = sb), do: sb

  def prev_match(%__MODULE__{} = sb),
    do:
      %{sb | match_index: rem(sb.match_index - 1 + length(sb.matches), length(sb.matches))}
      |> goto_match()

  defp goto_match(%__MODULE__{matches: []} = sb), do: sb

  defp goto_match(%__MODULE__{} = sb) do
    matched_line_index = Enum.at(sb.matches, sb.match_index)
    %{sb | offset: max(length(sb.lines) - 1 - matched_line_index, 0)}
  end

  defp trim_to(lines, max) when length(lines) > max, do: Enum.slice(lines, -max, max)
  defp trim_to(lines, _max), do: lines
end
