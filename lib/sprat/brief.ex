defmodule Sprat.Brief do
  @moduledoc """
  The daily brief (spec §10.10): a header line, one lowercase line per project
  (position; what moved; what is stuck; what needs a decision) and a `net:`
  line.

  Pure and deterministic, no model: every fact comes from the input, and a
  header segment whose number the input does not hold is left out rather than
  guessed (spec §12).

  Input:

  - `now` (`DateTime`), `projects` (`[%Project{}]`, archived ones skipped),
    `findings` (`[%Finding{}]`; resolved, dismissed and snoozed are ignored),
    `served` (`[%Served{}]`, already limited to the period the brief covers,
    matched to projects by `project_name`), `pm_spend` (USD, or nil).
  - Optional: `done_yesterday` (integer), `nudges` (`%{delivered: n, resolved: m}`),
    `session_names` (`%{session_id => name}`, to label session findings).

  A finding counts as **yours** when its kind is `:needs_you` or its state is
  `:escalated`; as **sprat's** when the PM is on it (`:pm_running`, `:acted`);
  `:scheduled` findings (usage limits) are waits, not stalls; the rest are stuck.
  """

  alias Sprat.Observer.Model.{Finding, Position, Project, Served}

  @ignored_states [:resolved, :dismissed, :snoozed]

  @spec compose(map()) :: String.t()
  def compose(%{now: now} = input) do
    findings =
      input
      |> Map.get(:findings, [])
      |> Enum.reject(&(&1.state in @ignored_states))

    names = Map.get(input, :session_names, %{})
    served = Map.get(input, :served, [])

    projects =
      input
      |> Map.get(:projects, [])
      |> Enum.reject(& &1.archived?)
      |> Enum.map(fn p ->
        fs = findings |> Enum.filter(&(&1.project_root == p.root)) |> Enum.sort_by(&sort_key/1)
        sv = served |> Enum.filter(&(&1.project_name == name(p))) |> newest_first()
        %{project: p, groups: group(fs), served: sv}
      end)
      |> Enum.sort_by(fn row -> {rank(row), name(row.project)} end)

    lines =
      [header(input, length(projects)), ""] ++
        Enum.map(projects, &project_line(&1, now, names)) ++
        ["", net(projects)]

    Enum.join(lines, "\n") <> "\n"
  end

  # ── header and net ───────────────────────────────────────────────────────

  defp header(input, n_projects) do
    date = input.now |> Calendar.strftime("%a %-d %b") |> String.downcase()

    segments =
      [
        "brief",
        date,
        plural(n_projects, "project"),
        case input[:done_yesterday] do
          n when is_integer(n) -> "#{plural(n, "item")} done yesterday"
          _ -> nil
        end,
        case input[:nudges] do
          %{delivered: d, resolved: r} -> "#{plural(d, "nudge")}, #{r} resolved"
          %{delivered: d} -> plural(d, "nudge")
          _ -> nil
        end,
        case input[:pm_spend] do
          s when is_number(s) -> "pm $" <> :erlang.float_to_binary(s * 1.0, decimals: 2)
          _ -> nil
        end
      ]

    segments |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp net(rows) do
    yours = rows |> Enum.map(&length(&1.groups.yours)) |> Enum.sum()
    stuck = Enum.count(rows, &(&1.groups.stuck != []))
    limited = Enum.count(rows, &(&1.groups.scheduled != []))
    moving = Enum.count(rows, &(rank(&1) == 3))

    parts =
      [
        yours > 0 && plural(yours, "decision") <> " for you",
        stuck > 0 && "#{stuck} stuck",
        limited > 0 && "#{limited} limited",
        moving > 0 && "#{moving} moving"
      ]
      |> Enum.filter(&is_binary/1)

    case parts do
      [] -> "net: nothing open"
      _ -> "net: " <> Enum.join(parts, ", ")
    end
  end

  # ── one project ──────────────────────────────────────────────────────────

  # "on course" only when something landed in the last two days; otherwise
  # say how long it has been quiet (activity is not progress).
  defp quiet_or_on_course(p, now) do
    case p.position && p.position.last_progress_at do
      %DateTime{} = at ->
        days = div(DateTime.diff(now, at), 86_400)
        if days >= 2, do: "quiet #{days}d", else: "on course"

      _ ->
        "no progress recorded"
    end
  end

  defp project_line(%{project: p, groups: g, served: served}, now, names) do
    parts =
      [position(p, now)] ++
        moved(served) ++
        Enum.map(g.stuck, &finding_text(&1, now, names)) ++
        Enum.map(g.scheduled, &finding_text(&1, now, names)) ++
        Enum.map(g.sprat, &("sprat on it: " <> finding_text(&1, now, names))) ++
        Enum.map(g.yours, &("you: " <> finding_text(&1, now, names)))

    parts =
      if rank(%{project: p, groups: g}) == 3,
        do: parts ++ [if(moved(served) != [], do: "on course", else: quiet_or_on_course(p, now))],
        else: parts

    name(p) <> ": " <> (parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("; "))
  end

  defp position(%Project{position: %Position{all_done?: true} = pos}, now) do
    case pos.last_progress_at do
      %DateTime{} = at -> "done #{age(at, now)} ago"
      _ -> "all done"
    end
  end

  defp position(%Project{position: %Position{phase_id: phase, done: d, total: t}}, _now)
       when not is_nil(phase),
       do: "#{phase} #{d}/#{t}"

  defp position(%Project{position: %Position{done: d, total: t}}, _now) when t > 0,
    do: "#{d}/#{t}"

  defp position(_project, _now), do: "no roadmap yet"

  defp moved([]), do: []
  defp moved(served), do: [served |> Enum.take(2) |> Enum.map_join(", ", & &1.text)]

  defp finding_text(%Finding{} = f, now, names) do
    label = names[f.session_id]
    text = f.summary || f.rule

    text = if label, do: "#{label} #{text}", else: text

    if f.kind == :needs_you and match?(%DateTime{}, f.first_seen_at),
      do: "#{text} (#{age(f.first_seen_at, now)})",
      else: text
  end

  # ── grouping and order ───────────────────────────────────────────────────

  defp group(findings) do
    empty = %{yours: [], sprat: [], scheduled: [], stuck: []}

    findings
    |> Enum.group_by(fn f ->
      cond do
        f.kind == :needs_you or f.state == :escalated -> :yours
        f.state in [:pm_running, :acted] -> :sprat
        f.kind == :scheduled -> :scheduled
        true -> :stuck
      end
    end)
    |> then(&Map.merge(empty, &1))
  end

  # 0 yours, 1 stuck, 2 sprat on it or limited, 3 moving, 4 done or no roadmap
  defp rank(%{project: p, groups: g}) do
    cond do
      g.yours != [] -> 0
      g.stuck != [] -> 1
      g.sprat != [] or g.scheduled != [] -> 2
      match?(%Position{all_done?: true}, p.position) -> 4
      match?(%Position{}, p.position) -> 3
      true -> 4
    end
  end

  defp sort_key(%Finding{first_seen_at: %DateTime{} = at, id: id}),
    do: {0, DateTime.to_unix(at, :microsecond), id}

  defp sort_key(%Finding{id: id}), do: {1, 0, id}

  defp newest_first(served) do
    Enum.sort_by(served, fn %Served{at: at, text: t} ->
      {-DateTime.to_unix(at, :microsecond), t}
    end)
  end

  defp name(%Project{name: name, root: root}), do: name || Path.basename(root)

  defp age(%DateTime{} = from, now) do
    secs = max(DateTime.diff(now, from), 0)

    cond do
      secs < 3600 -> "#{div(secs, 60)}m"
      secs < 48 * 3600 -> "#{div(secs, 3600)}h"
      true -> "#{div(secs, 86_400)} days"
    end
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
