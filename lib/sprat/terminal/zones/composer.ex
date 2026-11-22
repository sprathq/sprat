defmodule Sprat.Terminal.Zones.Composer do
  @moduledoc """
  The real `❻ Composer` zone (`docs/design/tui-zones.md` zone map: "Input,
  always reachable"). Wraps the existing `Sprat.Terminal.Composer` state
  machine unchanged — every emacs chord, history, completion menu and
  bracketed-paste behaviour it already has carries over; this zone is only
  the cell-rendering and `Terminal.Zone` adapter around it.

  `handle_key/2` never itself decides INSERT vs NAV — `Terminal.Focus`
  already only forwards to a zone the keys that mode says should reach it
  (in INSERT, everything not a chord/Esc), so this module simply always
  feeds `handle_key/2` to `Composer.handle_event/2`. A submit becomes the
  `{:submit, text}` intent, same shape `Sprat.Terminal.Keybindings`/
  `Sprat.Session.Shell` already understand.
  """

  @behaviour Sprat.Terminal.Zone

  alias Sprat.Terminal.{Composer, Glyphs, Screen}

  defstruct [:composer]

  @impl true
  def id, do: :composer

  @impl true
  def title(_state), do: "Composer"

  @impl true
  def min_size, do: {20, 3}

  @impl true
  def overlay_capable?, do: false

  @impl true
  def init(opts) do
    %__MODULE__{
      composer:
        Composer.new(
          commands: Keyword.get(opts, :commands, []),
          history: Keyword.get(opts, :history, []),
          files: Keyword.get(opts, :files, [])
        )
    }
  end

  @doc "How many lines of text the composer holds — the layout sizes its box from this."
  def line_count(%__MODULE__{composer: c}), do: c |> Composer.lines() |> length()

  @doc "True when the composer has no typed text — the context `Terminal.Keybindings.dispatch/4` needs for Ctrl+C/Ctrl+D."
  def empty?(%__MODULE__{composer: c}), do: c.text == ""

  @doc """
  The open completion menu, whichever it is, as `%{matches:, selected:,
  query:}` — or `nil`. The renderer draws this; the composer's own rect has
  no room for a list.
  """
  def completions(%__MODULE__{composer: c}) do
    case Composer.menu(c) do
      %{matches: matches, selected: selected, query: query} ->
        %{
          matches: Enum.map(matches, fn {name, _desc} -> "/" <> name end),
          selected: selected,
          query: query
        }

      nil ->
        Composer.mention(c)
    end
  end

  @doc "True while the `/`-command menu or `@`-mention menu is open — same context need as `empty?/1`."
  def menu_open?(%__MODULE__{composer: c}),
    do: Composer.menu(c) != nil or Composer.mention(c) != nil

  @doc "Clears typed text (Ctrl+C with unsent text — spec §10 Keybindings: `:clear_composer`)."
  def clear(%__MODULE__{composer: c} = state),
    do: %{
      state
      | composer: %{c | text: "", cursor: 0, pastes: %{}, history_index: nil, draft: nil}
    }

  @impl true
  def render(%__MODULE__{composer: composer}, rect, focused?, _frame) do
    border_style =
      if focused?, do: %{fg: :cyan, bg: nil, attrs: [:bright]}, else: Screen.default_style()

    inner_w = max(rect.w - 2, 1)
    {cursor_row, cursor_col} = Composer.cursor_position(composer)

    # The box is `rect.h` rows including both borders, so only `rect.h - 2`
    # rows of text fit. Rendering every line regardless wrote past the rect —
    # a three-line paste produced five rows in a three-row box and tore the
    # layout apart, after which the UI stopped repainting entirely.
    max_rows = max(rect.h - 2, 1)
    all_lines = Composer.lines(composer)
    {visible, first_row} = visible_rows(all_lines, cursor_row, max_rows)

    text_lines =
      visible
      |> Enum.with_index(first_row)
      |> Enum.map(fn {line, row} ->
        prefix = if row == 0, do: "> ", else: ""
        # 1 leading space (below) + the "> " prefix on row 0.
        avail = max(inner_w - 1 - String.length(prefix), 1)
        col = if row == cursor_row, do: cursor_col, else: 0
        prefix <> scroll_window(line, col, avail)
      end)

    # Only spend a row on the "more" note when there is a row to spare: in a
    # three-row box (one row of text) the text itself matters more than the
    # count of what is hidden.
    text_lines =
      if length(all_lines) > max_rows and max_rows >= 2 do
        hidden = length(all_lines) - max_rows + 1
        List.replace_at(text_lines, -1, "… +#{hidden} more line(s)")
      else
        text_lines
      end

    ascii? = Glyphs.ascii?()
    top = Screen.text_cells(border(:top, rect.w, focused?, ascii?), rect.w, border_style)
    bottom = Screen.text_cells(border(:bottom, rect.w, ascii?), rect.w, border_style)

    {_tl, _tr, _bl, _br, _h, v} = Glyphs.box_glyphs(ascii?)

    body =
      Enum.map(text_lines, fn line ->
        cells = Screen.text_cells(" " <> line, inner_w, Screen.default_style())
        [{v, border_style}] ++ cells ++ [{v, border_style}]
      end)

    body = Enum.map(body, &Enum.take(&1, rect.w))
    [top] ++ body ++ [bottom]
  end

  # Horizontal scroll (design's "Multi-line composer": wrap or scroll,
  # following the cursor) — keeps a line longer than the box wide enough
  # to show fully invisible-but-typed instead of hard-cutting it at the
  # border. `col` is a grapheme index (the composer's own cursor unit
  # throughout — see `Composer.cursor_position/1`), so this is a grapheme
  # window, same unit the rest of the composer already reasons in.
  defp scroll_window(line, col, avail) do
    graphemes = String.graphemes(line)
    len = length(graphemes)

    if len <= avail do
      line
    else
      start = min(max(col - avail + 1, 0), len - avail)
      graphemes |> Enum.slice(start, avail) |> Enum.join()
    end
  end

  # Keep the caret's row on screen: scroll the window down as the text grows
  # past the box rather than drawing rows that do not fit.
  defp visible_rows(lines, cursor_row, max_rows) do
    count = length(lines)

    if count <= max_rows do
      {lines, 0}
    else
      first = cursor_row |> min(count - max_rows) |> max(0)
      {Enum.slice(lines, first, max_rows), first}
    end
  end

  defp border(:top, w, focused?, ascii?) do
    {tl, tr, _bl, _br, h, _v} = Glyphs.box_glyphs(ascii?)
    inner = max(w - 2, 0)

    label =
      if focused?, do: " #{Glyphs.focus_marker(ascii?)} Composer ", else: ""

    dashes = max(inner - String.length(label), 0)
    tl <> label <> String.duplicate(h, dashes) <> tr
  end

  defp border(:bottom, w, ascii?) do
    {_tl, _tr, bl, br, h, _v} = Glyphs.box_glyphs(ascii?)
    bl <> String.duplicate(h, max(w - 2, 0)) <> br
  end

  @doc """
  Replaces the `@`-completion file list. Scanning a project takes hundreds of
  milliseconds even after skipping build directories, so the renderer starts
  with an empty list and fills it from a background walk rather than delaying
  the first paint.
  """
  def set_files(%__MODULE__{composer: composer} = state, files) when is_list(files),
    do: %{state | composer: Composer.set_files(composer, files)}

  @impl true
  def handle_key(%__MODULE__{composer: composer} = state, event) do
    case Composer.handle_event(composer, event) do
      {:ok, composer} -> {%{state | composer: composer}, []}
      {:submit, text, composer} -> {%{state | composer: composer}, [{:submit, text}]}
    end
  end
end
