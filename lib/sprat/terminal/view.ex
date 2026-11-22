defmodule Sprat.Terminal.View do
  @moduledoc """
  Live-region components as pure functions `(state, width) -> [line]`:
  activity/spinner line, mission checklist, permission/question prompt,
  composer box, footer. All output already wrapped to `width - 1` columns
  (never exactly `width`, per the terminal spike's deferred-wrap finding).
  """

  alias IO.ANSI
  alias Sprat.Terminal.{Composer, Glyphs, Width}

  @spinner_frames ~w(✢ ✳ ∗ ✻ ✽)
  @ascii_spinner_frames ~w(| / - \\)

  @doc "activity: %{spinner_index:, verb:, elapsed_s:, tokens:, interruptible?: true}"
  def activity_line(activity, width, opts \\ []) do
    frames = if Glyphs.ascii?(opts), do: @ascii_spinner_frames, else: @spinner_frames
    frame = Enum.at(frames, rem(activity.spinner_index, length(frames)))
    hint = if Map.get(activity, :interruptible?, true), do: " · esc to interrupt", else: ""

    text =
      "#{frame} #{activity.verb}… (#{activity.elapsed_s}s · #{down_arrow(opts)} #{format_k(activity.tokens)} tokens#{hint})"

    Width.wrap(text, draw_width(width))
  end

  defp down_arrow(opts), do: if(Glyphs.ascii?(opts), do: "v", else: "↓")

  @doc "stages: [{label, :done | :active | :pending}]. collapses to one line when `collapsed?` is true."
  def checklist_lines(%{stages: stages} = state, width, opts \\ []) do
    ascii? = Glyphs.ascii?(opts)

    if Map.get(state, :collapsed?, false) do
      {done, total} = {Enum.count(stages, fn {_, s} -> s == :done end), length(stages)}
      [Width.truncate("  #{done}/#{total} stages complete", draw_width(width))]
    else
      Enum.flat_map(stages, fn
        {label, status, sub_lines} ->
          [checklist_line(label, status, ascii?, width) | Enum.map(sub_lines, &("    " <> &1))]

        {label, status} ->
          [checklist_line(label, status, ascii?, width)]
      end)
    end
  end

  defp checklist_line(label, status, ascii?, width) do
    Width.truncate("  #{Glyphs.checklist_marker(status, ascii?)} #{label}", draw_width(width))
  end

  @doc """
  prompt: %{title:, lines:, options:, selected:, free_text?: false}. Shared
  rendering for the permission prompt and the `ask_user` question prompt
  (numbered options, arrow-selected, plus optional free text).
  """
  def prompt_lines(prompt, width, opts \\ []) do
    ascii? = Glyphs.ascii?(opts)
    color? = Glyphs.color?(opts)
    w = draw_width(width)
    inner = max(w - 4, 10)
    {corner_tl, corner_tr, corner_bl, corner_br, horiz, side} = box_glyphs(ascii?)

    title_prefix = "#{corner_tl}#{horiz} #{prompt.title} "
    top_dashes = max(w - Width.width(title_prefix) - Width.width(corner_tr), 0)
    top = title_prefix <> String.duplicate(horiz, top_dashes) <> corner_tr
    bottom = corner_bl <> String.duplicate(horiz, w - 2) <> corner_br

    body_lines =
      prompt.lines
      |> Enum.flat_map(&Width.wrap(&1, inner))
      |> Enum.map(&(side <> " " <> pad_to(&1, inner) <> " " <> side))

    option_lines =
      prompt.options
      |> Enum.with_index()
      |> Enum.map(fn {opt, i} ->
        glyph = if i == prompt.selected, do: Glyphs.selected_marker(ascii?), else: " "
        plain = "#{glyph} #{i + 1}. #{opt}"

        content =
          if i == prompt.selected and color? do
            String.replace(plain, glyph, style(ANSI.green(), glyph), global: false)
          else
            plain
          end

        side <> " " <> pad_to(content, inner) <> " " <> side
      end)

    free_text_line =
      if Map.get(prompt, :free_text?, false) do
        [side <> " " <> pad_to("> ", inner) <> " " <> side]
      else
        []
      end

    blank = side <> " " <> pad_to("", inner) <> " " <> side
    [top] ++ body_lines ++ [blank] ++ option_lines ++ free_text_line ++ [bottom]
  end

  @doc "Bordered multi-line composer box, built from a Sprat.Terminal.Composer state."
  def composer_lines(%Composer{} = composer, width, opts \\ []) do
    ascii? = Glyphs.ascii?(opts)
    w = draw_width(width)
    inner = max(w - 4, 10)
    {corner_tl, corner_tr, corner_bl, corner_br, horiz, side} = box_glyphs(ascii?)

    top = corner_tl <> String.duplicate(horiz, w - 2) <> corner_tr
    bottom = corner_bl <> String.duplicate(horiz, w - 2) <> corner_br

    text_lines =
      composer
      |> Composer.lines()
      |> Enum.flat_map(&Width.wrap(&1, inner))

    text_lines = if text_lines == [], do: ["> "], else: prefix_first(text_lines, "> ")

    body = Enum.map(text_lines, &(side <> " " <> pad_to(&1, inner) <> " " <> side))
    [top] ++ body ++ [bottom]
  end

  defp prefix_first([first | rest], prefix), do: [prefix <> first | rest]
  defp prefix_first([], prefix), do: [prefix]

  @doc "footer: %{mode:, cost:, sources:, hint: nil}"
  def footer_lines(footer, width, opts \\ []) do
    hint = footer[:hint] || "? for shortcuts"
    marker = if Glyphs.ascii?(opts), do: ">", else: "⏵"

    text =
      "  #{marker} #{footer.mode} mode · #{footer.cost} · #{footer.sources} sources            #{hint}"

    [Width.truncate(text, draw_width(width))]
  end

  defp box_glyphs(true), do: {"+", "+", "+", "+", "-", "|"}
  defp box_glyphs(false), do: {"╭", "╮", "╰", "╯", "─", "│"}

  defp pad_to(text, width) do
    pad = max(width - Width.width(text), 0)
    text <> String.duplicate(" ", pad)
  end

  defp style(code, text), do: code <> text <> ANSI.reset()

  defp format_k(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_k(n), do: "#{n}"

  # Never draw into the last column — a line that exactly fills the
  # terminal width leaves some terminals in a "deferred wrap" state that
  # desyncs the cursor-up-N redraw math (see docs/phase0/03-terminal-spike.md).
  defp draw_width(width), do: max(width - 1, 10)
end
