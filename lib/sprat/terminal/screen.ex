defmodule Sprat.Terminal.Screen do
  @moduledoc """
  Alternate-screen lifecycle and a damage-tracked cell buffer for the zoned
  UI. This is the pure core the design doc (`docs/design/tui-zones.md`,
  "Implementation" table) calls `Terminal.Screen`: everything here is data
  in, data/iodata out — no process, no IO. `Terminal.ZonedRenderer` is the
  process that owns one of these and is the sole writer of the bytes this
  module produces.

  ## Grid shape

  A frame is `%{row_index => row}`, `row` a list of exactly `cols` cells.
  A cell is either `{grapheme, style}` (a one- or two-column-wide grapheme,
  `style` a map `%{fg:, bg:, attrs:}`, any key `nil`/`[]` for "default") or
  the atom `:cont` — the second column of a wide grapheme. `:cont` is never
  drawn on its own; `text_cells/3` is the only place that produces one, and
  `diff/4` always pulls a changed `:cont` cell's lead column into the same
  write so a wide character is never split across two writes (or two
  frames) — the acceptance criterion in the build brief.

  The very last cell of the very last row is never included in a diff:
  writing to it can push a real terminal into a scroll, which would
  silently corrupt every row above (same class of bug the inline
  renderer's "never fill exactly `cols`" rule guards against — see
  `docs/phase0/03-terminal-spike.md`).
  """

  alias Sprat.Terminal.Width

  @type style :: %{
          optional(:fg) => atom() | nil,
          optional(:bg) => atom() | nil,
          optional(:attrs) => [atom()]
        }
  @type cell :: {String.t(), style()} | :cont
  @type frame :: %{non_neg_integer() => [cell()]}

  @default_style %{fg: nil, bg: nil, attrs: []}

  def default_style, do: @default_style

  @doc "A blank `cols`x`rows` frame."
  def blank(cols, rows) when cols > 0 and rows > 0 do
    row = blank_row(cols)
    for r <- 0..(rows - 1), into: %{}, do: {r, row}
  end

  def blank_row(cols), do: List.duplicate({" ", @default_style}, cols)

  @doc """
  Lay `text` out as exactly `width` cells, one grapheme per column (two for
  a wide grapheme, followed by `:cont`), truncated to fit and padded with
  blanks in `style`. A wide grapheme that would land exactly on the last
  column is dropped (replaced by a blank) rather than split.

  ANSI SGR escape codes (`\\e[...m`) in `text` are stripped first, not laid
  out as cells: a cell's style is carried in `style` (the `{grapheme,
  style}` shape this whole module is built on — see moduledoc), so an
  escape byte has no business becoming a grapheme of its own. Left
  un-stripped, every byte of e.g. `Sprat.Terminal.Markdown`'s
  `"\\e[1m\\e[36m## heading\\e[0m"` (Markdown was written for the old
  inline renderer, which just `IO.write/2`s such a string as-is — ANSI
  baked in is correct there) counted as one real column of width, so a
  9-byte escape sequence at the front of a heading pushed the real text 9
  columns right of where this module's own tracked frame thought it was —
  confirmed with a real tmux capture of a streamed Markdown heading
  rendering as `"##          heading text"`, and, on the terminal actually
  interpreting those bytes as the escape sequence they are (zero columns,
  not nine), every write after it on the row landing further and further
  from the diff's intended column. Root cause of the "streamed Markdown
  corruption" defect — not `Screen.diff/4`'s cell-by-cell comparison
  logic, which was already correct once fed a correct frame.
  """
  def text_cells(text, width, style \\ @default_style) when is_binary(text) and width >= 0 do
    {cells, _used} =
      text
      |> Width.strip_ansi()
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
        gw = Width.grapheme_width(g)

        cond do
          used + gw > width -> {:halt, {acc, used}}
          gw == 2 -> {:cont, {[:cont, {g, style} | acc], used + 2}}
          true -> {:cont, {[{g, style} | acc], used + 1}}
        end
      end)

    cells = Enum.reverse(cells)
    pad = List.duplicate({" ", style}, max(width - length(cells), 0))
    cells ++ pad
  end

  @doc "Places `rows` (each already exactly `rect.w` cells) into `frame` at `rect.x`,`rect.y`, clipped to the frame."
  def put_rows(frame, %{x: x, y: y, w: w}, rows) when is_map(frame) do
    frame_rows = map_size(frame)

    rows
    |> Enum.with_index()
    |> Enum.reduce(frame, fn {row_cells, i}, frame ->
      row_index = y + i

      if row_index >= 0 and row_index < frame_rows do
        splice(frame, row_index, x, Enum.take(row_cells, w))
      else
        frame
      end
    end)
  end

  defp splice(frame, row_index, x, cells) do
    Map.update!(frame, row_index, fn row ->
      cols = length(row)
      {before, rest} = Enum.split(row, max(x, 0))
      {_dropped, after_} = Enum.split(rest, length(cells))
      spliced = before ++ cells ++ after_
      spliced |> Enum.take(cols) |> pad_row(cols)
    end)
  end

  defp pad_row(row, cols) when length(row) < cols,
    do: row ++ List.duplicate({" ", @default_style}, cols - length(row))

  defp pad_row(row, _cols), do: row

  @doc """
  Runs of changed cells between two frames, as `{row, start_col, cells}` —
  the only thing `to_ansi/1` (or a test double) needs to reproduce `new`
  exactly starting from `old`. Never touches the frame's last cell.
  """
  def diff(old, new, cols, rows) do
    last_row = rows - 1

    for row <- 0..(rows - 1),
        old_row = Map.get(old, row, blank_row(cols)),
        new_row = Map.get(new, row, blank_row(cols)),
        run <- diff_row(row, old_row, new_row, cols, row == last_row) do
      run
    end
  end

  defp diff_row(row, old_row, new_row, cols, last_row?) do
    old_a = List.to_tuple(old_row)
    new_a = List.to_tuple(new_row)

    limit = if last_row?, do: cols - 2, else: cols - 1

    0..max(min(limit, cols - 1), -1)
    |> Enum.filter(&(elem(old_a, &1) != elem(new_a, &1)))
    |> extend_for_wide(new_a, cols)
    |> Enum.sort()
    |> Enum.uniq()
    |> group_runs()
    |> Enum.map(fn idxs -> {row, hd(idxs), Enum.map(idxs, &elem(new_a, &1))} end)
  end

  defp extend_for_wide(idxs, new_a, cols) do
    Enum.flat_map(idxs, fn i ->
      cond do
        elem(new_a, i) == :cont and i > 0 -> [i - 1, i]
        i < cols - 1 and wide_lead?(elem(new_a, i)) -> [i, i + 1]
        true -> [i]
      end
    end)
  end

  defp wide_lead?({g, _style}), do: Width.grapheme_width(g) == 2
  defp wide_lead?(_), do: false

  defp group_runs([]), do: []

  defp group_runs(sorted) do
    Enum.reduce(sorted, [], fn i, acc ->
      case acc do
        [[last | _] = current | rest] when i == last + 1 -> [[i | current] | rest]
        _ -> [[i] | acc]
      end
    end)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
  end

  @doc "ESC sequence to enter the alternate screen and hide the cursor."
  def enter_alt_screen, do: "\e[?1049h\e[?25l"

  @doc "ESC sequence to leave the alternate screen and show the cursor."
  def leave_alt_screen, do: "\e[?25h\e[?1049l"

  @doc """
  ESC sequence to clear the whole physical screen and home the cursor.
  Needed on resize, and only there: diffing against a merely-*tracked*
  blank frame is not enough, because a diff only writes cells where the
  new frame differs from the old — a cell that's blank in both never gets
  an actual space written to it, even if the real terminal still shows
  stale content there from before the resize (the terminal's own reflow
  is not guaranteed to clear what falls outside the new dimensions, and
  in practice doesn't always — found by resizing a live pane and seeing
  the old composer box survive under the new, composer-less single-zone
  layout). An explicit clear is the only way to guarantee what's on
  screen actually matches a blank tracked frame.
  """
  def clear_screen, do: "\e[2J\e[H"

  @doc "Renders `diff/4`'s runs to a single ANSI-writable binary: cursor-position + styled text per run."
  def to_ansi(runs, opts \\ []) do
    color? = Keyword.get(opts, :color?, true)

    {iodata, _style} =
      Enum.reduce(runs, {[], nil}, fn {row, col, cells}, {acc, last_style} ->
        {text, last_style} = render_cells(cells, last_style, color?)
        {[acc, "\e[#{row + 1};#{col + 1}H", text], last_style}
      end)

    IO.iodata_to_binary([iodata, if(color?, do: IO.ANSI.reset(), else: "")])
  end

  defp render_cells(cells, last_style, color?) do
    Enum.reduce(cells, {[], last_style}, fn
      :cont, {acc, style} ->
        {acc, style}

      {ch, style}, {acc, last_style} ->
        sgr = if color? and style != last_style, do: sgr_for(style), else: ""
        {[acc, sgr, ch], style}
    end)
  end

  defp sgr_for(style) do
    fg = style[:fg] && apply(IO.ANSI, style[:fg], [])
    bg = style[:bg] && apply(IO.ANSI, background_fun(style[:bg]), [])
    attrs = Enum.map(style[:attrs] || [], &apply(IO.ANSI, &1, []))
    IO.iodata_to_binary([IO.ANSI.reset(), fg || "", bg || "", attrs])
  end

  defp background_fun(color), do: String.to_atom("#{color}_background")
end
