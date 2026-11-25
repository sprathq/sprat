defmodule Sprat.Terminal.Board.Style do
  @moduledoc """
  The Pass palette, glyph translation and line assembly (`docs/spec-v4.md`
  §10.7–10.8). Pure.

  Sprat paints one background only: `:row`, a faint warm band behind the
  selected row of a list (`highlight/3`), so the right-hand columns of the
  row under the cursor are easy to find. Every other role is a foreground
  colour and/or an attribute (bold, faint, reverse); the age chip is reverse
  video of a foreground role. In 16 colours and NO_COLOR there is no band,
  and the `›` marker carries the selection alone.

  A line is built from segments, `{text, style}`, where `style` is a role
  atom (`:text`, `:bright`, `:quiet`, `:rule`, `:you`, `:stuck`,
  `:progress`) or a list of one role plus modifiers (`:bold`, `:reverse`,
  `:faint`). `line/3` translates glyphs for ASCII mode, strips control
  bytes from untrusted text, truncates to the width, and emits SGR inline.
  """

  alias Sprat.Terminal.{Sanitize, Width}

  @type color :: :truecolor | :c256 | :c16 | :none
  @type ctx :: %{
          width: pos_integer(),
          height: pos_integer(),
          color: color(),
          ascii?: boolean(),
          frame: non_neg_integer()
        }
  @type style :: atom() | [atom()]
  @type seg :: {String.t(), style()}

  @truecolor %{
    text: "38;2;239;232;218",
    bright: "38;2;255;250;240;1",
    quiet: "38;2;124;116;104",
    rule: "38;2;74;68;60",
    you: "38;2;224;169;59",
    stuck: "38;2;200;67;47",
    progress: "38;2;167;194;122",
    # Claude Code's own coral: a mirrored session is Claude's, not Sprat's.
    claude: "38;2;217;119;87",
    row: "48;2;52;48;42"
  }

  @c256 %{
    text: "38;5;255",
    bright: "38;5;231;1",
    quiet: "38;5;244",
    rule: "38;5;239",
    you: "38;5;179",
    stuck: "38;5;167",
    progress: "38;5;150",
    claude: "38;5;173",
    row: "48;5;236"
  }

  @c16 %{
    text: "",
    bright: "1",
    quiet: "2",
    rule: "2",
    you: "33",
    stuck: "31",
    progress: "32",
    claude: "35",
    row: ""
  }

  # NO_COLOR: no colour codes at all, but bold and faint are attributes,
  # not colours, so hierarchy survives.
  @none %{
    text: "",
    bright: "1",
    quiet: "2",
    rule: "2",
    you: "",
    stuck: "",
    progress: "",
    claude: "",
    row: ""
  }

  @modifiers %{bold: "1", faint: "2", reverse: "7"}

  # Longest first so multi-char replacements never get split.
  @ascii [
    {"┏", "+"},
    {"┓", "+"},
    {"┗", "+"},
    {"┛", "+"},
    {"━", "="},
    {"┃", "|"},
    {"┌", "+"},
    {"┐", "+"},
    {"└", "+"},
    {"┘", "+"},
    {"╭", "+"},
    {"╮", "+"},
    {"╰", "+"},
    {"╯", "+"},
    {"─", "-"},
    {"│", "|"},
    {"▰", "#"},
    {"▱", "."},
    {"●", "*"},
    {"◌", "o"},
    {"⏸", "||"},
    {"⚠", "!"},
    {"▸", ">"},
    {"◆", "+"},
    {"✓", "v"},
    {"○", "-"},
    {"·", "."},
    {"•", "o"},
    {"▌", ">"},
    {"›", ">"},
    {"⏎", "enter"},
    {"←→", "h/l"},
    {"↑↓", "j/k"},
    {"←", "<-"},
    {"→", "->"},
    {"↑", "^"},
    {"↓", "v"},
    {"…", "..."},
    {"▏", "|"},
    {"×", "x"},
    {"“", "\""},
    {"”", "\""},
    {"‘", "'"},
    {"’", "'"},
    {"—", "-"},
    {"–", "-"}
  ]

  @doc "Builds a render context from the caller's options, with defaults."
  def ctx(opts) do
    %{
      width: max(Map.get(opts, :width, 80), 1),
      height: max(Map.get(opts, :height, 24), 1),
      color: Map.get(opts, :color, :truecolor),
      ascii?: Map.get(opts, :ascii?, false),
      frame: Map.get(opts, :frame, 0)
    }
  end

  @doc "The SGR parameter string for a style under `ctx` (\"\" for none)."
  def sgr(style, ctx) do
    palette = palette(ctx.color)

    style
    |> List.wrap()
    |> Enum.map(fn s -> Map.get(palette, s) || Map.get(@modifiers, s) || "" end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(";")
  end

  defp palette(:truecolor), do: @truecolor
  defp palette(:c256), do: @c256
  defp palette(:c16), do: @c16
  defp palette(_), do: @none

  @doc "Paints already-translated `text` with `style` (reset after)."
  def paint("", _style, _ctx), do: ""

  def paint(text, style, ctx) do
    # Plain spaces need no colour (no background is ever painted), unless
    # reversed: the age chip's padding is part of its filled shape.
    styles = List.wrap(style)
    blank? = String.trim(text, " ") == "" and :reverse not in styles and :row not in styles

    case if(blank?, do: "", else: sgr(style, ctx)) do
      "" -> text
      codes -> "\e[" <> codes <> "m" <> text <> "\e[0m"
    end
  end

  @doc """
  Cleans text for display: strips escape/control sequences (untrusted
  session and model text), folds newlines and tabs to spaces, and in ASCII
  mode swaps every known glyph for its ASCII stand-in.
  """
  def tr(nil, _ctx), do: ""

  def tr(text, ctx) when is_binary(text) do
    text
    |> Sanitize.strip()
    |> String.replace(["\n", "\t"], " ")
    |> ascii(ctx)
  end

  def tr(other, ctx), do: tr(to_string(other), ctx)

  defp ascii(text, %{ascii?: true}) do
    Enum.reduce(@ascii, text, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp ascii(text, _ctx), do: text

  @doc "Display width of `text` after translation."
  def w(text, ctx), do: Width.width(tr(text, ctx))

  @doc "The ellipsis for this context."
  def ellipsis(%{ascii?: true}), do: "..."
  def ellipsis(_), do: "…"

  @doc "Truncates (with an ellipsis) and right-pads translated `text` to exactly `width` columns."
  def fit(text, width, ctx, align \\ :left)
  def fit(_text, width, _ctx, _align) when width <= 0, do: ""

  def fit(text, width, ctx, align) do
    t = truncate(tr(text, ctx), width, ctx)
    pad = String.duplicate(" ", max(width - Width.width(t), 0))
    if align == :right, do: pad <> t, else: t <> pad
  end

  @doc "Truncates already-translated text to `width` columns with an ellipsis."
  def truncate(text, width, _ctx) when width <= 0, do: if(text == "", do: "", else: "")

  def truncate(text, width, ctx) do
    cond do
      Width.width(text) <= width -> text
      width <= Width.width(ellipsis(ctx)) -> hard_cut(text, width)
      true -> Width.truncate(text, width, ellipsis(ctx))
    end
  end

  defp hard_cut(text, width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn g, {acc, used} ->
      gw = Width.grapheme_width(g)
      if used + gw > width, do: {:halt, {acc, used}}, else: {:cont, {acc <> g, used + gw}}
    end)
    |> elem(0)
  end

  @doc "Word-wraps translated `text` to `width` columns (explicit newlines kept as breaks)."
  def wrap(nil, _width, _ctx), do: []

  def wrap(text, width, ctx) when width > 0 do
    text
    |> to_string()
    |> Sanitize.strip()
    |> String.split("\n")
    |> Enum.flat_map(fn part ->
      case String.trim(part) do
        "" -> []
        p -> Width.wrap(ascii(String.replace(p, "\t", " "), ctx), width)
      end
    end)
  end

  def wrap(_text, _width, _ctx), do: []

  @doc """
  Assembles segments into one painted line no wider than `width` columns.
  Segment text is translated (`tr/2`) first; the line is cut hard at the
  width (layouts are expected to fit already; this is the guarantee).
  """
  def line(segs, ctx, width \\ nil) do
    width = width || ctx.width

    {parts, _used} =
      Enum.reduce(segs, {[], 0}, fn
        nil, acc ->
          acc

        {text, style}, {acc, used} ->
          t = tr(text, ctx)
          room = width - used

          cond do
            room <= 0 ->
              {acc, used}

            Width.width(t) <= room ->
              {[paint(t, style, ctx) | acc], used + Width.width(t)}

            true ->
              cut = hard_cut(t, room)
              {[paint(cut, style, ctx) | acc], used + Width.width(cut)}
          end
      end)

    parts |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc "Visible width of a list of segments (after translation)."
  def segs_width(segs, ctx) do
    segs |> Enum.reject(&is_nil/1) |> Enum.map(fn {t, _} -> w(t, ctx) end) |> Enum.sum()
  end

  @doc """
  Segments cut and padded to exactly `width` columns. The segment that
  crosses the edge is truncated with an ellipsis; the rest are dropped.
  """
  def fit_segs(segs, width, ctx) do
    {acc, used} =
      segs
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce_while({[], 0}, fn {text, style}, {acc, used} ->
        t = tr(text, ctx)
        tw = Width.width(t)
        room = width - used

        cond do
          room <= 0 -> {:halt, {acc, used}}
          tw <= room -> {:cont, {[{t, style} | acc], used + tw}}
          true -> {:halt, {[{truncate(t, room, ctx), style} | acc], width}}
        end
      end)

    used = min(used, width)
    Enum.reverse(acc) ++ List.wrap(sp(width - used))
  end

  @doc """
  `left` and `right` segments on one `width`-column span: `right` flush to
  the right edge, `left` truncated to make room for it.
  """
  def lr(left, right, width, ctx) do
    right = Enum.reject(right, &is_nil/1)
    rw = segs_width(right, ctx)

    if rw >= width do
      fit_segs(right, width, ctx)
    else
      fit_segs(left, width - rw, ctx) ++ right
    end
  end

  @doc """
  The selected row of a list: its segments padded to `width` and set on the
  `:row` background, so the band runs the row's full width.
  """
  def highlight(segs, width, ctx) do
    segs
    |> fit_segs(width, ctx)
    |> Enum.map(fn {t, style} -> {t, List.wrap(style) ++ [:row]} end)
  end

  @doc "A run of spaces as a segment."
  def sp(n) when n > 0, do: {String.duplicate(" ", n), :text}
  def sp(_), do: nil

  @doc """
  A band rule: ` TITLE ─ label ─────── right ─`, `width` columns wide.
  `title` quiet, rules in the rule colour, `label`/`right` quiet.
  """
  def rule(title, ctx, opts \\ []) do
    width = Keyword.get(opts, :width, ctx.width)
    label = Keyword.get(opts, :label)
    right = Keyword.get(opts, :right)
    dim? = Keyword.get(opts, :dim?, false)
    title_style = if dim?, do: :rule, else: :quiet

    head = [{" ", :text}, {title, title_style}, {" ", :text}]
    head = if label, do: head ++ [{"─ ", :rule}, {label, :quiet}, {" ", :text}], else: head
    tail = if right, do: [{" ", :text}, {right, :quiet}, {" ─", :rule}], else: []

    used = segs_width(head, ctx) + segs_width(tail, ctx)
    fill = max(width - used, 0)
    tail = if fill == 0 and right, do: [], else: tail
    fill = if tail == [], do: max(width - segs_width(head, ctx), 0), else: fill

    line(head ++ [{String.duplicate("─", fill), :rule}] ++ tail, ctx, width)
  end

  @doc "Pads a painted line with spaces to `width` visible columns (for side-by-side columns)."
  def pad_painted(painted, width) do
    painted <> String.duplicate(" ", max(width - Width.width(painted), 0))
  end
end
