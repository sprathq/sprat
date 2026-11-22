defmodule Sprat.Roadmap.Parser.Spec do
  @moduledoc """
  Specs (spec-v4 §5.1, source 4): the phases of a "Build sequence" or "Phases"
  section. Pure.

  Recognised phase starts:

    * a paragraph opening with `**Phase A — Name.**`, `**Phase A: Name.**` or
      `**Phase 0: spikes (days).**`, inside a section whose heading names a
      build sequence, phases, milestones or a roadmap;
    * a heading `### Phase 1: Name` (or `— Name`) anywhere.

  A phase's top-level numbered list (up to the next phase) gives its items;
  a phase without one is a single item named after the phase. The phase id
  is the spec's own label (`A`, `0`, `1`); the builder keeps it when it is
  free. States are unknown to a spec, so every item is `:todo`.
  """

  alias Sprat.Observer.Model.{Item, Phase}
  alias Sprat.Roadmap.Markdown, as: Md

  @section_re ~r/build sequence|phases|milestones|roadmap|delivery plan|sequence|rollout/i
  @bold_phase_re ~r/^\s*\*\*\s*Phase\s+([A-Z0-9]{1,3})\b\s*[—–:.\-]?\s*(.*?)\*\*\s*(.*)$/u
  @heading_phase_re ~r/^Phase\s+([A-Z0-9]{1,3})\b\s*[—–:.\-]?\s*(.*)$/u

  @spec parse(String.t(), keyword()) :: [Phase.t()]
  def parse(text, opts \\ []) do
    source = Keyword.get(opts, :source)
    lines = Md.lines(text) |> Enum.reject(& &1.fence?)

    headings =
      for l <- lines,
          {level, htext} <- List.wrap(Md.heading(l.text)),
          do: %{n: l.n, level: level, text: htext}

    last_n = lines |> List.last() |> then(&if(&1, do: &1.n, else: 0))

    section_ranges =
      for h <- headings, Regex.match?(@section_re, Md.clean(h.text)) do
        {h.n, section_end(headings, h, last_n)}
      end

    starts =
      lines
      |> Enum.flat_map(fn l ->
        cond do
          match = Md.heading(l.text) ->
            {level, htext} = match

            case Regex.run(@heading_phase_re, Md.clean(htext)) do
              [_, label, name] ->
                [%{n: l.n, label: label, name: name, stop_level: level}]

              _ ->
                []
            end

          in_ranges?(l.n, section_ranges) ->
            case Regex.run(@bold_phase_re, l.text) do
              [_, label, name, _rest] ->
                [%{n: l.n, label: label, name: Md.clean(name), stop_level: nil}]

              _ ->
                []
            end

          true ->
            []
        end
      end)

    starts
    |> Enum.with_index()
    |> Enum.map(fn {start, i} ->
      next_start = Enum.at(starts, i + 1)
      stop = phase_end(start, next_start, headings, section_ranges, last_n)

      body = Enum.filter(lines, &(&1.n > start.n and &1.n < stop))
      title = phase_title(start)

      items =
        case numbered_items(body) do
          [] ->
            [%Item{id: nil, text: title, state: :todo, source: source, source_line: start.n}]

          nums ->
            Enum.map(nums, fn {n, text} ->
              %Item{
                id: nil,
                text: Md.short(text, 140),
                state: :todo,
                source: source,
                source_line: n
              }
            end)
        end

      %Phase{id: start.label, title: title, source: source, items: items}
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp phase_title(%{label: label, name: name}) do
    name = name |> Md.clean() |> String.trim() |> String.trim_trailing(".") |> String.trim()
    if name == "", do: "Phase #{label}", else: Md.truncate(name, 100)
  end

  defp section_end(headings, h, last_n) do
    Enum.find_value(headings, last_n + 1, fn o -> if o.n > h.n and o.level <= h.level, do: o.n end)
  end

  defp in_ranges?(n, ranges), do: Enum.any?(ranges, fn {a, b} -> n > a and n < b end)

  defp phase_end(start, next_start, headings, ranges, last_n) do
    by_next = if next_start, do: next_start.n, else: last_n + 1

    by_heading =
      case start.stop_level do
        nil ->
          # a bold paragraph phase ends with its section (or any heading)
          Enum.find_value(headings, last_n + 1, fn h -> if h.n > start.n, do: h.n end)

        level ->
          Enum.find_value(headings, last_n + 1, fn h ->
            if h.n > start.n and h.level <= level, do: h.n
          end)
      end

    by_range =
      case Enum.find(ranges, fn {a, b} -> start.n > a and start.n < b end) do
        {_, b} -> b
        nil -> last_n + 1
      end

    Enum.min([by_next, by_heading, by_range])
  end

  defp numbered_items(body) do
    nums =
      for l <- body,
          {indent, _num, text} <- List.wrap(Md.numbered(l.text)),
          do: {indent, l.n, text}

    case nums do
      [] ->
        []

      _ ->
        base = nums |> Enum.map(&elem(&1, 0)) |> Enum.min()

        nums
        |> Enum.filter(&(elem(&1, 0) == base))
        |> Enum.map(fn {_indent, n, text} -> {n, continuation(body, n, text)} end)
    end
  end

  defp continuation(body, n, text) do
    more =
      body
      |> Enum.filter(&(&1.n > n))
      |> Enum.take_while(fn l ->
        String.trim(l.text) != "" and Md.numbered(l.text) == nil and Md.bullet(l.text) == nil and
          Md.heading(l.text) == nil and String.starts_with?(l.text, " ")
      end)
      |> Enum.map_join(" ", &String.trim(&1.text))

    String.trim(text <> " " <> more)
  end
end
