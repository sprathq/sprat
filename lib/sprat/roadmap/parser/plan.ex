defmodule Sprat.Roadmap.Parser.Plan do
  @moduledoc """
  Plan files (spec-v4 §5.1, source 3). Pure: text in, phases out.

  Three shapes, tried in order:

    * **Task plans** (the superpowers `writing-plans` shape): `### Task N: …`
      headings, each with `- [ ] **Step k …**` checkboxes. The file is one
      phase and each task one item, done when all its steps are ticked. Steps
      are not items: a twelve-task plan is twelve items, not sixty.
    * **Checkbox plans**: every heading with `- [ ]` / `- [x]` (also `* [ ]`,
      `1. [ ]`) under it is a phase, each top-level checkbox an item. Nested
      checkboxes fold into their parent. Checkboxes in code fences are ignored.
    * **Status lists** (only with `status_lists: true`, used for `ROADMAP.md`,
      `TODO.md`, `PLAN.md`): no checkboxes, but headings such as `Shipped`,
      `Next`, `Backlog` over bullet lists. A heading that starts with a done
      word yields done items; other status headings yield todo items.

  Every item carries `source` and `source_line`. Ids are left nil: the
  builder assigns them.
  """

  alias Sprat.Observer.Model.{Item, Phase}
  alias Sprat.Roadmap.Markdown, as: Md

  @type result :: %{
          title: String.t() | nil,
          mode: :tasks | :checkbox | :status | :none,
          phases: [Phase.t()]
        }

  @task_re ~r/^(?:Task|Chunk|Milestone)\s+\d+[a-z]?\s*[:.—–-]\s*/iu
  @done_heading ~r/^(shipped|done|completed?|finished|released|built|delivered|live)\b/i
  @status_heading ~r/^(shipped|done|completed?|finished|released|built|delivered|live|next|now|up next|todo|to do|to-do|planned|backlog|wanted|owed|designed|later|soon|in progress|doing|current|roadmap|not started|open|pending|ideas?|future)\b/i

  @spec parse(String.t(), keyword()) :: result()
  def parse(text, opts \\ []) do
    source = Keyword.get(opts, :source)
    lines = Md.lines(text)
    title = plan_title(lines, source)

    headings =
      for %{fence?: false, text: t, n: n} <- lines, h = Md.heading(t), h != nil do
        {level, htext} = h
        %{n: n, level: level, text: htext}
      end

    task_headings = Enum.filter(headings, &Regex.match?(@task_re, Md.clean(&1.text)))

    cond do
      task_headings != [] ->
        %{
          title: title,
          mode: :tasks,
          phases: tasks_phases(lines, headings, task_headings, title, source)
        }

      Enum.any?(lines, &(not &1.fence? and Md.checkbox(&1.text) != nil)) ->
        %{title: title, mode: :checkbox, phases: checkbox_phases(lines, title, source)}

      Keyword.get(opts, :status_lists, false) ->
        phases = status_phases(lines, headings, source)
        %{title: title, mode: if(phases == [], do: :none, else: :status), phases: phases}

      true ->
        %{title: title, mode: :none, phases: []}
    end
  end

  defp plan_title(lines, source) do
    h1 =
      Enum.find_value(lines, fn
        %{fence?: false, text: t} ->
          case Md.heading(t) do
            {1, text} -> text
            _ -> nil
          end

        _ ->
          nil
      end)

    case h1 do
      nil when is_binary(source) ->
        source
        |> Path.basename(".md")
        |> String.replace(~r/^\d{4}-\d{2}-\d{2}-/, "")
        |> String.replace("-", " ")

      nil ->
        nil

      text ->
        text
        |> Md.clean()
        |> String.replace(~r/\s+Implementation\s+Plan\b/i, "")
        |> String.replace(~r/\s+Plan$/i, "")
    end
  end

  # ── tasks ────────────────────────────────────────────────────────────────

  defp tasks_phases(lines, headings, task_headings, title, source) do
    by_n = Map.new(lines, &{&1.n, &1})
    last_n = length(lines)

    items =
      Enum.map(task_headings, fn th ->
        stop =
          Enum.find_value(headings, last_n + 1, fn h ->
            if h.n > th.n and h.level <= th.level, do: h.n
          end)

        section = for n <- th.n..(stop - 1)//1, do: Map.fetch!(by_n, n)

        boxes =
          for %{fence?: false, text: t} <- section, b = Md.checkbox(t), b != nil, do: b

        # A task headed "(dropped)", "(skipped)" or struck through is not work
        # left to do; it counts as done so it never becomes the position.
        dropped? =
          Regex.match?(~r/\((dropped|skipped|cancelled|canceled|removed)\)|~~.+~~/i, th.text)

        done? =
          dropped? or (boxes != [] and Enum.all?(boxes, fn {_, checked?, _} -> checked? end))

        section_text = Enum.map_join(section, "\n", & &1.text)

        %Item{
          id: nil,
          text: th.text |> Md.clean() |> String.replace(@task_re, "") |> Md.truncate(140),
          state: if(done?, do: :done, else: :todo),
          source: source,
          source_line: th.n,
          hints: Md.commit_messages(section_text)
        }
      end)

    [%Phase{id: nil, title: title || "Plan", source: source, items: items}]
  end

  # ── checkboxes ───────────────────────────────────────────────────────────

  defp checkbox_phases(lines, title, source) do
    {phases, current} =
      Enum.reduce(lines, {[], new_section(title, nil)}, fn
        %{fence?: true}, acc ->
          acc

        %{text: t, n: n}, {done, cur} ->
          case Md.heading(t) do
            {_level, htext} ->
              {close_section(cur, done), new_section(Md.clean(htext), n)}

            nil ->
              case Md.checkbox(t) do
                nil -> {done, cur}
                {indent, checked?, text} -> {done, add_box(cur, indent, checked?, text, n)}
              end
          end
      end)

    close_section(current, phases)
    |> Enum.reverse()
    |> Enum.map(fn sec ->
      items =
        sec.items
        |> Enum.reverse()
        |> Enum.map(fn it ->
          kids = Enum.reverse(it.kids)
          done? = it.checked? or (kids != [] and Enum.all?(kids, & &1))

          %Item{
            id: nil,
            text: Md.short(it.text, 140),
            state: if(done?, do: :done, else: :todo),
            source: source,
            source_line: it.n,
            hints: Md.commit_messages(it.text)
          }
        end)

      %Phase{id: nil, title: sec.title || title || "Plan", source: source, items: items}
    end)
  end

  defp new_section(title, n), do: %{title: title, n: n, base: nil, items: []}

  defp close_section(%{items: []}, done), do: done
  defp close_section(sec, done), do: [sec | done]

  defp add_box(%{base: nil} = sec, indent, checked?, text, n),
    do: %{
      sec
      | base: indent,
        items: [%{text: text, checked?: checked?, n: n, kids: []} | sec.items]
    }

  defp add_box(%{base: base, items: [parent | rest]} = sec, indent, checked?, _text, _n)
       when indent > base do
    %{sec | items: [%{parent | kids: [checked? | parent.kids]} | rest]}
  end

  defp add_box(sec, _indent, checked?, text, n),
    do: %{sec | items: [%{text: text, checked?: checked?, n: n, kids: []} | sec.items]}

  # ── status lists ─────────────────────────────────────────────────────────

  defp status_phases(lines, headings, source) do
    by_n = Map.new(lines, &{&1.n, &1})
    last_n = length(lines)

    headings
    |> Enum.filter(&(&1.level >= 2 and Regex.match?(@status_heading, Md.clean(&1.text))))
    |> Enum.map(fn h ->
      stop =
        Enum.find_value(headings, last_n + 1, fn o ->
          if o.n > h.n and o.level <= h.level, do: o.n
        end)

      section =
        for n <- (h.n + 1)..(stop - 1)//1,
            line = Map.fetch!(by_n, n),
            not line.fence?,
            do: line

      entries =
        for %{text: t, n: n} <- section,
            e = Md.bullet(t) || numbered_as_bullet(t),
            e != nil,
            do: {elem(e, 0), elem(e, 1), n}

      base = entries |> Enum.map(&elem(&1, 0)) |> Enum.min(fn -> 0 end)
      done? = Regex.match?(@done_heading, Md.clean(h.text))

      items =
        for {indent, text, n} <- entries, indent == base do
          %Item{
            id: nil,
            text: label(text),
            state: if(done?, do: :done, else: :todo),
            source: source,
            source_line: n,
            hints: linked_docs(text)
          }
        end

      %Phase{id: nil, title: Md.clean(h.text), source: source, items: items}
    end)
    |> Enum.reject(&(&1.items == []))
  end

  defp numbered_as_bullet(t) do
    case Md.numbered(t) do
      {indent, _n, text} -> {indent, text}
      nil -> nil
    end
  end

  @doc false
  # An item label: the bold lead when the text starts with one, else the first sentence.
  def label(text) do
    case Regex.run(~r/^\s*\*\*(.+?)\*\*/, text) do
      [_, bold] when byte_size(bold) > 0 and binary_part(bold, byte_size(bold) - 1, 1) != ":" ->
        bold
        |> Md.clean()
        |> String.trim_trailing(".")
        |> String.trim_trailing(":")
        |> Md.truncate(120)

      _ ->
        Md.short(text, 120)
    end
  end

  defp linked_docs(text) do
    Regex.scan(~r/\(([^()\s]+\.md)\)/, text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end
end
