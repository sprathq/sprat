defmodule Sprat.Roadmap.Parser.Pause do
  @moduledoc """
  `docs/PAUSE.md`, the handover `/pause` writes (spec-v4 §5.1, source 2). Pure.

  The real files share a shape:

      # Paused 2026-09-13 12:46 BST · chc-rails          (or "# Handover: 9 Nov 2026 …")
      ## Read this first
      ## Repository state                               (or "## State")
      ## Resume in this order                           (or "## Continue, in order")
      1. **Ask the user …** and act on the answers. [user]
      ## In progress / Open decisions / Rulings already made / Deferred and blocked / Do not

  Later sessions append `## Done since the pause (2026-10-29)` sections; the
  newest heading date is `updated_on`.

  The ordered list under the resume heading becomes the items: the first one
  not blocked is `:active`, the rest `:todo`, and an item that says it is
  blocked is `:blocked` with that sentence as the reason. A trailing role tag
  (`[user]`, `[plan]`) is dropped from the text.
  """

  alias Sprat.Observer.Model.Item
  alias Sprat.Roadmap.Markdown, as: Md

  @resume_re ~r/\b(resume|continue|next steps?|next actions?|what to do next|pick up|up next)\b/i
  @state_re ~r/^(repository state|repo state|state|state of the repo(sitory)?)\b/i
  @blocked_re ~r/(?:^|[.;]\s+|—\s*)(blocked\b.*?(?:\.(?=\s|$)|$))/i

  @type result :: %{
          title: String.t() | nil,
          written_on: Date.t() | nil,
          updated_on: Date.t() | nil,
          repo_state: String.t() | nil,
          items: [Item.t()]
        }

  @spec parse(String.t(), keyword()) :: result()
  def parse(text, opts \\ []) do
    source = Keyword.get(opts, :source)
    lines = Md.lines(text)
    sections = sections(lines)

    {title, written_on} =
      case Enum.find(sections, &(&1.level == 1)) do
        nil -> {nil, nil}
        h1 -> {Md.clean(h1.title), Md.find_date(h1.title)}
      end

    heading_dates =
      sections
      |> Enum.flat_map(&Md.all_dates(&1.title))
      |> Enum.concat(List.wrap(written_on))

    updated_on = Enum.max(heading_dates, Date, fn -> nil end)

    resume =
      Enum.find(sections, &(&1.level >= 2 and Regex.match?(@resume_re, Md.clean(&1.title))))

    repo = Enum.find(sections, &(&1.level >= 2 and Regex.match?(@state_re, Md.clean(&1.title))))

    %{
      title: title,
      written_on: written_on,
      updated_on: updated_on,
      repo_state: repo && repo_state(repo.lines),
      items: if(resume, do: items(resume.lines, source), else: [])
    }
  end

  # Splits into heading sections; each carries the non-heading lines up to the next heading.
  defp sections(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case not line.fence? and Md.heading(line.text) do
        {level, htext} ->
          [%{level: level, title: htext, n: line.n, lines: []} | acc]

        _ ->
          case acc do
            [] -> acc
            [cur | rest] -> [%{cur | lines: [line | cur.lines]} | rest]
          end
      end
    end)
    |> Enum.map(&%{&1 | lines: Enum.reverse(&1.lines)})
    |> Enum.reverse()
  end

  defp repo_state(lines) do
    lines
    |> Enum.map_join("\n", & &1.text)
    |> String.trim()
    |> case do
      "" -> nil
      text -> Md.truncate(text, 2000)
    end
  end

  defp items(lines, source) do
    entries = list_entries(lines)

    entries
    |> Enum.map(fn {n, raw} ->
      {lead_tag, text} = leading_tag(raw)
      done? = lead_tag != nil and Regex.match?(~r/^(done|shipped|finished)\b/i, lead_tag)
      cleaned = Md.clean(text) |> strip_tag()

      blocked =
        case Regex.run(@blocked_re, cleaned) do
          [_, sentence] when not done? -> sentence |> String.trim() |> Md.truncate(160)
          _ -> nil
        end

      %Item{
        id: nil,
        text: text |> strip_tag() |> Sprat.Roadmap.Parser.Plan.label() |> strip_tag(),
        state:
          cond do
            done? -> :done
            blocked -> :blocked
            true -> :todo
          end,
        blocked_reason: blocked,
        source: source,
        source_line: n,
        hints: Regex.scan(~r/`([^`\s]+\.md)`/, text) |> Enum.map(fn [_, p] -> p end)
      }
    end)
    |> activate_first()
  end

  # Top-level numbered items (or bullets when there are none), with their
  # continuation lines folded into the text.
  defp list_entries(lines) do
    numbered =
      for %{fence?: false, text: t, n: n} <- lines,
          {indent, _num, text} <- List.wrap(Md.numbered(t)),
          indent <= 1,
          do: {n, text}

    starts =
      if numbered != [] do
        numbered
      else
        for %{fence?: false, text: t, n: n} <- lines,
            {indent, text} <- List.wrap(Md.bullet(t)),
            indent <= 1,
            do: {n, text}
      end

    start_ns = Enum.map(starts, &elem(&1, 0))

    Enum.map(Enum.with_index(starts), fn {{n, text}, i} ->
      next = Enum.at(start_ns, i + 1)

      continuation =
        lines
        |> Enum.filter(fn l -> l.n > n and (next == nil or l.n < next) and not l.fence? end)
        |> Enum.take_while(fn l -> String.trim(l.text) != "" and Md.heading(l.text) == nil end)
        |> Enum.reject(fn l -> Md.bullet(l.text) != nil end)
        |> Enum.map_join(" ", &String.trim(&1.text))

      {n, String.trim(text <> " " <> continuation)}
    end)
  end

  # A leading `[user]` / `[done 2026-11-06 on prod]` tag: returns {tag, rest}.
  defp leading_tag(text) do
    case Regex.run(~r/^\s*\[([^\]\n]{1,80})\]\s*(.*)$/s, text) do
      [_, tag, rest] -> {tag, rest}
      _ -> {nil, text}
    end
  end

  defp strip_tag(text), do: String.replace(text, ~r/\s*\[[a-z][a-z \-]*\]\s*$/i, "")

  defp activate_first(items) do
    case Enum.find_index(items, &(&1.state == :todo)) do
      nil -> items
      i -> List.update_at(items, i, &%{&1 | state: :active})
    end
  end
end
