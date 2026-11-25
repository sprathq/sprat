defmodule Sprat.Terminal.Board do
  @moduledoc """
  The Pass (`docs/spec-v4.md` §10): one column of stacked bands, read top to
  bottom. Pure: `render/2` maps a `Sprat.Terminal.Board.View` and the
  terminal's size and capabilities to exactly `height` lines, each at most
  `width` display columns, with SGR codes inline and no background colour
  ever painted.

  Screens: the board (§10.3, with a ticket opened in place, §10.4), a
  project (§10.6) and a session's condensed transcript (§10.6). Width
  breakpoints follow §10.5: cards at 84+ columns (four at 120+, with a
  last-progress column on the line), one-line strips at 60–83, two-line
  strips and two-line project rows below 60. In a short pane served goes
  first, then the line truncates to `…N more`; the rail is never cut.
  """

  alias Sprat.Observer.Model.{Project, Session, Ticket}
  alias Sprat.Terminal.{Composer, Mascot}
  alias Sprat.Terminal.Board.{Help, Keys, Style, Tank, View}

  import Sprat.Terminal.Board.Style, only: [sp: 1]

  @card_rows 6
  @max_served 5
  @default_thresholds %{default: 15}

  @type opts :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          optional(:color) => :truecolor | :c256 | :c16 | :none,
          optional(:ascii?) => boolean(),
          optional(:frame) => non_neg_integer(),
          optional(:reduced_motion?) => boolean()
        }

  @doc "Renders the view to exactly `opts.height` lines."
  @spec render(View.t(), opts()) :: [String.t()]
  def render(%View{} = view, opts) do
    ctx =
      opts
      |> Style.ctx()
      |> Map.put(:reduced_motion?, Map.get(opts, :reduced_motion?, false))

    bottom = bottom_lines(view, ctx)
    avail = max(ctx.height - length(bottom), 0)

    body =
      cond do
        view.help? -> help_screen(view, ctx, avail)
        true -> screen(view, ctx, avail)
      end

    finalize(body, bottom, avail, ctx)
  end

  defp screen(%View{screen: :board} = view, ctx, avail), do: board(view, ctx, avail)

  # On the project and session screens an overlay sits right under the header.
  defp screen(%View{overlay: overlay} = view, ctx, avail) when not is_nil(overlay) do
    [header, blank | rest] = screen(%{view | overlay: nil}, ctx, avail)
    band = overlay_band(overlay, ctx, max(div(avail, 2), 3))
    Enum.take([header, blank] ++ band ++ ["" | rest], avail)
  end

  defp screen(%View{screen: {:project, root}} = view, ctx, avail),
    do: project_screen(view, root, ctx, avail)

  defp screen(%View{screen: {:session, sid}} = view, ctx, avail),
    do: session_screen(view, sid, ctx, avail)

  defp screen(%View{screen: {:activity, root}} = view, ctx, avail),
    do: activity_screen(view, root, ctx, avail)

  defp screen(%View{screen: {:processes, _}} = view, ctx, avail),
    do: processes_screen(view, ctx, avail)

  defp finalize(body, bottom, avail, ctx) do
    body = Enum.take(body, avail)
    pad = List.duplicate("", avail - length(body))
    (body ++ pad ++ bottom) |> Enum.take(-ctx.height) |> pad_height(ctx.height)
  end

  defp pad_height(lines, h) when length(lines) >= h, do: lines
  defp pad_height(lines, h), do: lines ++ List.duplicate("", h - length(lines))

  # == the board ================================================================

  defp board(view, ctx, avail) do
    top = [header(view, ctx, fleet(view, ctx)), ""] ++ first_run(view, ctx) ++ now_band(view, ctx)
    rail = rail_band(view, ctx)
    remaining = avail - length(top) - length(rail) - 1

    line_projects = View.line(view)
    served = view |> View.served_today() |> Enum.take(@max_served)
    dim? = not is_nil(view.opened_ticket)

    line_rule =
      Style.rule("THE LINE", ctx,
        label: if(dim?, do: "dimmed", else: "every project, worst first"),
        width: rule_w(ctx),
        dim?: dim?
      )

    full_line = line_rows(view, line_projects, ctx, :all, dim?)

    served_band =
      if served == [] or dim?,
        do: [],
        else: ["", served_rule(ctx)] ++ served_rows(view, served, ctx)

    rest =
      cond do
        view.overlay ->
          overlay_band(view.overlay, ctx, max(remaining, 2))

        line_projects == [] ->
          [line_rule, Style.line([{" no projects yet · /add <path>", :quiet}], ctx)]

        1 + length(full_line) + length(served_band) <= remaining ->
          [line_rule | full_line] ++ served_band

        remaining >= 2 ->
          [line_rule | line_rows(view, line_projects, ctx, remaining - 1, dim?)]

        true ->
          []
      end

    case rest do
      [] -> top ++ rail
      _ -> top ++ rail ++ ["" | rest]
    end
  end

  defp rule_w(ctx), do: ctx.width - 1

  # Until the owner has opened help once: where to start.
  defp first_run(%View{first_run?: true}, ctx) do
    [
      Style.line(
        Style.fit_segs(
          [
            {" new here? press ", :quiet},
            {"?", :you},
            {" on any screen and Sprat explains what you're looking at", :quiet}
          ],
          rule_w(ctx),
          ctx
        ),
        ctx
      ),
      ""
    ]
  end

  defp first_run(_view, _ctx), do: []

  # == activity (spec-v5 §5): everything Sprat did, and what runs it ==========

  @max_programs 6

  defp activity_screen(view, root, ctx, avail) do
    snap = view.snapshot
    offset = Map.get(snap, :utc_offset, 0)
    name = root && View.project(view, root) && View.project(view, root).name
    crumbs = if name, do: [name, "activity"], else: ["activity"]

    jobs =
      view
      |> View.jobs()
      |> Enum.filter(&(is_nil(root) or &1.project_root == root))

    now = now_band(%{view | snapshot: Map.put(snap, :jobs, jobs)}, ctx)
    top = [header(view, ctx, crumbs), ""] ++ now
    system = Map.get(snap, :system) || %{}
    programs = (Map.get(snap, :commands) || []) |> Enum.take(@max_programs)

    machine =
      if root,
        do: [],
        else: ["" | processes_band(system, ctx)] ++ ["" | programs_band(programs, ctx)]

    events = View.activity(view, root)
    room = max(avail - length(top) - length(machine) - 1, 3)
    rows = events |> Enum.drop(view.activity_index) |> Enum.take(room - 1)

    shown =
      cond do
        events == [] ->
          "nothing yet"

        view.activity_index > 0 ->
          "#{view.activity_index + 1}–#{view.activity_index + length(rows)} of #{length(events)}"

        true ->
          "newest first · #{length(events)}"
      end

    timeline =
      [
        Style.rule("ACTIVITY", ctx,
          label: if(name, do: name, else: "every project"),
          right: shown,
          width: rule_w(ctx)
        )
      ] ++
        Enum.map(rows, &event_row(view, &1, root, offset, ctx))

    Enum.take(top ++ timeline ++ machine, avail)
  end

  # == sprat's processes =======================================================
  #
  # sprat serve's supervision tree, live: every process with how hard it is
  # working (a meter of its last readings), what is new and what just ended;
  # below, the messages they send each other, as lanes a dot travels along
  # from sender to receiver, more dots for more messages.

  @max_lanes 8
  @max_children 5
  @busy_rate 2_000

  defp processes_screen(view, ctx, avail) do
    procs = view.procs
    map = procs && procs.map

    right =
      if map,
        do: [{"#{map.processes} BEAM processes · #{map.memory_mb} MB", :quiet}, sp(1)],
        else: nil

    crumbs =
      ["activity", "processes"] ++
        case view.procs_view do
          :tree -> ["tree"]
          :pulse -> ["pulse"]
          :tank -> ["tank"]
          _ -> []
        end

    top = [header(view, ctx, crumbs, right), ""]
    room = max(avail - length(top), 3)

    body =
      cond do
        (map == nil and procs) && procs.error ->
          [
            Style.rule("PROCESSES", ctx, width: rule_w(ctx)),
            Style.line([{" " <> procs_error(procs.error), :quiet}], ctx)
          ]

        map == nil ->
          [
            Style.rule("PROCESSES", ctx, width: rule_w(ctx)),
            Style.line([{" reading sprat serve's processes" <> Style.ellipsis(ctx), :quiet}], ctx)
          ]

        view.procs_view == :story ->
          story(view, procs, ctx, room)

        view.procs_view == :pulse ->
          pulse(view, procs, ctx, room)

        view.procs_view == :tank ->
          tank(view, procs, ctx, room)

        true ->
          names = Map.new(map.nodes, &{&1.id, &1.name})
          lanes = lanes(Map.values(procs.flows), names, map.at, ctx)
          # The messages keep the bottom rows, the tree the rest, however
          # many of either there are this reading: nothing below a row
          # moves when a process starts or a lane comes and goes.
          tree_room = max(room - (@max_lanes + 3), 4)
          tree = process_tree(procs, ctx) |> Enum.take(tree_room - 1)
          tree = tree ++ List.duplicate("", tree_room - 1 - length(tree))

          [
            Style.rule("PROCESSES", ctx,
              label: "sprat serve, live",
              right: "work · mailbox · memory",
              width: rule_w(ctx)
            )
            | tree
          ] ++
            [
              "",
              Style.rule("MESSAGES", ctx,
                label: "who sends to whom",
                right: "per second",
                width: rule_w(ctx)
              )
            ] ++
            if(lanes == [],
              do: [Style.line([{" nothing sent in the last sample", :quiet}], ctx)],
              else: lanes
            )
      end

    Enum.take(top ++ body, avail)
  end

  # -- the grouped view --
  #
  # Sprat's processes as the things they stand for: a watcher per Claude
  # session, under its project, with the session's state and the last thing
  # its watcher read; then the parts that decide and deliver (the engine,
  # the publisher, the line to your board, the tasks running, the project
  # watchers, the plumbing folded into one row); then the latest change
  # followed hop by hop from Claude to this screen.

  # A change younger than this counts as just now: its hops carry sparks.
  @fresh_ms 3_000

  defp story(view, procs, ctx, room) do
    map = procs.map
    watchers = session_watchers(map)
    groups = story_groups(view, watchers)
    shown = groups |> Enum.flat_map(fn {_p, rows} -> Enum.map(rows, & &1.session.session_id) end)
    resting = map_size(watchers) - Enum.count(shown, &watched?(watchers, &1))

    parts = sprat_rows(view, procs, watchers, ctx)
    chain = chain_rows(view, procs, watchers, groups, ctx)
    session_room = max(room - length(parts) - length(chain) - 3, 2)

    sessions =
      groups
      |> Enum.flat_map(fn {p, rows} ->
        [Style.line([{"  " <> project_label(p), :text}], ctx)] ++
          Enum.map(rows, &story_row(view, &1, ctx))
      end)

    {sessions, cut} =
      if length(sessions) > session_room - 1 do
        kept = Enum.take(sessions, session_room - 2)
        {kept, length(sessions) - length(kept)}
      else
        {sessions, 0}
      end

    tail =
      [
        cut > 0 &&
          Style.line([{"  #{cut} more rows below; widen the pane to see them", :quiet}], ctx),
        resting > 0 &&
          groups != [] &&
          Style.line(
            [{"  + #{plural(resting, "watcher")} of ended sessions, resting", :quiet}],
            ctx
          )
      ]
      |> Enum.filter(& &1)

    sessions =
      if groups == [],
        do: [Style.line([{"  " <> no_sessions(watchers), :quiet}], ctx) | tail],
        else: sessions ++ tail

    sessions = Enum.take(sessions, session_room)
    sessions = sessions ++ List.duplicate("", session_room - length(sessions))

    [
      Style.rule("CLAUDE SESSIONS", ctx,
        label: "a watcher follows each one's transcript",
        right: "last thing it read",
        width: rule_w(ctx)
      )
      | sessions
    ] ++ ["" | parts] ++ ["" | chain]
  end

  # Just after sprat serve starts, its watchers run before it has matched
  # them to sessions.
  defp no_sessions(watchers) when map_size(watchers) == 0, do: "no Claude session is running"

  defp no_sessions(watchers),
    do:
      "no live Claude session yet · #{plural(map_size(watchers), "watcher")} reading transcripts"

  # Session watchers by session id. A daemon from before refs names them
  # "session <first 8 of the id>": matched on that.
  defp session_watchers(map) do
    for n <- map.nodes, key = watcher_key(n), key != nil, into: %{}, do: {key, n}
  end

  defp watcher_key(%{ref: {:session, sid}}), do: sid
  defp watcher_key(%{name: "session " <> short}), do: {:short, short}
  defp watcher_key(_), do: nil

  defp watcher(watchers, sid),
    do: Map.get(watchers, sid) || Map.get(watchers, {:short, String.slice(sid, 0, 8)})

  defp watched?(watchers, sid), do: watcher(watchers, sid) != nil

  # Live sessions by project, in a fixed order (project, then session name),
  # so a row stays where it is while states change.
  defp story_groups(view, watchers) do
    view.snapshot.projects
    |> Enum.sort_by(&String.downcase(project_label(&1)))
    |> Enum.map(fn p ->
      rows =
        p.sessions
        |> Enum.map(&%{session: &1, state: View.session_state(view, &1)})
        |> Enum.reject(&(&1.state == :ended))
        |> Enum.map(&Map.put(&1, :node, watcher(watchers, &1.session.session_id)))
        |> Enum.sort_by(&{String.downcase(session_label(&1.session)), &1.session.session_id})

      {p, rows}
    end)
    |> Enum.reject(fn {_p, rows} -> rows == [] end)
  end

  defp story_row(view, %{session: s, state: state, node: node}, ctx) do
    offset = Map.get(view.snapshot, :utc_offset, 0)
    {g, gs} = if state == :busy, do: spinner(ctx), else: glyph_seg(state)
    wide? = table_w(ctx) >= 90
    label_w = if wide?, do: 22, else: 16
    detail_w = if wide?, do: max(min(table_w(ctx) - label_w - 50, 30), 12), else: 18

    left =
      [{"    ", :text}, {g <> " ", gs}, {Style.fit(session_label(s), label_w, ctx), :text}, sp(1)] ++
        Style.fit_segs(story_detail_segs(view, s, state, offset), detail_w, ctx) ++
        [sp(2)] ++
        did_segs(node, "read", ctx)

    # No meter: a watcher reads every two seconds, so its work is a
    # stutter; the last thing it read says more.
    right =
      if node, do: [], else: [{"no watcher", :quiet}, sp(1)]

    Style.line(Style.lr(left, right, table_w(ctx), ctx), ctx)
  end

  # The session's state, without its title (the label says which it is).
  defp story_detail(view, s, :busy, _offset),
    do: working_for(view.snapshot.now, s, quiet(view, s))

  defp story_detail(view, s, state, offset), do: session_detail(view, s, state, offset)

  defp story_detail_segs(view, s, state, offset) when state in [:idle, :finished],
    do: session_detail_segs(view, s, state, offset, detail_style(state))

  defp story_detail_segs(view, s, state, offset),
    do: [{story_detail(view, s, state, offset), detail_style(state)}]

  # The last thing a process did and how long ago: bright while new, then
  # quiet, then "resting" once it is a minute old.
  defp did_segs(nil, _verb, _ctx), do: []
  defp did_segs(%{did: nil}, _verb, _ctx), do: [{"watching", :quiet}]

  defp did_segs(%{did: did, did_ago_ms: ms}, verb, _ctx) do
    cond do
      ms < @fresh_ms -> [{did, :progress}, {" · now", :quiet}]
      ms < 60_000 -> [{did <> " · #{div(ms, 1000)}s ago", :quiet}]
      true -> [{"last #{verb} #{ago_ms(ms)}", :quiet}]
    end
  end

  defp ago_ms(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m ago"
  defp ago_ms(ms), do: "#{div(ms, 3_600_000)}h ago"

  defp fresh?(%{did_ago_ms: ms}) when is_integer(ms), do: ms < @fresh_ms
  defp fresh?(_), do: false

  # -- the parts that decide and deliver --

  defp sprat_rows(_view, procs, watchers, ctx) do
    map = procs.map
    by_name = fn name -> Enum.find(map.nodes, &(&1.name == name)) end
    engine = by_name.("engine")
    publisher = by_name.("publisher")
    boards = Enum.filter(map.nodes, &(&1.ref == :board or &1.name == "a board"))
    tasks_sup = by_name.("tasks")
    tasks = if tasks_sup, do: Enum.filter(map.nodes, &(&1.parent == tasks_sup.id)), else: []
    projects = Enum.filter(map.nodes, &match?({:project, _}, Map.get(&1, :ref)))

    named =
      MapSet.new(
        Enum.map(
          [engine, publisher | boards ++ tasks ++ projects] ++ Map.values(watchers),
          &(&1 && &1.id)
        )
      )

    plumbing = Enum.filter(map.nodes, &(&1.kind == :worker and not MapSet.member?(named, &1.id)))
    plumbing_rate = plumbing |> Enum.map(&rate(procs, &1.id)) |> Enum.sum()

    latest_project =
      projects |> Enum.filter(& &1.did) |> Enum.min_by(& &1.did_ago_ms, fn -> nil end)

    [
      Style.rule("SPRAT", ctx, label: "the parts that decide and deliver", width: rule_w(ctx)),
      part_row(
        procs,
        engine,
        "engine",
        "decides what each session needs",
        did_segs(engine, "checked", ctx),
        ctx
      ),
      part_row(
        procs,
        publisher,
        "publisher",
        "sends every change out",
        did_segs(publisher, "sent", ctx),
        ctx
      ),
      part_row(
        procs,
        List.first(boards),
        "your board",
        case length(boards) do
          0 -> "no board connected"
          1 -> "this screen's line to sprat serve"
          n -> "#{n} boards connected"
        end,
        did_segs(List.first(boards), "sent", ctx),
        ctx
      ),
      part_row(
        procs,
        tasks_sup,
        "tasks",
        "investigations and jobs",
        case tasks do
          [] -> [{"nothing running", :quiet}]
          ts -> [spinner(ctx), {" " <> Enum.map_join(ts, ", ", & &1.name), :text}]
        end,
        ctx
      ),
      part_row(
        procs,
        nil,
        "projects",
        "#{plural(length(projects), "watcher")} of roadmaps and git",
        case latest_project do
          nil -> []
          p -> [{p.name <> ": ", :quiet} | did_segs(p, "read", ctx)]
        end,
        ctx
      ),
      part_row(
        procs,
        nil,
        "plumbing",
        "#{length(plumbing)} helpers · #{kb(plumbing |> Enum.map(& &1.memory_kb) |> Enum.sum())}",
        [{if(plumbing_rate >= @busy_rate, do: "busy", else: "all quiet"), :quiet}],
        ctx
      )
    ]
  end

  defp part_row(procs, node, name, role, did, ctx) do
    busy? = node != nil and rate(procs, node.id) >= @busy_rate
    wide? = table_w(ctx) >= 90
    role_w = max(min(table_w(ctx) - 14 - 52, 34), 10)

    left =
      [
        {" " <> if(ctx.ascii?, do: "+", else: "◆") <> " ", :quiet},
        {Style.fit(name, 11, ctx), if(busy?, do: :bright, else: :text)},
        sp(1)
      ] ++
        if(wide?, do: [{Style.fit(role, role_w, ctx), :quiet}, sp(2)], else: [sp(1)]) ++ did

    right =
      if node && wide?,
        do:
          meter(Map.get(procs.rates, node.id, []), ctx) ++
            [{"  " <> String.pad_leading(per_second(rate(procs, node.id)), 6), :quiet}, sp(1)],
        else: []

    Style.line(Style.lr(left, right, table_w(ctx), ctx), ctx)
  end

  # -- from Claude to your screen --
  #
  # The latest thing a watcher read, and the hops it takes to reach this
  # screen: the watcher puts it where the engine reads it, the engine's next
  # check takes it in, the publisher sends the change, the board's line
  # delivers it. While it is new, sparks run along the hops.

  defp chain_rows(view, procs, watchers, groups, ctx) do
    map = procs.map
    by_name = fn name -> Enum.find(map.nodes, &(&1.name == name)) end

    latest =
      for {_p, rows} <- groups, r <- rows, r.node && r.node.did, do: r

    latest = Enum.min_by(latest, & &1.node.did_ago_ms, fn -> nil end)
    _ = watchers

    case latest do
      nil ->
        [
          Style.rule("FROM CLAUDE TO YOUR SCREEN", ctx, width: rule_w(ctx)),
          Style.line([{" nothing new from a Claude session yet", :quiet}], ctx)
        ]

      %{session: s, node: w} ->
        live? = fresh?(w)
        engine = by_name.("engine")
        publisher = by_name.("publisher")
        board = Enum.find(map.nodes, &(&1.ref == :board or &1.name == "a board"))

        hops = [
          {session_label(s), "Claude wrote"},
          {"watcher", w.did},
          {"engine", (engine && engine.did) || "checked"},
          {"publisher", (publisher && publisher.did) || "sent it"},
          {"your board", if(board, do: "redrawn", else: "not connected")}
        ]

        age = if live?, do: "just now", else: "#{ago_ms(w.did_ago_ms)}"
        age = if age == "0m ago", do: "#{div(w.did_ago_ms, 1000)}s ago", else: age

        [
          Style.rule("FROM CLAUDE TO YOUR SCREEN", ctx,
            label: "the latest change, hop by hop",
            right: age,
            width: rule_w(ctx)
          )
          | chain(hops, live?, view, ctx)
        ]
    end
  end

  defp chain(hops, live?, _view, ctx) do
    w = table_w(ctx) - 2
    names = Enum.map(hops, fn {name, _} -> Style.truncate(name, 16, ctx) end)
    widths = Enum.map(names, &Style.w(&1, ctx))
    gaps = length(hops) - 1
    arrow = div(w - Enum.sum(widths) - 2 * gaps, gaps)

    if arrow >= 6 do
      top =
        names
        |> Enum.with_index()
        |> Enum.flat_map(fn {name, i} ->
          style = if i == 0, do: :bright, else: :text
          seg = [{name, style}]

          if i < gaps,
            do: seg ++ [sp(1)] ++ lane(if(live?, do: 1, else: 0), arrow, i, ctx) ++ [sp(1)],
            else: seg
        end)

      under =
        hops
        |> Enum.with_index()
        |> Enum.flat_map(fn {{_name, says}, i} ->
          span = Enum.at(widths, i) + if(i < gaps, do: arrow + 2, else: 0)

          [
            {Style.fit(says, span - 1, ctx) |> String.pad_trailing(span),
             if(i == 0, do: :quiet, else: :quiet)}
          ]
        end)

      [Style.line([sp(1) | top], ctx), Style.line([sp(1) | under], ctx)]
    else
      # Narrow: the hops one under another.
      down = if ctx.ascii?, do: "v", else: "↓"

      hops
      |> Enum.with_index()
      |> Enum.map(fn {{name, says}, i} ->
        Style.line(
          Style.fit_segs(
            [
              {if(i == 0, do: "  ", else: " " <> down <> " "), :rule},
              {name, :text},
              {"  " <> says, :quiet}
            ],
            rule_w(ctx),
            ctx
          ),
          ctx
        )
      end)
    end
  end

  # -- the pulse --
  #
  # Every live session's last two minutes as a lane, time running right to
  # left: a mark for each thing it did (edited, ran a command, read, wrote,
  # asked you, failed), a bar while a command runs, and the latest thing at
  # the end of the lane. Below, the engine's checks and the board's redraws
  # on the same clock.

  @pulse_ms 120_000
  @spanning [:run, :agent, :web]
  @priority [:fail, :ask, :you, :edit, :run, :agent, :web, :read, :tool, :say]

  defp pulse(view, procs, ctx, room) do
    map = procs.map
    groups = story_groups(view, session_watchers(map))
    w = rule_w(ctx)
    name_w = 24
    info_w = if w >= 110, do: 30, else: 18
    lane_w = max(w - name_w - info_w - 3, 12)
    now = map.wall_ms
    marks = Map.get(procs, :marks, %{})

    # A session that did nothing in the window, and isn't working or
    # waiting, has an empty lane: those fold into one line at the end.
    quiet? = fn r ->
      r.state not in [:busy, :waiting, :stuck] and
        not Enum.any?((r.node && r.node.beats) || [], &(now - elem(&1, 0) <= @pulse_ms))
    end

    quiet = for {_p, rows} <- groups, r <- rows, quiet?.(r), do: session_label(r.session)

    lanes =
      groups
      |> Enum.map(fn {p, rows} -> {p, Enum.reject(rows, quiet?)} end)
      |> Enum.reject(fn {_p, rows} -> rows == [] end)
      |> Enum.flat_map(fn {p, rows} ->
        [Style.line([{" " <> project_label(p), :text}], ctx)] ++
          Enum.map(rows, &pulse_row(view, &1, now, name_w, lane_w, info_w, ctx))
      end)

    folded =
      if quiet == [],
        do: [],
        else: [
          "",
          Style.line(
            Style.fit_segs(
              [
                {" #{plural(length(quiet), "quiet session")}, nothing in two minutes: ", :quiet},
                {Enum.join(quiet, ", "), :rule}
              ],
              w,
              ctx
            ),
            ctx
          )
        ]

    lanes =
      if lanes == [] and quiet == [],
        do: [Style.line([{"  no live Claude session", :quiet}], ctx)],
        else: lanes ++ folded

    pushes = Map.get(marks, "publisher", [])
    per_min = Enum.count(pushes, &(now - &1 <= 60_000))

    system = [
      Style.line(
        [{" " <> String.duplicate(if(ctx.ascii?, do: "-", else: "─"), w - 2), :rule}],
        ctx
      ),
      system_lane(
        "engine",
        Map.get(marks, "engine", []),
        {if(ctx.ascii?, do: "|", else: "┊"), :quiet},
        "checks every session",
        now,
        name_w,
        lane_w,
        info_w,
        ctx
      ),
      system_lane(
        "your board",
        pushes,
        {if(ctx.ascii?, do: "*", else: "•"), :progress},
        "redrawn #{per_min}× a minute",
        now,
        name_w,
        lane_w,
        info_w,
        ctx
      )
    ]

    lane_room = max(room - length(system) - 3, 2)
    lanes = Enum.take(lanes, lane_room)
    lanes = lanes ++ List.duplicate("", lane_room - length(lanes))

    [
      Style.rule("PULSE", ctx,
        label: "every session's last two minutes, newest on the right",
        width: w
      ),
      Style.line(pulse_legend(ctx), ctx)
      | lanes
    ] ++ system
  end

  defp pulse_legend(ctx) do
    [sp(1)] ++
      Enum.flat_map(
        [
          edit: "edit",
          run: "command",
          read: "read",
          say: "wrote",
          you: "you wrote",
          ask: "asked you",
          fail: "failed"
        ],
        fn {kind, word} ->
          {g, style} = beat_glyph(kind, ctx)
          [{g, style}, {" " <> word <> "   ", :quiet}]
        end
      )
  end

  defp pulse_row(view, %{session: s, state: state, node: node}, now, name_w, lane_w, info_w, ctx) do
    beats = (node && node.beats) || []
    {g, gs} = if state == :busy, do: spinner(ctx), else: glyph_seg(state)

    name = [
      {"  ", :text},
      {g <> " ", gs},
      {Style.fit(session_label(s), name_w - 5, ctx), :text},
      sp(1)
    ]

    lane = pulse_cells(beats, now, lane_w, state == :busy, ctx)
    info = [sp(1) | pulse_info(view, beats, s, state, now, info_w, ctx)]

    Style.line(Style.fit_segs(name ++ lane ++ info, name_w + lane_w + info_w + 1, ctx), ctx)
  end

  # The lane's cells, oldest on the left: the most telling beat in each
  # column, a bar after a command while it runs (until the next beat, or
  # now while the session works), blank otherwise.
  defp pulse_cells(beats, now, lane_w, busy?, ctx) do
    start = now - @pulse_ms
    col_ms = @pulse_ms / lane_w
    col = fn at -> floor((at - start) / col_ms) end

    marks =
      beats
      |> Enum.reject(&(elem(&1, 1) == :done))
      |> Enum.group_by(&col.(elem(&1, 0)), &elem(&1, 1))
      |> Map.new(fn {c, kinds} ->
        {c, Enum.min_by(kinds, &(Enum.find_index(@priority, fn k -> k == &1 end) || 99))}
      end)

    spans =
      beats
      |> Enum.zip(tl(beats ++ [nil]))
      |> Enum.flat_map(fn {{at, kind, _}, next} ->
        if kind in @spanning do
          from = col.(at) + 1

          to =
            case next do
              {nat, _, _} -> col.(nat) - 1
              nil -> if busy?, do: lane_w - 1, else: from - 1
            end

          for c <- max(from, 0)..min(to, lane_w - 1)//1, do: {c, kind}
        else
          []
        end
      end)
      |> Map.new()

    bar = if ctx.ascii?, do: "-", else: "─"
    # A faint track every few columns, so the eye can follow a quiet lane.
    track = fn c ->
      near? =
        Map.has_key?(marks, c - 1) or Map.has_key?(marks, c + 1) or
          Map.has_key?(spans, c - 1) or Map.has_key?(spans, c + 1)

      if rem(c, 3) == 0 and not near?,
        do: {if(ctx.ascii?, do: ".", else: "⋅"), :rule},
        else: {" ", :text}
    end

    for c <- 0..(lane_w - 1) do
      cond do
        k = marks[c] -> beat_glyph(k, ctx)
        k = spans[c] -> {bar, elem(beat_glyph(k, ctx), 1)}
        true -> track.(c)
      end
    end
    |> merge_segs()
  end

  # The latest thing the session did, and how long ago.
  defp pulse_info(view, beats, s, state, now, info_w, ctx) do
    latest = beats |> Enum.reject(&(elem(&1, 1) in [:done, :say])) |> List.last()

    case {state, latest} do
      {:waiting, _} ->
        [{Style.fit("waiting on you", info_w - 1, ctx), :you}]

      {_, nil} ->
        [
          {Style.fit(
             story_detail(view, s, state, Map.get(view.snapshot, :utc_offset, 0)),
             info_w - 1,
             ctx
           ), :quiet}
        ]

      {_, {at, kind, label}} ->
        {g, style} = beat_glyph(kind, ctx)
        words = label || beat_word(kind)
        age = " · " <> short_duration(div(max(now - at, 0), 1000))
        text = Style.truncate(words, info_w - 3 - String.length(age), ctx)
        [{g <> " ", style}, {text, :text}, {age, :quiet}]
    end
  end

  defp beat_word(:edit), do: "edited"
  defp beat_word(:run), do: "a command"
  defp beat_word(:read), do: "read"
  defp beat_word(:web), do: "the web"
  defp beat_word(:agent), do: "a subagent"
  defp beat_word(:ask), do: "asked you"
  defp beat_word(:you), do: "you wrote"
  defp beat_word(:fail), do: "failed"
  defp beat_word(_), do: "a tool"

  defp beat_glyph(kind, %{ascii?: true}) do
    {g, style} = beat_glyph(kind, %{ascii?: false})

    {%{
       "✎" => "e",
       "▶" => ">",
       "◦" => "o",
       "◇" => "w",
       "◈" => "A",
       "•" => "*",
       "·" => ".",
       "›" => "<",
       "✗" => "x"
     }[g] || g, style}
  end

  defp beat_glyph(:edit, _), do: {"✎", :progress}
  defp beat_glyph(:run, _), do: {"▶", :bright}
  defp beat_glyph(:read, _), do: {"◦", :quiet}
  defp beat_glyph(:web, _), do: {"◇", :quiet}
  defp beat_glyph(:agent, _), do: {"◈", :text}
  defp beat_glyph(:ask, _), do: {"?", :you}
  defp beat_glyph(:you, _), do: {"›", :you}
  defp beat_glyph(:fail, _), do: {"✗", :stuck}
  defp beat_glyph(:say, _), do: {"·", :text}
  defp beat_glyph(_, _), do: {"•", :quiet}

  defp system_lane(name, ats, glyph, info, now, name_w, lane_w, info_w, ctx) do
    start = now - @pulse_ms
    col_ms = @pulse_ms / lane_w
    cols = MapSet.new(ats, &floor((&1 - start) / col_ms))

    cells =
      for c <- 0..(lane_w - 1) do
        if MapSet.member?(cols, c), do: glyph, else: {" ", :text}
      end
      |> merge_segs()

    Style.line(
      Style.fit_segs(
        [{"    " <> Style.fit(name, name_w - 5, ctx) <> " ", :quiet}] ++
          cells ++ [{" " <> Style.fit(info, info_w - 1, ctx), :quiet}],
        name_w + lane_w + info_w + 1,
        ctx
      ),
      ctx
    )
  end

  # -- the tank --

  defp tank(view, procs, ctx, room) do
    fish =
      for {_p, rows} <- story_groups(view, session_watchers(procs.map)), r <- rows do
        %{name: session_label(r.session), state: r.state, fresh?: fresh?(r.node)}
      end

    Tank.render(%{fish: fish}, %{ctx | width: rule_w(ctx), height: max(room, 10)})
    |> Enum.map(&Style.line(&1, ctx))
  end

  defp procs_error(:old_daemon),
    do: "this sprat serve is older than the processes screen; restart it to see them"

  defp procs_error(why) when is_binary(why), do: "can't read sprat serve's processes: " <> why
  defp procs_error(why), do: "can't read sprat serve's processes: " <> inspect(why)

  # -- the tree --

  defp process_tree(procs, ctx) do
    map = procs.map
    gone = Enum.map(procs.gone, &Map.put(&1.node, :gone?, true))
    nodes = map.nodes ++ gone
    order = Map.get(procs, :order, %{})

    kids =
      nodes
      |> Enum.with_index()
      |> Enum.sort_by(fn {n, i} -> {Map.get(order, n.id, :infinity), i} end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.group_by(& &1.parent)

    roots = Map.get(kids, nil, [])

    Enum.flat_map(Enum.with_index(roots), fn {n, i} ->
      tree_rows(n, kids, procs, "", i == length(roots) - 1, true, ctx)
    end)
  end

  defp tree_rows(node, kids, procs, prefix, last?, root?, ctx) do
    {branch, carry} =
      cond do
        root? -> {"", ""}
        ctx.ascii? -> {if(last?, do: "`- ", else: "|- "), if(last?, do: "   ", else: "|  ")}
        true -> {if(last?, do: "└─ ", else: "├─ "), if(last?, do: "   ", else: "│  ")}
      end

    row = process_row(node, procs, prefix <> branch, ctx)
    children = Map.get(kids, node.id, [])
    {shown, hidden} = notable_children(children, procs)

    rows =
      shown
      |> Enum.with_index()
      |> Enum.flat_map(fn {c, i} ->
        last = i == length(shown) - 1 and hidden == 0
        tree_rows(c, kids, procs, prefix <> carry, last, false, ctx)
      end)

    more =
      if hidden > 0 do
        corner = if ctx.ascii?, do: "`- ", else: "└─ "

        [
          Style.line(
            [{" " <> prefix <> carry <> corner, :rule}, {"#{hidden} more, resting", :quiet}],
            ctx
          )
        ]
      else
        []
      end

    [row | rows] ++ more
  end

  # A supervisor of many (a watcher per session) gives its rows to the ones
  # that did something most recently (worked, had mail, started, ended),
  # always the same number of them, in their usual order; the rest are
  # counted. A watcher keeps its row until others have been busier since,
  # so the rows don't flicker with every reading.
  # Only a crowd of like processes folds: a group with a supervisor in it is
  # Sprat's own structure, always shown whole.
  defp notable_children(children, procs) do
    if length(children) <= @max_children + 1 or Enum.any?(children, &(&1.kind == :supervisor)),
      do: {children, 0},
      else: crowd(children, procs)
  end

  defp crowd(children, procs) do
    active = Map.get(procs, :active, %{})

    last = fn c ->
      cond do
        Map.get(c, :gone?, false) -> gone_at(procs, c.id)
        true -> Map.get(active, c.id, -1)
      end
    end

    keep =
      children
      |> Enum.with_index()
      |> Enum.sort_by(fn {c, i} -> {last.(c), -i} end, :desc)
      |> Enum.take(@max_children)
      |> MapSet.new(fn {c, _} -> c.id end)

    shown = Enum.filter(children, &MapSet.member?(keep, &1.id))
    {shown, length(children) - length(shown)}
  end

  defp gone_at(procs, id) do
    Enum.find_value(procs.gone, -1, &(&1.node.id == id && &1.at))
  end

  defp rate(procs, id) do
    case Map.get(procs.rates, id) do
      [r | _] -> r
      _ -> 0
    end
  end

  defp process_row(node, procs, prefix, ctx) do
    gone? = Map.get(node, :gone?, false)
    new? = Map.has_key?(procs.born, node.id)
    r = rate(procs, node.id)
    busy? = r >= @busy_rate

    glyph =
      cond do
        gone? -> {"·", :quiet}
        node.kind == :supervisor -> {if(ctx.ascii?, do: "+", else: "◆"), :quiet}
        node.kind == :task -> spinner(ctx)
        busy? -> {"●", :bright}
        true -> {"●", :quiet}
      end

    name_style =
      cond do
        gone? -> :quiet
        new? -> :progress
        node.kind == :supervisor -> :text
        busy? -> :bright
        true -> :text
      end

    note =
      cond do
        gone? -> [{"  ended", :quiet}]
        new? -> [{"  new", :progress}]
        true -> []
      end

    name_w = min(max(table_w(ctx) - 40, 18), 44)
    left = [{" " <> prefix, :rule}, glyph, {" ", :text}]
    used = Style.w(" " <> prefix, ctx) + 2

    # An ended row has no numbers: its name and note get the width.
    label_w = if gone?, do: table_w(ctx) - used, else: max(name_w - used + 2, 6)
    label = Style.fit_segs([{node.name, name_style}] ++ note, label_w, ctx)

    right =
      if gone? do
        []
      else
        meter(Map.get(procs.rates, node.id, []), ctx) ++
          [
            {"  " <> String.pad_leading(per_second(r), 6), if(busy?, do: :text, else: :quiet)},
            {"  " <> String.pad_leading(mailbox(node.queue), 6),
             if(node.queue > 20, do: :you, else: :quiet)},
            {"  " <> String.pad_leading(kb(node.memory_kb), 8), :quiet},
            sp(1)
          ]
      end

    Style.line(Style.lr(left ++ label, right, table_w(ctx), ctx), ctx)
  end

  # Rows read as a table: on a wide terminal the numbers stay near the names.
  defp table_w(ctx), do: min(rule_w(ctx), 112)

  @blocks ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  @blocks_ascii ~w(. : - = + * # @)

  # The last readings, oldest left: how hard it worked, on a log scale.
  defp meter(rates, ctx) do
    blocks = if ctx.ascii?, do: @blocks_ascii, else: @blocks
    readings = rates |> Enum.take(8) |> Enum.reverse()
    pad = String.duplicate(" ", 8 - length(readings))

    bars =
      Enum.map_join(readings, fn
        r when r < 50 -> " "
        r -> Enum.at(blocks, min(trunc(:math.log10(r) * 1.6) - 2, 7) |> max(0))
      end)

    [{pad <> bars, :progress}]
  end

  defp per_second(r) when r < 1, do: "-"
  defp per_second(r) when r < 1_000, do: "#{round(r)}"
  defp per_second(r) when r < 1_000_000, do: "#{Float.round(r / 1_000, 1)}k"
  defp per_second(r), do: "#{Float.round(r / 1_000_000, 1)}M"

  defp mailbox(0), do: "-"
  defp mailbox(n), do: "#{n}"

  # -- the lanes --

  # The tracer's sample: messages counted over this long.
  @sample_s 0.4

  defp lanes(flows, names, now, ctx) do
    name_w = 16
    tag_w = 14
    lane_w = max(min(table_w(ctx) - 2 * name_w - tag_w - 12, 34), 8)

    flows
    # The busiest, in a fixed order (by name), so a lane keeps its row as
    # rates change.
    |> Enum.sort_by(&{-&1.count, &1.from, &1.to})
    |> Enum.take(@max_lanes)
    |> Enum.sort_by(&{Map.get(names, &1.from, "?"), Map.get(names, &1.to, "?"), &1.from, &1.to})
    |> Enum.with_index()
    |> Enum.map(fn {f, i} ->
      from = Style.fit(Map.get(names, f.from, "?"), name_w, ctx)
      to = Style.fit(Map.get(names, f.to, "?"), name_w, ctx)
      per_s = round(f.count / @sample_s)
      # Not in the latest sample: the lane rests until it goes.
      quiet? = now - Map.get(f, :at, now) > 0

      Style.line(
        Style.fit_segs(
          [{" " <> from <> " ", :text}] ++
            lane(if(quiet?, do: 0, else: f.count), lane_w, i, ctx) ++
            [
              {" " <> to <> " ", :text},
              {Style.fit(f.tag, tag_w, ctx), :quiet},
              {String.pad_leading(if(quiet?, do: "-", else: "#{per_s}"), 6),
               if(quiet?, do: :quiet, else: :text)}
            ],
          table_w(ctx),
          ctx
        ),
        ctx
      )
    end)
  end

  # A lane from sender to receiver with dots on their way: more dots for
  # more messages, moving one cell a frame (still, for reduced motion). A
  # lane with nothing in the latest sample is an empty track.
  defp lane(0, w, _i, ctx) do
    {dash, head} = if ctx.ascii?, do: {"-", ">"}, else: {"─", "▶"}
    [{String.duplicate(dash, w - 1) <> head, :rule}]
  end

  defp lane(count, w, i, ctx) do
    track = w - 1
    dots = count |> Kernel.+(1) |> :math.log2() |> ceil() |> min(4) |> max(1)
    shift = if ctx.reduced_motion?, do: 0, else: ctx.frame + i * 3
    at = MapSet.new(for k <- 0..(dots - 1), do: rem(shift + div(k * track, dots), track))
    {dash, head, dot} = if ctx.ascii?, do: {"-", ">", "o"}, else: {"─", "▶", "●"}

    cells =
      for c <- 0..(track - 1) do
        if MapSet.member?(at, c), do: {dot, :you}, else: {dash, :rule}
      end

    merge_segs(cells) ++ [{head, :rule}]
  end

  defp merge_segs(cells) do
    cells
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn chunk -> {Enum.map_join(chunk, &elem(&1, 0)), elem(hd(chunk), 1)} end)
  end

  defp event_row(view, e, root, offset, ctx) do
    {icon, style} =
      case e.status do
        :ok -> {if(ctx.ascii?, do: "+", else: "✓"), :progress}
        :failed -> {if(ctx.ascii?, do: "x", else: "✗"), :stuck}
        :running -> {if(ctx.ascii?, do: ">", else: "▸"), :progress}
        _ -> {"·", :quiet}
      end

    project =
      cond do
        root ->
          []

        e.project_root ->
          [{Style.fit(project_label(view, e.project_root), 14, ctx) <> "  ", :text}]

        true ->
          [{Style.fit("sprat", 14, ctx) <> "  ", :quiet}]
      end

    Style.line(
      Style.fit_segs(
        [{" " <> hhmmss(e.at, offset) <> "  ", :quiet}] ++
          project ++
          [
            {icon <> " ", style},
            {kind_label(e.kind) <> "  ", :quiet},
            {e.text, if(e.status == :failed, do: :stuck, else: :text)}
          ],
        rule_w(ctx),
        ctx
      ),
      ctx
    )
  end

  defp project_label(view, root) do
    case View.project(view, root) do
      %{name: name} when is_binary(name) -> name
      _ -> Path.basename(root)
    end
  end

  defp kind_label(kind) do
    case kind do
      :job -> "job     "
      :pm -> "pm      "
      :delivery -> "sent    "
      :finding -> "finding "
      :served -> "done    "
      :engine -> "engine  "
      :command -> "program "
      :session -> "session "
      :observer -> "watching"
      _ -> "event   "
    end
  end

  defp processes_band(system, ctx) when map_size(system) == 0,
    do: [
      Style.rule("PROCESSES", ctx, width: rule_w(ctx)),
      Style.line([{" shown when the board is connected to sprat serve", :quiet}], ctx)
    ]

  defp processes_band(system, ctx) do
    summary =
      "#{system[:processes]} BEAM processes · #{system[:memory_mb]} MB · up #{duration(system[:uptime_s] || 0)}"

    work =
      "#{plural(system[:tasks] || 0, "task")}: #{plural(system[:jobs_running] || 0, "job")}, " <>
        plural(system[:pm_running] || 0, "investigation")

    rows =
      Enum.map(system[:tree] || [], fn p ->
        busy? = p.queue > 20

        Style.line(
          Style.fit_segs(
            [
              {" " <> Style.fit(p.name, 14, ctx), :text},
              {if(p.alive?, do: "running", else: "down   "),
               if(p.alive?, do: :progress, else: :stuck)},
              {"   mailbox " <> String.pad_leading(Integer.to_string(p.queue), 4),
               if(busy?, do: :you, else: :quiet)},
              {"   " <> String.pad_leading(kb(p.memory_kb), 8), :quiet}
            ] ++ if(p.name == "tasks", do: [{"   " <> work, :quiet}], else: []),
            rule_w(ctx),
            ctx
          ),
          ctx
        )
      end)

    [Style.rule("PROCESSES", ctx, label: summary, width: rule_w(ctx)) | rows]
  end

  defp programs_band([], ctx),
    do: [Style.rule("PROGRAMS SPRAT RUNS", ctx, label: "none yet", width: rule_w(ctx))]

  defp programs_band(programs, ctx) do
    rows =
      Enum.map(programs, fn c ->
        status =
          case c.last_status do
            0 -> {"exit 0", :quiet}
            :timeout -> {"stopped (too slow)", :stuck}
            nil -> {"", :quiet}
            n -> {"exit #{n}", :you}
          end

        running = if c.running > 0, do: [{"   #{c.running} running now", :progress}], else: []

        Style.line(
          Style.fit_segs(
            [
              {" " <> Style.fit(c.name, 18, ctx), :text},
              {String.pad_leading("#{c.runs}", 6) <> " runs", :quiet},
              {"   avg " <> String.pad_leading(ms(c.avg_ms), 6), :quiet},
              {"   max " <> String.pad_leading(ms(c.max_ms), 6),
               if(c.max_ms >= 5_000, do: :you, else: :quiet)},
              {"   ", :text},
              status
            ] ++ running,
            rule_w(ctx),
            ctx
          ),
          ctx
        )
      end)

    [
      Style.rule("PROGRAMS SPRAT RUNS", ctx,
        label: "since start, busiest first",
        width: rule_w(ctx)
      )
      | rows
    ]
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"

  defp ms(n) when n < 1000, do: "#{n}ms"
  defp ms(n), do: "#{Float.round(n / 1000, 1)}s"

  defp kb(n) when n < 1024, do: "#{n} KB"
  defp kb(n), do: "#{Float.round(n / 1024, 1)} MB"

  defp duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp duration(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp hhmmss(nil, _offset), do: "--:--:--"

  defp hhmmss(%DateTime{} = dt, offset) do
    dt = DateTime.add(dt, offset, :second)
    pad2(dt.hour) <> ":" <> pad2(dt.minute) <> ":" <> pad2(dt.second)
  end

  # -- now (spec-v5 §5): what Sprat is doing this moment ------------------------

  @max_now 3

  defp now_band(view, ctx) do
    jobs = view |> View.jobs() |> Enum.take(@max_now)

    rows =
      pending_row(view, ctx) ++
        Enum.flat_map(jobs, &job_rows(view, &1, ctx)) ++
        investigation_rows(view, @max_now - length(jobs), ctx)

    case rows do
      [] -> []
      rows -> [Style.rule("NOW", ctx, width: rule_w(ctx)) | rows] ++ [""]
    end
  end

  # Sprat's own investigations (PM runs) are work in progress too: what it
  # is looking into, for which project, and for how long.
  defp investigation_rows(_view, room, _ctx) when room <= 0, do: []

  defp investigation_rows(view, room, ctx) do
    now = view.snapshot.now

    view.snapshot.tickets
    |> Enum.filter(& &1.pm_running?)
    |> Enum.take(room)
    |> Enum.map(fn t ->
      what = (t.headline || "") |> String.replace_prefix("investigating: ", "") |> first_line()

      left = [
        {" ", :text},
        spinner(ctx),
        {" " <> (t.project_name || "sprat"), :bright},
        {" · investigating · " <> what, :text}
      ]

      Style.line(
        Style.lr(
          left,
          [{"  " <> elapsed(now, t.pm_started_at), :quiet}, sp(1)],
          rule_w(ctx),
          ctx
        ),
        ctx
      )
    end)
  end

  defp pending_row(%View{pending: %{label: label}}, ctx),
    do: [
      Style.line([{" ", :text}, spinner(ctx), {" " <> label <> Style.ellipsis(ctx), :you}], ctx)
    ]

  defp pending_row(_view, _ctx), do: []

  defp job_rows(view, job, ctx) do
    now = view.snapshot.now

    {icon, detail, right} =
      case job.status do
        :running ->
          {spinner(ctx), job.step && {job.step, :text}, elapsed(now, job.started_at)}

        :done ->
          {{if(ctx.ascii?, do: "+", else: "✓"), :progress}, job.result && {job.result, :quiet},
           ago(now, job.finished_at)}

        _ ->
          # Why it failed is the point: on its own lines below, not cut off.
          {{if(ctx.ascii?, do: "x", else: "✗"), :stuck}, nil, ago(now, job.finished_at)}
      end

    left =
      [{" ", :text}, icon, {" " <> (job.project_name || "sprat"), :bright}] ++
        if(job.label, do: [{" · " <> job.label, :text}], else: []) ++
        case detail do
          {text, style} -> [{" · " <> text, style}]
          nil -> []
        end

    head = Style.line(Style.lr(left, [{"  " <> right, :quiet}, sp(1)], rule_w(ctx), ctx), ctx)

    why =
      if job.status == :failed and is_binary(job.result) do
        job.result
        |> Style.wrap(rule_w(ctx) - 4, ctx)
        |> Enum.take(2)
        |> Enum.map(&Style.line([{"   ", :text}, {&1, :stuck}], ctx))
      else
        []
      end

    [head | why]
  end

  @spin ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @spin_ascii ["|", "/", "-", "\\"]

  defp spinner(%{reduced_motion?: true} = ctx),
    do: {if(ctx.ascii?, do: "*", else: "•"), :progress}

  defp spinner(ctx) do
    frames = if ctx.ascii?, do: @spin_ascii, else: @spin
    {Enum.at(frames, rem(ctx.frame, length(frames))), :progress}
  end

  defp elapsed(_now, nil), do: ""

  defp elapsed(now, at) do
    s = max(DateTime.diff(now, at), 0)
    if s < 60, do: "#{s}s", else: "#{div(s, 60)}m #{rem(s, 60)}s"
  end

  defp ago(_now, nil), do: ""

  defp ago(now, at) do
    s = max(DateTime.diff(now, at), 0)
    if s < 60, do: "just now", else: "#{div(s, 60)}m ago"
  end

  # -- overlay (the brief) -----------------------------------------------------

  defp overlay_band({:brief, text}, ctx, budget) do
    rule = Style.rule("BRIEF", ctx, right: "esc close", width: rule_w(ctx))

    rows =
      text
      |> to_string()
      |> String.split("\n")
      |> Enum.flat_map(fn
        "" -> [""]
        para -> Style.wrap(para, ctx.width - 2, ctx)
      end)
      |> Enum.map(&Style.line([{" ", :text}, {&1, :text}], ctx))

    room = max(budget - 1, 1)

    rows =
      if length(rows) > room do
        Enum.take(rows, room - 1) ++
          [Style.line([{" …#{length(rows) - room + 1} more lines", :quiet}], ctx)]
      else
        rows
      end

    [rule | rows]
  end

  defp overlay_band(_other, _ctx, _budget), do: []

  # -- header ------------------------------------------------------------------

  defp header(view, ctx, crumbs, right \\ nil)

  # The board's header: the fleet at a glance instead of crumbs.
  defp header(view, ctx, {:fleet, segs}, right) do
    left = [{" ", :text}, {"SPRAT", :bright}, {" ", :text}, fish(view, ctx)] ++ segs
    right = right || header_right(view, ctx)
    Style.line(Style.lr(left, right ++ [sp(1)], ctx.width, ctx), ctx)
  end

  defp header(view, ctx, crumbs, right) do
    left =
      [{" ", :text}, {"SPRAT", :bright}, {" ", :text}, fish(view, ctx)] ++
        Enum.flat_map(crumbs, fn c -> [{"  › ", :quiet}, {c, :text}] end)

    right = right || header_right(view, ctx)
    Style.line(Style.lr(left, right ++ [sp(1)], ctx.width, ctx), ctx)
  end

  # Every live agent in one line: how many work, how many just finished a
  # turn (someone's move), how many wait on the owner or are stuck. Words
  # from 100 columns, marks and numbers from 70, nothing narrower.
  defp fleet(view, ctx) do
    c = View.fleet_counts(view)

    parts =
      [
        {c.busy, "●", "working", :text},
        {c.finished, "✓", "finished", :progress},
        {c.waiting, "⏸", "need you", :you},
        {c.stuck, "⚠", "stuck", :stuck}
      ]
      |> Enum.reject(fn {n, _, _, _} -> n == 0 end)

    segs =
      cond do
        ctx.width < 70 ->
          []

        c.live == 0 ->
          [{"   no live sessions", :quiet}]

        parts == [] ->
          [{"   #{plural(c.live, "session")}, all idle", :quiet}]

        ctx.width >= 100 ->
          [{"  ", :text}] ++
            Enum.flat_map(parts, fn {n, g, word, style} ->
              [{" " <> g <> " ", style}, {"#{n} #{word}", :text}, {" ", :text}]
            end)

        true ->
          [{"  ", :text}] ++
            Enum.flat_map(parts, fn {n, g, _word, style} ->
              [{" " <> g, style}, {"#{n}", :text}]
            end)
      end

    {:fleet, segs}
  end

  defp header_right(view, ctx) do
    snap = view.snapshot
    offset = Map.get(snap, :utc_offset, 0)
    clock = hhmm(snap.now, offset)

    health = health(Map.get(snap, :header) || %{})

    if ctx.width >= 70 do
      health ++
        [{date_label(snap.now, offset) <> "  ", :quiet}, {clock, :text} | spend(snap.header)]
    else
      health ++ [{clock, :text}]
    end
  end

  # Said in the header because it silently breaks every delivery.
  defp health(%{cmux: :denied}), do: [{"✗ cmux refused sprat  ", :stuck}]
  defp health(%{cmux: :failed}), do: [{"✗ cmux not answering  ", :stuck}]
  defp health(_), do: []

  defp spend(%{pm_spend: spend} = header) when not is_nil(spend) do
    cap = Map.get(header, :fleet_cap)
    cap_text = if cap, do: "/" <> money(cap, :short), else: ""
    [{" · pm $" <> money(spend, :cents) <> cap_text, :quiet}]
  end

  defp spend(_), do: []

  @doc false
  def fish(view, ctx) do
    case View.fish_state(view) do
      :facing ->
        blink? = View.blinking?(view) and rem(div(ctx.frame, 5), 2) == 1
        {if(blink?, do: "<><", else: "<•<"), :you}

      :swimming ->
        if ctx.reduced_motion?,
          do: {"><>", :text},
          else: {Mascot.render(:working, ctx.frame, 8), :text}

      :still ->
        {"><>", :quiet}
    end
  end

  # -- the rail ----------------------------------------------------------------

  defp rail_mode(%{width: w}) when w >= 84, do: :cards
  defp rail_mode(%{width: w}) when w >= 60, do: :strips
  defp rail_mode(_), do: :strips2

  defp cards_across(%{width: w}) when w >= 120, do: 4
  defp cards_across(_), do: 3

  defp rail_band(view, ctx) do
    rail = View.rail(view)
    opened = view.opened_ticket && View.ticket(view, view.opened_ticket)

    cond do
      rail == [] ->
        [
          Style.rule("ON THE RAIL", ctx,
            label: "clear · nothing needs attention",
            width: rule_w(ctx),
            dim?: true
          )
        ]

      opened ->
        idx = Enum.find_index(rail, &(&1.id == opened.id)) || 0
        right = "#{idx + 1} of #{length(rail)} · ←→ · esc fold"

        [Style.rule("ON THE RAIL", ctx, right: right, width: rule_w(ctx))] ++
          opened_box(view, opened, ctx)

      true ->
        right = if ctx.width >= 60, do: "yours first, oldest left", else: "yours first"

        [
          Style.rule("ON THE RAIL", ctx,
            label: if(ctx.width >= 72, do: "what needs attention"),
            right: right,
            width: rule_w(ctx)
          )
          | rail_body(view, rail, ctx)
        ]
    end
  end

  defp rail_body(view, rail, ctx) do
    # The rail keeps its place while focus is elsewhere (so the cards don't
    # scroll), but only shows a selection while it has focus.
    selected = if view.focus == :rail, do: view.rail_index, else: nil

    case rail_mode(ctx) do
      :cards ->
        cards(view, rail, view.rail_index, selected, ctx)

      :strips ->
        Enum.with_index(rail) |> Enum.map(fn {t, i} -> strip(view, t, i == selected, ctx) end)

      :strips2 ->
        Enum.with_index(rail)
        |> Enum.flat_map(fn {t, i} -> strip2(view, t, i == selected, ctx) end)
    end
  end

  defp cards(view, rail, at, selected, ctx) do
    n = cards_across(ctx)
    card_w = min(div(ctx.width - 2 - (n - 1), n), 40)
    offset = max(0, at - n + 1)
    visible = rail |> Enum.drop(offset) |> Enum.take(n)

    columns =
      visible
      |> Enum.with_index(offset)
      |> Enum.map(fn {t, i} -> card(view, t, i == selected, card_w, ctx) end)

    rows =
      columns
      |> Enum.zip()
      |> Enum.map(fn row -> " " <> (row |> Tuple.to_list() |> Enum.join(" ")) end)

    hidden_after = length(rail) - offset - length(visible)

    more =
      cond do
        offset == 0 and hidden_after == 0 ->
          []

        true ->
          left = if offset > 0, do: [{" ← #{offset} more", :quiet}], else: []
          right = if hidden_after > 0, do: [{"+#{hidden_after} more →", :quiet}, sp(1)], else: []
          [Style.line(Style.lr(left, right, ctx.width, ctx), ctx)]
      end

    rows ++ more
  end

  defp card(view, %Ticket{} = t, selected?, card_w, ctx) do
    {tl, tr, bl, br, h, v} =
      if selected?,
        do: {"┏", "┓", "┗", "┛", "━", "┃"},
        else: {"┌", "┐", "└", "┘", "─", "│"}

    # The active card: heavy border in the accent colour.
    border = if selected?, do: :you, else: :rule
    iw = card_w - 4
    yours? = t.owner == :yours
    body_style = if yours?, do: :text, else: :quiet

    chip = if iw < 24, do: compact_chip(view, t), else: chip(view, t, ctx)
    head = [chip, {" ", :text}, owner_word(t), {" ", :text}, project_word(t)]

    headline =
      t.headline
      |> Style.wrap(iw, ctx)
      |> cap_lines(3, iw, ctx)
      |> pad_list(3, "")
      |> Enum.map(&[{&1, body_style}])

    fourth =
      cond do
        yours? and t.meanwhile -> [{t.meanwhile, :quiet}]
        t.pm_running? -> [ticket_fish(ctx, iw)]
        true -> []
      end

    action = [{t.action_label || default_action(t), if(selected?, do: :bright, else: body_style)}]

    row = fn segs ->
      Style.line(
        [{v <> " ", border}] ++ Style.fit_segs(segs, iw, ctx) ++ [{" " <> v, border}],
        ctx,
        card_w
      )
    end

    rows = [head] ++ headline ++ [fourth, action]
    rows = rows |> pad_list(@card_rows, []) |> Enum.take(@card_rows)

    [Style.line([{tl <> String.duplicate(h, card_w - 2) <> tr, border}], ctx, card_w)] ++
      Enum.map(rows, row) ++
      [Style.line([{bl <> String.duplicate(h, card_w - 2) <> br, border}], ctx, card_w)]
  end

  defp ticket_fish(%{reduced_motion?: true}, _w), do: {"><>", :quiet}
  defp ticket_fish(ctx, w), do: {Mascot.render(:working, ctx.frame, min(w, 12)), :quiet}

  defp cap_lines(lines, n, width, ctx) do
    if length(lines) <= n do
      lines
    else
      {keep, [last | _]} = Enum.split(lines, n - 1)
      keep ++ [Style.truncate(last <> " " <> Style.ellipsis(ctx), width, ctx)]
    end
  end

  defp pad_list(list, n, fill) when length(list) < n,
    do: list ++ List.duplicate(fill, n - length(list))

  defp pad_list(list, _n, _fill), do: list

  defp strip(view, %Ticket{} = t, selected?, ctx) do
    key = action_key(t)
    pw = 12
    marker = if selected?, do: {"▌", :bright}, else: {" ", :text}
    body_style = if t.owner == :yours, do: :text, else: :quiet

    head = [
      {" ", :text},
      marker,
      chip(view, t, ctx),
      {" ", :text},
      owner_word(t, 5),
      {" ", :text}
    ]

    head = head ++ [{Style.fit(project_name(t), pw, ctx), project_style(t)}, {" ", :text}]
    left = head ++ [{first_line(t.headline), body_style}] ++ fish_tail(t, ctx)
    right = [{" " <> key, if(selected?, do: :bright, else: body_style)}, sp(1)]
    Style.line(Style.lr(left, right, ctx.width, ctx), ctx)
  end

  defp strip2(view, %Ticket{} = t, selected?, ctx) do
    key = action_key(t)
    marker = if selected?, do: {"▌", :bright}, else: {" ", :text}
    body_style = if t.owner == :yours, do: :text, else: :quiet

    left = [
      {" ", :text},
      marker,
      chip(view, t, ctx),
      {" ", :text},
      owner_word(t, 5),
      {" ", :text},
      project_word(t)
    ]

    right = [{key, if(selected?, do: :bright, else: body_style)}, sp(1)]

    second =
      [{String.duplicate(" ", 8), :text}, {first_line(t.headline), body_style}] ++
        fish_tail(t, ctx)

    [
      Style.line(Style.lr(left, right, ctx.width, ctx), ctx),
      Style.line(Style.fit_segs(second, ctx.width - 1, ctx), ctx)
    ]
  end

  defp fish_tail(%Ticket{pm_running?: true}, _ctx), do: [{" ><>", :quiet}]
  defp fish_tail(_t, _ctx), do: []

  defp first_line(nil), do: ""
  defp first_line(text), do: text |> String.split("\n") |> hd()

  defp owner_word(t, width \\ nil)
  defp owner_word(%Ticket{owner: :yours}, nil), do: {"yours", :you}
  defp owner_word(%Ticket{}, nil), do: {"sprat", :quiet}

  defp owner_word(t, w),
    do: {String.pad_trailing(elem(owner_word(t, nil), 0), w), elem(owner_word(t, nil), 1)}

  defp project_word(t), do: {project_name(t), project_style(t)}
  defp project_style(%Ticket{owner: :yours}), do: :bright
  defp project_style(_), do: [:quiet, :bold]

  defp project_name(%Ticket{project_name: name, project_root: root}),
    do: name || (root && Path.basename(root)) || "?"

  defp default_action(%Ticket{proposal: p}) when is_binary(p), do: "f send  ⏎ edit"
  defp default_action(%Ticket{owner: :yours}), do: "⏎ details"
  defp default_action(_), do: "⏎ watch"

  @doc false
  def action_key(%Ticket{} = t) do
    case String.split(t.action_label || default_action(t), " ", parts: 2) do
      [key | _] when key != "" -> key
      _ -> "⏎"
    end
  end

  # -- the age chip ------------------------------------------------------------

  defp chip(view, %Ticket{} = t, _ctx) do
    {" " <> String.pad_leading(age_label(view.snapshot.now, t.since), 3) <> " ",
     [age_role(view, t), :reverse]}
  end

  # Narrow cards drop the chip's padding so the project name still fits.
  defp compact_chip(view, %Ticket{} = t) do
    {String.pad_leading(age_label(view.snapshot.now, t.since), 3), [age_role(view, t), :reverse]}
  end

  @doc "Age as the chip shows it: `25M`, `3H`, `2D`."
  def age_label(_now, nil), do: "--"

  def age_label(now, since) do
    mins = max(div(DateTime.diff(now, since, :second), 60), 0)

    cond do
      mins < 60 -> "#{mins}M"
      mins < 48 * 60 -> "#{div(mins, 60)}H"
      true -> "#{div(mins, 1440)}D"
    end
  end

  @doc """
  The chip's colour role: quiet while fresh, amber past the finding rule's
  threshold, red past twice it or with an unresolved nudge (§10.7).
  """
  def age_role(%View{snapshot: snap}, %Ticket{} = t) do
    finding = t.finding
    kind = finding && finding.kind
    data = (finding && finding.data) || %{}
    thresholds = Map.merge(@default_thresholds, get_in(snap, [:settings, :age_thresholds]) || %{})
    threshold = Map.get(thresholds, finding && finding.rule, thresholds.default)
    mins = if t.since, do: div(DateTime.diff(snap.now, t.since, :second), 60), else: 0

    cond do
      kind == :scheduled -> :quiet
      Map.get(data, :unresolved_nudge) -> :stuck
      mins >= threshold * 2 -> :stuck
      mins >= threshold -> :you
      true -> :quiet
    end
  end

  # -- a ticket, opened (§10.4) ------------------------------------------------

  @label_w 11

  defp opened_box(view, %Ticket{} = t, ctx) do
    bw = ctx.width - 2
    iw = bw - 4
    tw = iw - @label_w
    yours? = t.owner == :yours
    finding = t.finding
    decision = t.decision

    sid = t.session_name || (t.session_id && String.slice(t.session_id, 0, 8))

    head =
      [chip(view, t, ctx), {" ", :text}, owner_word(t), {" · ", :quiet}, project_word(t)] ++
        if(sid, do: [{" · ", :quiet}, {sid, :quiet}], else: [])

    editing? =
      match?(%{purpose: :edit_proposal}, view.composer) and view.composer.ticket_id == t.id

    proposal = View.fire_text(view, t)

    you_block =
      cond do
        editing? ->
          composer_rows(view.composer.composer, tw, ctx)
          |> labelled("you", :you, tw, ctx)

        proposal ->
          edited = if Map.has_key?(view.edited, t.id), do: " (edited)", else: ""

          labelled_text("you", proposal, :bright, tw, ctx,
            right: [{"e edit" <> edited, :quiet}],
            label_style: :you
          )

        yours? ->
          text = (decision && decision.owner_note) || t.headline
          labelled_text("you", text, :text, tw, ctx, label_style: :you)

        true ->
          labelled_text("sprat", t.headline, :quiet, tw, ctx) ++
            if(t.pm_running?,
              do: [[{String.duplicate(" ", @label_w), :text}, ticket_fish(ctx, 12)]],
              else: []
            )
      end

    found =
      if finding && finding.summary,
        do: labelled_text("found", finding.summary, :text, tw, ctx),
        else: []

    tried =
      case decision && decision.tried do
        [_ | _] = items ->
          items |> Enum.flat_map(&hanging(&1, tw, ctx)) |> labelled("tried", :quiet, tw, ctx)

        _ ->
          []
      end

    did =
      case t.did do
        [_ | _] = entries ->
          entries
          |> Enum.flat_map(&did_rows(&1, view, tw, ctx))
          |> labelled("did", :quiet, tw, ctx)

        _ ->
          []
      end

    pm =
      case pm_summary(t) do
        nil ->
          []

        text ->
          [
            Style.lr(
              [{"pm run", :quiet}, sp(@label_w - 6), {text, :quiet}],
              [{"⏎ session", :quiet}],
              iw,
              ctx
            )
          ]
      end

    keys = [opened_keys(view, t, editing?, proposal, ctx)]

    body =
      [head, []] ++
        you_block ++
        if(found ++ tried ++ did == [], do: [], else: [[]]) ++
        found ++ tried ++ did ++ if(pm == [], do: [], else: [[]]) ++ pm ++ keys

    border = :bright

    [Style.line([{" ┏" <> String.duplicate("━", bw - 2) <> "┓", border}], ctx)] ++
      Enum.map(body, fn segs ->
        Style.line([{" ┃ ", border}] ++ Style.fit_segs(segs, iw, ctx) ++ [{" ┃", border}], ctx)
      end) ++
      [Style.line([{" ┗" <> String.duplicate("━", bw - 2) <> "┛", border}], ctx)]
  end

  defp opened_keys(_view, _t, true, _proposal, _ctx) do
    [{"enter save   alt+enter newline   esc cancel", :quiet}]
  end

  defp opened_keys(view, t, false, proposal, _ctx) do
    pairs =
      cond do
        match?(%{purpose: :dismiss_reason}, view.composer) ->
          [
            {"reason: " <> view.composer.composer.text <> "▏", :you},
            {"   enter dismiss   esc cancel", :quiet}
          ]

        proposal ->
          [{"f send   e edit   E $EDITOR   c copy   x dismiss   m mute   esc fold", :quiet}]

        t.owner == :yours ->
          [{"x done   c copy note   m mute   u revert   esc fold", :quiet}]

        true ->
          [{"x dismiss   m mute   ⏎ session   esc fold", :quiet}]
      end

    pairs
  end

  defp pm_summary(%Ticket{} = t) do
    run = t.pm_run || %{}
    confidence = Map.get(run, :confidence) || (t.decision && t.decision.confidence)

    parts =
      [
        Map.get(run, :cost_usd) && "$" <> money(Map.get(run, :cost_usd), :cents),
        Map.get(run, :turns) && "#{Map.get(run, :turns)} turns",
        confidence && "confidence #{confidence}",
        t.pm_running? && "running"
      ]
      |> Enum.filter(&is_binary/1)

    if parts == [], do: nil, else: Enum.join(parts, " · ")
  end

  defp did_rows(entry, view, tw, ctx) do
    at = Map.get(entry, :at)
    time = if at, do: hhmm(at, Map.get(view.snapshot, :utc_offset, 0)), else: "     "
    rev = Map.get(entry, :revertible_id)
    right = if rev, do: [{"u revert", :quiet}], else: []
    rw = if rev, do: 10, else: 0
    lines = Style.wrap(Map.get(entry, :text, ""), max(tw - 7 - rw, 8), ctx)

    case lines do
      [] ->
        []

      [first | more] ->
        [Style.lr([{time <> "  ", :quiet}, {first, :text}], right, tw, ctx)] ++
          Enum.map(more, &[{"       ", :text}, {&1, :text}])
    end
  end

  # A list item wrapped with a two-column hanging indent.
  defp hanging(text, tw, ctx) do
    case Style.wrap(text, tw - 2, ctx) do
      [] -> []
      [first | more] -> [[{first, :text}] | Enum.map(more, &[{"  " <> &1, :text}])]
    end
  end

  defp labelled_text(label, text, style, tw, ctx, opts \\ []) do
    right = Keyword.get(opts, :right, [])
    rw = Style.segs_width(right, ctx)
    width = if rw > 0, do: tw - rw - 2, else: tw

    rows =
      text
      |> Style.wrap(max(width, 8), ctx)
      |> Enum.map(&[{&1, style}])

    rows =
      case {rows, right} do
        {[first | more], [_ | _]} -> [Style.lr(first, right, tw, ctx) | more]
        _ -> rows
      end

    labelled(rows, label, Keyword.get(opts, :label_style, :quiet), tw, ctx)
  end

  defp labelled([], _label, _style, _tw, _ctx), do: []

  defp labelled([first | more], label, style, _tw, _ctx) do
    pad = String.duplicate(" ", @label_w)

    [
      [{String.pad_trailing(label, @label_w), style} | first]
      | Enum.map(more, &[{pad, :text} | &1])
    ]
  end

  defp composer_rows(%Composer{} = c, tw, ctx) do
    {row, col} = Composer.cursor_position(c)

    c
    |> Composer.lines()
    |> Enum.with_index()
    |> Enum.flat_map(fn {text, i} ->
      text = if i == row, do: insert_at(text, col, "▏"), else: text
      text |> Style.wrap(tw, ctx) |> then(&if(&1 == [], do: [""], else: &1))
    end)
    |> Enum.map(&[{&1, :bright}])
  end

  defp insert_at(text, col, mark) do
    {a, b} = text |> String.graphemes() |> Enum.split(col)
    Enum.join(a) <> mark <> Enum.join(b)
  end

  # -- the line ----------------------------------------------------------------

  defp position_label(%{position: %{} = pos}),
    do: String.trim("#{pos.phase_id} #{pos.done || 0}/#{pos.total || 0}")

  defp position_label(_), do: ""

  defp line_layout(view, projects, ctx) do
    names = Enum.map(projects, &project_label/1)
    # Names get up to 22 columns on wide panes (real repo names run long:
    # `cupful_backend`), 16 on narrow ones.
    cap = if ctx.width >= 100, do: 22, else: 16
    nw = names |> Enum.map(&String.length/1) |> Enum.max(fn -> 8 end) |> Kernel.+(2) |> min(cap)

    gw =
      projects
      |> Enum.map(&(length(&1.sessions) * 2))
      |> Enum.max(fn -> 2 end)
      |> max(6)
      |> min(12)

    auto_w =
      projects
      |> Enum.map(&String.length(autonomy_word(&1.autonomy)))
      |> Enum.max(fn -> 3 end)
      |> max(3)
      |> Kernel.+(1)

    labels_w =
      projects
      |> Enum.map(&String.length(elem(View.doing(view, &1), 0)))
      |> Enum.max(fn -> 8 end)

    # What Sprat is doing gets its own column on wide panes; on narrower ones
    # it takes the autonomy word's place (the project screen still shows it).
    {doing_w, auto_w} =
      cond do
        ctx.width >= 90 -> {labels_w + 2, auto_w}
        ctx.width >= 60 -> {0, labels_w + 1}
        true -> {0, auto_w}
      end

    %{
      mode: if(ctx.width >= 60, do: :one, else: :two),
      name_w: nw,
      doing_w: doing_w,
      # "C 15/16" is 7 characters; one more keeps a gap before the bar.
      pos_w:
        projects
        |> Enum.map(&String.length(position_label(&1)))
        |> Enum.max(fn -> 6 end)
        |> Kernel.+(1)
        |> max(7),
      bar_w: if(ctx.width >= 84, do: 10, else: 6),
      glyph_w: gw,
      auto_w: auto_w,
      last_w: if(ctx.width >= 120, do: 9, else: 0)
    }
  end

  defp line_rows(view, projects, ctx, budget, dim?) do
    layout = line_layout(view, projects, ctx)

    # Column headings, quiet, so the row reads without the help page.
    {heading, budget} =
      cond do
        layout.mode != :one or projects == [] -> {[], budget}
        budget == :all -> {[line_heading(layout, ctx)], :all}
        budget >= 3 -> {[line_heading(layout, ctx)], budget - 1}
        true -> {[], budget}
      end

    per = if layout.mode == :one, do: 1, else: 2
    sel = view.line_index
    focus? = view.focus == :line and not dim?
    n = length(projects)

    {offset, count, above?, below} =
      cond do
        budget == :all or n * per <= budget ->
          {0, n, false, 0}

        true ->
          cap = max(div(budget - 1, per), 1)
          offset = max(0, sel - cap + 1)

          {cap, offset} =
            if offset > 0 do
              cap = max(div(budget - 2, per), 1)
              {cap, max(0, sel - cap + 1)}
            else
              {cap, offset}
            end

          {offset, cap, offset > 0, max(n - offset - cap, 0)}
      end

    rows =
      projects
      |> Enum.with_index()
      |> Enum.drop(offset)
      |> Enum.take(count)
      |> Enum.flat_map(fn {p, i} ->
        project_row(view, p, layout, focus? and i == sel, dim?, ctx)
      end)

    above = if above?, do: [Style.line([{" …#{offset} above ↑", :quiet}], ctx)], else: []
    more = if below > 0, do: [Style.line([{" …#{below} more ↓", :quiet}], ctx)], else: []
    heading ++ above ++ rows ++ more
  end

  defp line_heading(layout, ctx) do
    mid_w =
      ctx.width - 1 - 1 - layout.name_w - layout.pos_w - layout.bar_w - 2 - layout.doing_w -
        layout.auto_w - layout.last_w

    col = fn text, w, align -> {Style.fit(text, max(w, 0), ctx, align), :rule} end

    doing =
      if layout.doing_w > 0,
        do: [col.("sprat is", layout.doing_w - 1, :right), sp(1)],
        else: []

    auto_label = if ctx.width < 90, do: "sprat is", else: "autonomy"
    last = if layout.last_w > 0, do: [col.("moved", layout.last_w, :right)], else: []

    Style.line(
      [
        {" ", :text},
        col.("project", layout.name_w, :left),
        col.("roadmap", layout.pos_w + layout.bar_w + 2, :left),
        col.("working on", mid_w - layout.glyph_w - 1, :left),
        sp(1),
        col.("agents", layout.glyph_w, :left)
      ] ++ doing ++ [col.(auto_label, layout.auto_w, :right)] ++ last,
      ctx
    )
  end

  defp project_label(%Project{name: name, root: root}), do: name || Path.basename(root || "?")

  defp project_row(view, %Project{} = p, layout, selected?, dim?, ctx) do
    state = View.project_state(view, p)
    marker = if selected?, do: {"›", :bright}, else: {" ", :text}

    name_style =
      cond do
        selected? -> :bright
        state == :yours -> :bright
        state == :done -> :quiet
        true -> :text
      end

    name = {Style.fit(project_label(p), layout.name_w, ctx), name_style}
    glyphs = session_glyphs(view, p, layout.glyph_w, ctx)

    auto =
      if ctx.width >= 60 and ctx.width < 90 do
        {label, style} = View.doing(view, p)
        {Style.fit(label, layout.auto_w, ctx, :right), style}
      else
        {Style.fit(autonomy_word(p.autonomy), layout.auto_w, ctx, :right), :quiet}
      end

    doing =
      if layout.doing_w > 0 do
        {label, style} = View.doing(view, p)
        [{Style.fit(label, layout.doing_w - 1, ctx, :right), style}, sp(1)]
      else
        []
      end

    last =
      if layout.last_w > 0,
        do: [{Style.fit(last_progress(view, p), layout.last_w, ctx, :right), :quiet}],
        else: []

    segs =
      case layout.mode do
        :one ->
          mid_w =
            ctx.width - 1 - 1 - layout.name_w - layout.pos_w - layout.bar_w - 2 - layout.doing_w -
              layout.auto_w - layout.last_w

          [marker, name] ++
            position_segs(view, p, state, layout, mid_w, glyphs, ctx) ++ doing ++ [auto] ++ last

        :two ->
          :two
      end

    rows =
      case segs do
        :two ->
          first = Style.lr([marker, name, sp(1)] ++ glyphs, [auto, sp(1)], ctx.width, ctx)
          mid_w = ctx.width - 1 - 3 - layout.pos_w - layout.bar_w - 2

          second =
            [{"   ", :text}] ++ position_segs(view, p, state, layout, mid_w, [], ctx)

          [first, second]

        segs ->
          [segs ++ [sp(1)]]
      end

    rows
    |> Enum.map(fn segs -> if dim?, do: dim(segs), else: segs end)
    |> Enum.map(fn segs ->
      if selected? and not dim?, do: Style.highlight(segs, ctx.width - 1, ctx), else: segs
    end)
    |> Enum.map(&Style.line(&1, ctx))
  end

  defp dim(segs) do
    Enum.map(segs, fn
      nil -> nil
      {t, :progress} -> {t, :rule}
      {t, [_ | _] = style} -> {t, if(:reverse in style, do: [:quiet, :reverse], else: :quiet)}
      {t, _} -> {t, :quiet}
    end)
  end

  # Position, bar and item (with glyphs after it) — `width` covers item + glyphs.
  defp position_segs(view, %Project{} = p, state, layout, mid_w, glyphs, ctx) do
    span = layout.pos_w + layout.bar_w + 2 + mid_w

    cond do
      state == :done ->
        [{Style.fit("✓ all phases done", span, ctx), :quiet}]

      is_nil(p.position) ->
        left =
          if p.roadmap,
            do: [{"roadmap read · no position yet", :quiet}],
            else: [{"no roadmap yet · r propose", :quiet}]

        item_and_glyphs(left, glyphs, layout, span, ctx)

      true ->
        pos = p.position
        label = position_label(p)

        [{Style.fit(label, layout.pos_w, ctx), :text}] ++
          bar(pos.done || 0, pos.total, layout.bar_w) ++
          [sp(2)] ++
          item_and_glyphs(
            item_segs(view, p, state, ctx.width >= 60),
            glyphs,
            layout,
            mid_w,
            ctx
          )
    end
  end

  defp item_segs(view, %Project{} = p, state, wide?) do
    pos = p.position
    item = pos.item_text || ""
    inferred = if p.roadmap && p.roadmap.inferred?, do: [{" · inferred", :quiet}], else: []

    suffix =
      case state do
        :stalled ->
          [{" · stalled", :you}]

        # The reset time is in the "doing" column on wide panes.
        :limited ->
          at = View.limited_until(view, p)

          if wide?,
            do: [{" · limited", :quiet}],
            else: [
              {" · limited · resumes " <> hhmm(at, Map.get(view.snapshot, :utc_offset, 0)),
               :quiet}
            ]

        :stuck ->
          [{" · stuck", :stuck}]

        _ ->
          []
      end

    [{item, :text}] ++ inferred ++ suffix
  end

  # The item takes what the glyph column does not; with no glyphs it may
  # run into the glyph column (a limited project's resume time does).
  defp item_and_glyphs(item, [], _layout, width, ctx), do: Style.fit_segs(item, width, ctx)

  defp item_and_glyphs(item, glyphs, layout, width, ctx) do
    gw = max(layout.glyph_w, Style.segs_width(glyphs, ctx))
    Style.fit_segs(item, width - gw - 1, ctx) ++ [sp(1)] ++ Style.fit_segs(glyphs, gw, ctx)
  end

  defp bar(_done, total, width) when total in [nil, 0],
    do: [{String.duplicate("▱", width), :rule}]

  defp bar(done, total, width) do
    filled = round(done * width / total) |> min(width) |> max(0)
    filled = if done > 0 and filled == 0, do: 1, else: filled
    [{String.duplicate("▰", filled), :progress}, {String.duplicate("▱", width - filled), :rule}]
  end

  defp session_glyphs(view, %Project{} = p, width, ctx) do
    p
    |> View.sorted_sessions(view)
    |> Enum.map(&glyph_seg(View.session_state(view, &1)))
    |> Enum.reduce_while({[], 0}, fn {g, _} = seg, {acc, used} ->
      gw = Style.w(g, ctx) + if(acc == [], do: 0, else: 1)
      if used + gw > width, do: {:halt, {acc, used}}, else: {:cont, {[seg | acc], used + gw}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.intersperse({" ", :text})
  end

  defp glyph_seg(:waiting), do: {"⏸", :you}
  defp glyph_seg(:stuck), do: {"⚠", :stuck}
  defp glyph_seg(:busy), do: {"●", :text}
  defp glyph_seg(:finished), do: {"✓", :progress}
  defp glyph_seg(:idle), do: {"◌", :quiet}
  defp glyph_seg(:ended), do: {"·", :quiet}

  defp autonomy_word(:act_resume), do: "act+resume"
  defp autonomy_word(nil), do: ""
  defp autonomy_word(level), do: to_string(level)

  defp last_progress(view, %Project{position: %{last_progress_at: %DateTime{} = at}}) do
    relative(view.snapshot.now, at, Map.get(view.snapshot, :utc_offset, 0))
  end

  defp last_progress(_view, _p), do: ""

  # -- served ------------------------------------------------------------------

  defp served_rule(ctx),
    do: Style.rule("SERVED TODAY", ctx, label: "by sprat unless marked", width: rule_w(ctx))

  defp served_rows(view, served, ctx) do
    offset = Map.get(view.snapshot, :utc_offset, 0)
    nw = if ctx.width >= 60, do: 14, else: 12

    served
    |> Enum.with_index()
    |> Enum.map(fn {s, i} ->
      selected? = view.focus == :served and i == view.served_index
      marker = if selected?, do: {"›", :bright}, else: {" ", :text}
      style = if selected?, do: :bright, else: :quiet
      text = s.text <> if(s.by in [:you, :owner], do: " (you)", else: "")

      Style.line(
        Style.fit_segs(
          [
            marker,
            {hhmm(s.at, offset) <> "  ", :quiet},
            {Style.fit(s.project_name, nw, ctx), style},
            {text, style}
          ],
          ctx.width - 1,
          ctx
        ),
        ctx
      )
    end)
  end

  # == the project screen (§10.6) ==============================================

  defp project_screen(view, root, ctx, avail) do
    p = View.project(view, root)
    offset = Map.get(view.snapshot, :utc_offset, 0)
    items = View.project_items(view, root)
    selected = Enum.at(items, view.project_index)

    right =
      case p.position do
        %{phase_id: ph, done: d, total: t} = pos ->
          vel = if pos.velocity, do: " · #{format_velocity(pos.velocity)} items/day", else: ""
          [{"#{ph} · #{d}/#{t}" <> vel, :quiet}]

        _ ->
          []
      end

    header = header(view, ctx, [project_label(p)], right)
    tickets = for {:ticket, t} <- items, do: t
    opened = view.opened_ticket && View.ticket(view, view.opened_ticket)

    rail =
      case tickets do
        [] ->
          [Style.rule("ON THE RAIL", ctx, label: "rail clear", width: rule_w(ctx), dim?: true)]

        _ ->
          strips =
            Enum.flat_map(tickets, fn t ->
              sel? = match?({:ticket, ^t}, selected)

              [project_strip(view, t, sel?, ctx)] ++
                if(opened && opened.id == t.id, do: opened_box(view, t, ctx), else: [])
            end)

          [Style.rule("ON THE RAIL", ctx, width: rule_w(ctx)) | strips]
      end

    roadmap = roadmap_band(view, p, ctx)
    sessions = sessions_band(view, p, selected, ctx)

    middle =
      if ctx.width >= 140 do
        side_by_side(roadmap, sessions, ctx)
      else
        roadmap ++ [""] ++ sessions
      end

    served =
      case View.served_recent(view, p) |> Enum.take(@max_served) do
        [] ->
          []

        rows ->
          [Style.rule("SERVED", ctx, label: "last 7 days", width: rule_w(ctx))] ++
            Enum.map(rows, fn s ->
              Style.line(
                Style.fit_segs(
                  [
                    {" " <> String.pad_trailing(day_or_time(view.snapshot.now, s.at, offset), 7),
                     :quiet},
                    {s.text, :text}
                  ],
                  ctx.width - 1,
                  ctx
                ),
                ctx
              )
            end)
      end

    sources =
      case p.roadmap && p.roadmap.sources do
        [_ | _] = srcs ->
          [
            Style.line(
              Style.fit_segs(
                [{" sources  ", :quiet}, {Enum.map_join(srcs, " · ", &Path.basename/1), :quiet}],
                ctx.width - 1,
                ctx
              ),
              ctx
            )
          ]

        _ ->
          []
      end

    stack(
      [
        {nil, [header, ""]},
        {nil, rail ++ [""]},
        {nil, middle},
        {2, if(served == [], do: [], else: ["" | served])},
        {1, if(sources == [], do: [], else: ["" | sources])}
      ],
      avail
    )
  end

  # Bands in order; numbered ones are dropped (highest number first) until
  # the rest fits `avail`.
  defp stack(bands, avail) do
    total = bands |> Enum.map(fn {_, l} -> length(l) end) |> Enum.sum()

    droppable =
      bands
      |> Enum.with_index()
      |> Enum.filter(fn {{prio, lines}, _} -> prio && lines != [] end)
      |> Enum.sort_by(fn {{prio, _}, _} -> -prio end)

    case {total > avail, droppable} do
      {true, [{_, idx} | _]} ->
        bands |> List.replace_at(idx, {nil, []}) |> stack(avail)

      _ ->
        Enum.flat_map(bands, fn {_, l} -> l end)
    end
  end

  defp side_by_side(left, right, ctx) do
    lw = div(ctx.width - 3, 2)
    left = Enum.map(left, &Style.pad_painted(&1, lw))
    n = max(length(left), length(right))
    left = pad_list(left, n, String.duplicate(" ", lw))
    right = pad_list(right, n, "")
    Enum.zip_with(left, right, fn l, r -> l <> "  " <> r end)
  end

  defp col_ctx(ctx) do
    if ctx.width >= 140, do: %{ctx | width: div(ctx.width - 3, 2)}, else: ctx
  end

  defp project_strip(view, %Ticket{} = t, selected?, ctx) do
    marker = if selected?, do: {"▌", :bright}, else: {" ", :text}
    body_style = if t.owner == :yours, do: :text, else: :quiet
    text = t.headline |> to_string() |> String.replace("\n", " ")

    left = [
      {" ", :text},
      marker,
      chip(view, t, ctx),
      {" ", :text},
      owner_word(t, 5),
      {" ", :text},
      {text, body_style}
    ]

    right = [
      {"  " <> (t.action_label || default_action(t)),
       if(selected?, do: :bright, else: body_style)},
      sp(1)
    ]

    Style.line(Style.lr(left, right, ctx.width, ctx), ctx)
  end

  defp roadmap_band(view, %Project{} = p, ctx) do
    cctx = col_ctx(ctx)
    width = cctx.width - 1

    case p.roadmap do
      nil ->
        [
          Style.rule("ROADMAP", cctx, width: width),
          Style.line([{" no roadmap yet · w writes one from the project's docs", :quiet}], cctx)
        ]

      roadmap ->
        source =
          if roadmap.confirmed?,
            do: ".sprat/roadmap.md",
            else: roadmap.sources |> List.first() |> basename()

        active_phase = p.position && p.position.phase_id

        rows =
          Enum.flat_map(roadmap.phases, fn ph ->
            done = Enum.count(ph.items, &(&1.state == :done))
            total = length(ph.items)

            {glyph, style} =
              cond do
                total > 0 and done == total -> {"✓", :quiet}
                ph.id == active_phase -> {"▸", :bright}
                true -> {"○", :text}
              end

            head =
              Style.lr(
                [{" " <> glyph <> " ", style}, {ph.id <> "  ", style}, {ph.title, style}],
                [{"#{done}/#{total}", :quiet}, sp(1)],
                width,
                cctx
              )

            items = if ph.id == active_phase, do: phase_items(view, p, ph, width, cctx), else: []
            [Style.line(head, cctx) | items]
          end)

        rows =
          if rows == [] and p.position do
            pos = p.position

            text =
              "#{pos.phase_id} #{pos.phase_title || ""} · #{pos.done}/#{pos.total} · #{pos.item_text || ""}"

            [Style.line([{" ▸ " <> text, :text}], cctx)]
          else
            rows
          end

        [Style.rule("ROADMAP", cctx, label: source, width: width) | rows]
    end
  end

  defp basename(nil), do: "inferred"
  defp basename(path), do: Path.basename(path)

  defp phase_items(view, %Project{} = p, phase, width, ctx) do
    items = phase.items
    active_idx = Enum.find_index(items, &(&1.state in [:active, :blocked])) || 0
    start = max(active_idx - 3, 0)
    shown = items |> Enum.drop(start) |> Enum.take(6)
    hidden = length(items) - start - length(shown)

    shown
    |> Enum.with_index()
    |> Enum.map(fn {item, i} ->
      {glyph, style} =
        case item.state do
          :done -> {"✓", :quiet}
          :active -> {"▸", :bright}
          :blocked -> {"⚠", :stuck}
          _ -> {"○", :text}
        end

      sessions =
        p.sessions
        |> Enum.filter(&(item.branch && &1.branch == item.branch))
        |> Enum.flat_map(fn s ->
          [{"  " <> session_label(s) <> " ", :quiet}, glyph_seg(View.session_state(view, s))]
        end)

      more =
        if i == length(shown) - 1 and hidden > 0, do: [{"   …#{hidden} more", :quiet}], else: []

      reason =
        if item.state == :blocked and item.blocked_reason,
          do: [{" · " <> item.blocked_reason, :stuck}],
          else: []

      Style.line(
        Style.fit_segs(
          [{"      " <> glyph <> " ", style}, {item.text, style}] ++ reason ++ sessions ++ more,
          width,
          ctx
        ),
        ctx
      )
    end)
  end

  defp sessions_band(view, %Project{} = p, selected, ctx) do
    cctx = col_ctx(ctx)
    width = cctx.width - 1
    offset = Map.get(view.snapshot, :utc_offset, 0)
    sessions = View.sorted_sessions(p, view)

    rows =
      Enum.map(sessions, fn s ->
        sel? = match?({:session, %Session{session_id: sid}} when sid == s.session_id, selected)
        state = View.session_state(view, s)
        marker = if sel?, do: {"›", :bright}, else: {" ", :text}
        {g, gs} = if state == :busy, do: spinner(ctx), else: glyph_seg(state)

        segs =
          Style.fit_segs(
            [
              marker,
              {g <> " ", gs},
              {Style.fit(session_label(s), 21, cctx), if(sel?, do: :bright, else: :text)}
            ] ++ session_detail_segs(view, s, state, offset, :quiet),
            width,
            cctx
          )

        Style.line(
          if(sel?, do: Style.highlight(segs, width, cctx), else: segs),
          cctx
        )
      end)

    rows = if rows == [], do: [Style.line([{" no sessions", :quiet}], cctx)], else: rows
    [Style.rule("SESSIONS", cctx, width: width) | rows]
  end

  defp detail_style(:waiting), do: :you
  defp detail_style(:stuck), do: :stuck
  defp detail_style(:finished), do: :progress
  defp detail_style(_), do: :quiet

  defp session_label(%Session{} = s), do: s.name || s.branch || String.slice(s.session_id, 0, 8)

  # `explain?`: whether a quiet session's line carries why, what next and what
  # it last did (the session screen shows those on lines of their own).
  defp session_detail(view, %Session{} = s, state, offset, explain? \\ true) do
    now = view.snapshot.now
    quiet_detail = if explain?, do: &quiet_detail/4, else: fn _v, _s, short, _o -> short end

    case state do
      :waiting ->
        t = Enum.find(view.snapshot.tickets, &(&1.session_id == s.session_id))
        "waiting on you " <> String.downcase(age_label(now, t && t.since))

      :stuck ->
        t = Enum.find(view.snapshot.tickets, &(&1.session_id == s.session_id))
        "stuck · " <> first_line(t && t.headline)

      :busy ->
        explained = quiet(view, s)

        # A running command says more than the title it replaces.
        title =
          if s.title && not match?(%{reason: {:running, _, _}}, explained),
            do: s.title <> " · ",
            else: ""

        title <> working_for(now, s, explained)

      :finished ->
        quiet_detail.(view, s, "finished its turn " <> ago(now, s.status_since), offset)

      :idle ->
        quiet_detail.(
          view,
          s,
          "idle since " <> hhmm(s.status_since || s.last_activity_at, offset),
          offset
        )

      :ended ->
        "ended " <> hhmm(s.last_activity_at, offset)
    end
  end

  @quiet_after_s 5 * 60

  # How long the agent has worked on this turn and, when it has written
  # nothing for a while, how long it has been quiet (a long test run, or
  # hung): the in-progress clock for one agent.
  defp working_for(now, %Session{} = s, explained) do
    turn = s.status_since || s.started_at
    last = s.last_activity_at

    worked = if turn, do: "working " <> short_duration(DateTime.diff(now, turn)), else: "working"

    quiet = if last, do: DateTime.diff(now, last), else: 0

    cond do
      quiet < @quiet_after_s ->
        worked

      # Quiet because a command is still running (a long test run): say so,
      # rather than leave it looking hung.
      match?(%{reason: {:running, _, _}}, explained) ->
        {:running, label, since} = explained.reason
        for_ = if since, do: " for " <> short_duration(DateTime.diff(now, since)), else: ""
        worked <> " · running" <> for_ <> ": " <> label

      true ->
        worked <> " · quiet " <> short_duration(quiet)
    end
  end

  # What `Sprat.Engine.Quiet` says about a session that is not working, or nil
  # (an old daemon's snapshot carries none).
  defp quiet(view, %Session{session_id: sid}),
    do: view.snapshot |> Map.get(:quiet, %{}) |> Map.get(sid)

  # A quiet session's line: why it is quiet (in place of `fallback` when
  # nothing more is known than idle), what it last did, what Sprat will do.
  defp quiet_detail(view, s, fallback, offset) do
    case quiet_parts(view, s, fallback, offset) do
      nil -> fallback
      {why, nil, _reason} -> why
      {why, rest, _reason} -> why <> " · " <> rest
    end
  end

  # The same line split into why (its own colour, so it reads apart from the
  # plan and the last action) and the rest, or nil when nothing is known.
  defp quiet_parts(view, s, fallback, offset) do
    case quiet(view, s) do
      nil ->
        nil

      q ->
        now = view.snapshot.now
        fmt = &hhmm(&1, offset)

        why =
          case q.reason do
            :turn_done -> fallback
            _ -> Sprat.Engine.Quiet.why_text(q, fmt)
          end

        # The plan before the last action: when the row is cut, what Sprat
        # will do is the part that says whether it needs you.
        rest =
          [Sprat.Engine.Quiet.plan_text(q, now, fmt), Sprat.Engine.Quiet.last_text(q, now)]
          |> Enum.reject(&is_nil/1)
          |> case do
            [] -> nil
            parts -> Enum.join(parts, " · ")
          end

        {why, rest, q.reason}
    end
  end

  # A session's detail as segments in `base`, with a quiet session's why in
  # a colour of its own.
  defp session_detail_segs(view, %Session{} = s, state, offset, base)
       when state in [:idle, :finished] do
    now = view.snapshot.now

    fallback =
      if state == :finished,
        do: "finished its turn " <> ago(now, s.status_since),
        else: "idle since " <> hhmm(s.status_since || s.last_activity_at, offset)

    case quiet_parts(view, s, fallback, offset) do
      nil -> [{fallback, base}]
      {why, nil, reason} -> [{why, why_style(reason)}]
      {why, rest, reason} -> [{why, why_style(reason)}, {" · " <> rest, base}]
    end
  end

  defp session_detail_segs(view, s, state, offset, base),
    do: [{session_detail(view, s, state, offset), base}]

  # The session screen's two lines under the header for a session that is
  # not working: why, what it last did, and what Sprat will do next.
  defp quiet_rows(view, s, state, ctx) do
    q = quiet(view, s)

    if q && state in [:idle, :finished, :waiting] do
      offset = Map.get(view.snapshot, :utc_offset, 0)
      now = view.snapshot.now
      fmt = &hhmm(&1, offset)
      last = Sprat.Engine.Quiet.last_text(q, now)
      plan = Sprat.Engine.Quiet.plan_text(q, now, fmt)

      why =
        [{" why   ", :quiet}, {Sprat.Engine.Quiet.why_text(q, fmt), why_style(q.reason)}] ++
          if(last, do: [{" · last: " <> last, :quiet}], else: [])

      next = if plan, do: [[{" next  ", :quiet}, {plan, :text}]], else: []

      Enum.map([why | next], &Style.line(Style.fit_segs(&1, rule_w(ctx), ctx), ctx))
    else
      []
    end
  end

  defp why_style({:limit, _}), do: :stuck
  defp why_style({:question, _}), do: :you
  defp why_style({:permission, _}), do: :you
  defp why_style(_), do: :text

  defp short_duration(s) when s < 60, do: "#{max(s, 0)}s"
  defp short_duration(s) when s < 3600, do: "#{div(s, 60)}m"
  defp short_duration(s), do: "#{div(s, 3600)}h #{rem(div(s, 60), 60)}m"

  # == the session screen ======================================================

  defp session_screen(view, sid, ctx, avail) do
    {s, p} = View.session(view, sid)
    state = View.session_state(view, s)
    offset = Map.get(view.snapshot, :utc_offset, 0)

    header =
      header(
        view,
        ctx,
        [project_label(p), session_label(s)],
        if(state == :busy, do: [spinner(ctx), sp(1)], else: []) ++
          [{session_detail(view, s, state, offset, false), detail_style(state)}, sp(1)]
      )

    surface = mirror_surface(s)
    terminal? = View.mirroring?(view, sid)
    input = session_input(view, sid, s, ctx)
    why = quiet_rows(view, s, state, ctx)
    budget = max(avail - 3 - length(input) - length(why), 1)

    {rule, rows} =
      cond do
        view.session_mode == :recap ->
          recap_band(view, sid, surface, budget, offset, ctx)

        terminal? ->
          # The session's own screen, framed as Claude's window: one row more,
          # since the frame's title replaces the band rule.
          {nil,
           claude_frame(
             View.session_screen(view, sid),
             s,
             surface,
             budget + 2,
             view.mirror_scroll,
             ctx
           )}

        true ->
          right = "⏎ expand · tab recap"
          label = if surface, do: "condensed", else: "condensed · no cmux tab to mirror"

          rows =
            case View.session_lines(view, sid) do
              [] ->
                [Style.line([{" no transcript lines yet", :quiet}], ctx)]

              lines ->
                lines
                |> Enum.with_index()
                |> Enum.map(fn {l, i} -> transcript_rows(l, i, view, offset, ctx) end)
                |> window(view.session_index, budget, ctx)
            end

          {Style.rule("TRANSCRIPT", ctx, label: label, right: right, width: rule_w(ctx)), rows}
      end

    # The message line sits at the bottom, under the session's screen, the
    # way a terminal's prompt does.
    if rule do
      rows = Enum.take(rows, budget)
      [header | why] ++ ["", rule] ++ rows ++ List.duplicate("", budget - length(rows)) ++ input
    else
      # The frame's bottom edge already separates the session from the
      # message line; no second rule.
      [header | why] ++ [""] ++ rows ++ tl(input)
    end
  end

  # == what a session did ======================================================
  #
  # Read from its transcript (and its subagents'), not from a model: who
  # asked what, where each turn ended, the repositories it worked in, its
  # commits, failed test runs and stops. Newest at the bottom.

  defp recap_band(view, sid, surface, budget, offset, ctx) do
    hours = view.recap_hours

    spans =
      Enum.map_join(Keys.recap_hours(), " ", &if(&1 == hours, do: "[#{&1}h]", else: "#{&1}h"))

    next = if surface, do: "tab terminal", else: "tab transcript"

    rule =
      Style.rule("RECAP", ctx,
        label: "last #{hours}h",
        right: "←→ #{spans} · #{next}",
        width: rule_w(ctx)
      )

    rows =
      case View.recap(view, sid) do
        nil ->
          [Style.line([{" reading its transcript" <> Style.ellipsis(ctx), :quiet}], ctx)]

        r ->
          head = recap_head(r, offset, ctx)

          timeline_rows(r.timeline, view.recap_scroll, max(budget - length(head), 1), offset, ctx)
          |> then(&(head ++ &1))
      end

    {rule, rows}
  end

  defp recap_head(r, offset, ctx) do
    c = r.counts

    tests =
      cond do
        c.tests == 0 -> nil
        c.failed > 0 -> "#{c.tests} test runs, #{c.failed} failed"
        true -> "#{c.tests} test runs"
      end

    facts =
      [
        c.you > 0 && plural(c.you, "prompt") <> " from you",
        c.sprat > 0 && "#{c.sprat} from sprat",
        c.turns > 0 && plural(c.turns, "turn"),
        c.edits > 0 && plural(c.edits, "edit"),
        c.commits > 0 && plural(c.commits, "commit"),
        tests,
        c.limits > 0 && plural(c.limits, "usage limit")
      ]
      |> Enum.filter(&is_binary/1)

    first =
      case facts do
        [] ->
          [Style.line([{" nothing in these hours", :quiet}], ctx)]

        _ ->
          facts
          |> Enum.join(" · ")
          |> Style.wrap(ctx.width - 2, ctx)
          |> Enum.map(&Style.line([{" " <> &1, :text}], ctx))
      end

    repos =
      case r.repos do
        [] ->
          []

        list ->
          [
            Style.line(
              Style.fit_segs(
                [{" worked in  ", :quiet}] ++
                  (list
                   |> Enum.map(fn {name, n} -> [{name, :bright}, {" #{n}", :quiet}] end)
                   |> Enum.intersperse([{" · ", :quiet}])
                   |> List.flatten()),
                ctx.width - 1,
                ctx
              ),
              ctx
            )
          ]
      end

    cut =
      if r.cut? and r.from,
        do: [
          Style.line([{" read from #{hhmm(r.from, offset)}; older was not read", :quiet}], ctx)
        ],
        else: []

    first ++ repos ++ cut ++ [""]
  end

  defp timeline_rows([], _scroll, _budget, _offset, ctx),
    do: [Style.line([{" no prompts, turns or commits in these hours", :quiet}], ctx)]

  defp timeline_rows(entries, scroll, budget, offset, ctx) do
    shown = Enum.drop(entries, -min(scroll, max(length(entries) - 1, 0)))
    above = max(length(shown) - budget, 0)
    room = if above > 0, do: budget - 1, else: budget
    above = max(length(shown) - room, 0)

    more =
      if above > 0,
        do: [Style.line([{" …#{above} earlier ↑", :quiet}], ctx)],
        else: []

    more ++
      Enum.map(Enum.take(shown, -room), fn e ->
        {word, style} = recap_word(e.kind)
        time = if e.at, do: hhmm(e.at, offset), else: "     "

        Style.line(
          Style.fit_segs(
            [
              {" " <> time <> "  ", :quiet},
              {String.pad_trailing(word, 8), :quiet},
              {e.text, style}
            ],
            ctx.width - 1,
            ctx
          ),
          ctx
        )
      end)
  end

  defp recap_word(:you), do: {"you", :bright}
  defp recap_word(:sprat), do: {"sprat", :text}
  defp recap_word(:said), do: {"agent", :text}
  defp recap_word(:commit), do: {"commit", :progress}
  defp recap_word(:failed), do: {"failed", :stuck}
  defp recap_word(:stop), do: {"stopped", :stuck}
  defp recap_word(_), do: {"", :text}

  defp mirror_surface(%{surface: "surface:" <> _ = surface}), do: surface
  defp mirror_surface(_), do: nil

  # == a Claude session, mirrored ===============================================
  #
  # The session is Claude Code's, not Sprat's: it sits in a frame titled in
  # Claude's coral, with Sprat's header above and its message line below.
  # cmux hands over plain text only, so the colours inside are rebuilt from
  # the markers Claude Code puts on each kind of line (⏺ ⎿ ❯ ✻, diff
  # numbers); a line without a known marker stays plain text.

  defp claude_frame(text, s, surface, rows, scroll, ctx) do
    # One space of margin, like every band on the board.
    w = rule_w(ctx) - 1
    inner_w = w - 4
    inner_h = max(rows - 2, 1)

    lines =
      case text do
        nil ->
          [[{"reading the session's terminal" <> Style.ellipsis(ctx), :quiet}]]

        text ->
          all = View.mirror_lines(text)
          # Scrolled up: hide the newest `scroll` lines, keeping a page.
          shown = Enum.drop(all, -min(scroll, max(length(all) - inner_h, 0)))

          shown
          |> Enum.take(-inner_h)
          |> Enum.map(&full_rule(&1, inner_w))
          |> Enum.map(&claude_line/1)
      end

    # Newest at the bottom, like the terminal itself.
    lines = List.duplicate([], inner_h - length(lines)) ++ lines

    body =
      Enum.map(lines, fn segs ->
        Style.line(
          [{" │ ", :claude}] ++ Style.fit_segs(segs, inner_w, ctx) ++ [{" │", :claude}],
          ctx
        )
      end)

    [claude_top(s, surface, scroll, w, ctx) | body] ++
      [Style.line([{" ╰" <> String.duplicate("─", max(w - 2, 0)) <> "╯", :claude}], ctx)]
  end

  # Claude Code's input box is ruled across its own terminal; that terminal
  # is seldom exactly as wide as this frame, so a line that is only a rule
  # is drawn across the frame instead of stopping short or running out.
  defp full_rule(line, inner_w) do
    if Regex.match?(~r/^\s*─{8,}\s*$/u, line),
      do: String.duplicate("─", inner_w),
      else: line
  end

  defp claude_top(s, surface, scroll, w, ctx) do
    title = " Claude Code · #{s.name || String.slice(s.session_id, 0, 8)} · #{account_label(s)} "

    right =
      if scroll > 0,
        do: " ↑ #{scroll} lines up · ↓ back to live ",
        else: " live · #{surface} "

    fill = w - 2 - 1 - Style.w(title, ctx) - Style.w(right, ctx) - 1

    segs =
      if fill >= 1,
        do: [
          {"╭─", :claude},
          {title, [:claude, :bold]},
          {String.duplicate("─", fill), :claude},
          {right, :quiet},
          {"─╮", :claude}
        ],
        else: [
          {"╭─", :claude},
          {Style.truncate(title, max(w - 4, 1), ctx), [:claude, :bold]},
          {String.duplicate("─", max(w - 3 - Style.w(title, ctx), 0)), :claude},
          {"╮", :claude}
        ]

    Style.line([{" ", :text} | Style.fit_segs(segs, w, ctx)], ctx)
  end

  defp account_label(%{config_dir: dir}) when is_binary(dir) do
    Regex.replace(~r{^(/Users|/home)/[^/]+(?=/|$)}, dir, "~")
  end

  defp account_label(_), do: "?"

  @status_glyphs ~w(✻ ✶ ✳ ✢ ✽ ✺ * · ∗)

  @doc false
  # One line of Claude Code's screen, coloured the way Claude colours it.
  def claude_line(line) do
    {indent, rest} = split_indent(line)

    segs =
      cond do
        rest == "" ->
          []

        # A tool call: `⏺ Bash(mix test)`, `⏺ elixir-expert(Fix it all)`.
        match = Regex.run(~r/^⏺ ([\w.:-]+)(\(.*)$/u, rest) ->
          [_, name, args] = match
          [{"⏺ ", :progress}, {name, :bright}, {args, :text}]

        String.starts_with?(rest, "⏺") ->
          [{"⏺", :text}, {String.slice(rest, 1..-1//1), :text}]

        String.starts_with?(rest, "⎿") ->
          [{rest, :quiet}]

        # What the owner typed.
        String.starts_with?(rest, "❯") or String.starts_with?(rest, "> ") ->
          [{rest, :bright}]

        # The spinner line: `✻ Baked for 3m 19s`, `✶ Thinking…`.
        status_line?(rest) ->
          [{rest, :claude}]

        # Diff lines in an edit: `12 +  new code`, `13 -  old code`.
        Regex.match?(~r/^\d+\s+\+/, rest) ->
          [{rest, :progress}]

        Regex.match?(~r/^\d+\s+-/, rest) ->
          [{rest, :stuck}]

        Regex.match?(~r/^(Error|error:|✗|⚠)/u, rest) ->
          [{rest, :stuck}]

        # The prompt box's rules and Claude's own status footer.
        Regex.match?(~r/^[─━]{3,}/u, rest) or String.starts_with?(rest, "⏵⏵") or
            String.starts_with?(rest, "►►") ->
          [{rest, :rule}]

        true ->
          [{rest, :text}]
      end

    if indent == "", do: segs, else: [{indent, :text} | segs]
  end

  defp split_indent(line) do
    trimmed = String.trim_leading(line, " ")
    {String.duplicate(" ", String.length(line) - String.length(trimmed)), trimmed}
  end

  defp status_line?(rest) do
    case String.split(rest, " ", parts: 2) do
      [glyph, words] when glyph in @status_glyphs ->
        Regex.match?(~r/^\p{Lu}\p{Ll}+(…| for )/u, words)

      _ ->
        false
    end
  end

  defp session_input(view, sid, s, ctx) do
    name = s.name || String.slice(sid, 0, 8)

    line =
      cond do
        match?(%{purpose: :to_session, ticket_id: ^sid}, view.composer) ->
          text = view.composer.composer.text

          Style.fit_segs(
            [{" › to #{name}  ", :you}, {text <> "▏", :bright}],
            rule_w(ctx),
            ctx
          )

        not s.live? ->
          [{" this session has ended", :quiet}]

        View.session_dialog?(view, sid) ->
          [{" a dialog is open in #{name}: answer it here with 1–9, ↑↓ and ⏎", :you}]

        true ->
          [{" › type to talk to #{name}", :quiet}]
      end

    [Style.rule("", ctx, width: rule_w(ctx)), Style.line(line, ctx)]
  end

  defp transcript_rows(l, i, view, offset, ctx) do
    selected? = i == view.session_index
    expanded? = MapSet.member?(view.session_expanded, i)
    kind = Map.get(l, :kind) || :assistant
    error? = Map.get(l, :error?) == true or kind == :error

    style =
      cond do
        error? -> :stuck
        kind == :user -> :bright
        kind in [:tool, :result] -> :quiet
        true -> :text
      end

    marker = if selected?, do: {"›", :bright}, else: {" ", :text}
    at = Map.get(l, :at)
    time = if at, do: hhmm(at, offset), else: "     "
    word = kind_word(kind)

    text =
      if error?,
        do: "⚠ " <> to_string(Map.get(l, :text, "")),
        else: to_string(Map.get(l, :text, ""))

    lead = [marker, {time <> "  ", :quiet}, {String.pad_trailing(word, 7), :quiet}]
    tw = ctx.width - 1 - 15

    if expanded? do
      case Style.wrap(text, tw, ctx) do
        [] ->
          [Style.line(lead, ctx)]

        [first | more] ->
          [
            Style.line(lead ++ [{first, style}], ctx)
            | Enum.map(more, &Style.line([{String.duplicate(" ", 15), :text}, {&1, style}], ctx))
          ]
      end
    else
      [Style.line(Style.fit_segs(lead ++ [{text, style}], ctx.width - 1, ctx), ctx)]
    end
  end

  defp kind_word(:user), do: "you"
  defp kind_word(:assistant), do: "agent"
  defp kind_word(:tool), do: "tool"
  defp kind_word(:result), do: "result"
  defp kind_word(:error), do: "error"
  defp kind_word(:sprat), do: "sprat"
  defp kind_word(other), do: to_string(other)

  # Groups of rows (one group per logical line), windowed so `sel` stays visible.
  defp window(groups, sel, budget, ctx) do
    total = groups |> Enum.map(&length/1) |> Enum.sum()

    if total <= budget do
      List.flatten(groups)
    else
      start = fit_start(groups, sel, budget - 1)
      {shown, used} = take_groups(Enum.drop(groups, start), budget - 1)
      below = length(groups) - start - used
      more = if below > 0, do: [Style.line([{" …#{below} more ↓", :quiet}], ctx)], else: []
      shown ++ more
    end
  end

  defp fit_start(groups, sel, budget) do
    Enum.reduce_while(sel..0//-1, {sel, 0}, fn i, {_start, used} ->
      h = length(Enum.at(groups, i))
      if used + h > budget and i != sel, do: {:halt, {i + 1, used}}, else: {:cont, {i, used + h}}
    end)
    |> elem(0)
  end

  defp take_groups(groups, budget) do
    Enum.reduce_while(groups, {[], 0, 0}, fn g, {acc, rows, n} ->
      if rows + length(g) > budget and n > 0,
        do: {:halt, {acc, rows, n}},
        else: {:cont, {acc ++ g, rows + length(g), n + 1}}
    end)
    |> then(fn {acc, _rows, n} -> {Enum.take(acc, budget), n} end)
  end

  # == help ====================================================================

  # == help (?): what this screen is, what each part means, the keys ==========

  @help_measure 74

  defp help_screen(view, ctx, avail) do
    lines = help_lines(view, ctx, true)
    lines = if length(lines) <= avail, do: help_lines(view, ctx, false), else: lines
    offset = view.help_index |> min(max(length(lines) - avail, 0)) |> max(0)
    lines |> Enum.drop(offset) |> Enum.take(avail)
  end

  @doc false
  # How far the help page can scroll at this size (the board app clamps to it).
  def help_max_offset(view, opts) do
    ctx = Style.ctx(opts)
    avail = max(ctx.height - length(bottom_lines(view, ctx)), 1)
    max(length(help_lines(view, ctx, true)) - avail, 0)
  end

  defp help_lines(view, ctx, scrolls?) do
    page = Help.page(view)
    measure = min(rule_w(ctx) - 2, @help_measure)

    about =
      page.about
      |> Enum.map(fn para ->
        para
        |> Style.wrap(measure, ctx)
        |> Enum.map(&Style.line([{"  ", :text}, {&1, :text}], ctx))
      end)
      |> Enum.intersperse([""])
      |> List.flatten()

    parts =
      Enum.flat_map(page.parts, fn {heading, rows} ->
        ["", Style.rule(heading, ctx, width: rule_w(ctx))] ++
          Enum.flat_map(rows, &help_part(&1, measure, ctx))
      end)

    keys =
      ["", Style.rule("KEYS", ctx, width: rule_w(ctx))] ++
        Enum.flat_map(page.keys, fn {k, does} -> help_key(k, does, measure, ctx) end)

    crumbs = [help_place(view), "help"]
    right = [{"esc close", :quiet}, sp(1)]

    [
      header(view, ctx, crumbs, right),
      "",
      Style.rule(page.title, ctx,
        label: "what this screen is",
        right: if(scrolls?, do: "↑↓ scroll"),
        width: rule_w(ctx)
      )
    ] ++ about ++ parts ++ keys
  end

  defp help_place(view) do
    case Help.context(view) do
      :board -> "the board"
      :ticket -> "a ticket"
      :brief -> "the brief"
      :project -> project_label(elem(view.screen, 1) |> then(&View.project(view, &1)))
      :session -> "a session"
      :activity -> "activity"
      :processes -> "processes"
    end
  end

  # A part: its sample drawn the way the screen draws it, then what it means.
  # Side by side when there is room; stacked on narrow panes.
  @help_sample_w 18

  defp help_part({sample, text}, measure, ctx) do
    segs = Enum.flat_map(sample, &help_sample/1)

    if ctx.width >= 64 do
      text_w = min(rule_w(ctx) - @help_sample_w - 3, measure)
      [first | more] = Style.wrap(text, text_w, ctx) |> then(&if(&1 == [], do: [""], else: &1))
      pad = String.duplicate(" ", @help_sample_w + 3)

      [
        Style.line(
          [{"  ", :text}] ++
            Style.fit_segs(segs, @help_sample_w, ctx) ++ [{" ", :text}, {first, :quiet}],
          ctx
        )
        | Enum.map(more, &Style.line([{pad, :text}, {&1, :quiet}], ctx))
      ]
    else
      [Style.line([{"  ", :text} | Style.fit_segs(segs, rule_w(ctx) - 2, ctx)], ctx)] ++
        (text
         |> Style.wrap(rule_w(ctx) - 4, ctx)
         |> Enum.map(&Style.line([{"    ", :text}, {&1, :quiet}], ctx)))
    end
  end

  # What has been heard while the owner is still talking, transcribed again
  # every second or so: the newest words, so the end of the line is what
  # they just said.
  defp heard_so_far(%{partial: text}, style, ctx) when is_binary(text) and text != "" do
    room = ctx.width - 6

    text =
      if Style.w(text, ctx) > room, do: Style.ellipsis(ctx) <> tail(text, room - 1), else: text

    [Style.line([{"   ", :text}, {"“" <> text <> "”", style}], ctx)]
  end

  defp heard_so_far(_voice, _style, _ctx), do: []

  defp tail(text, n) do
    g = String.graphemes(text)
    g |> Enum.drop(max(length(g) - n, 0)) |> Enum.join()
  end

  defp help_sample({:chip, role, label}), do: [{" " <> label <> " ", [role, :reverse]}]

  defp help_sample({:glyphs, states}),
    do: states |> Enum.map(&glyph_seg/1) |> Enum.intersperse({" ", :text})

  defp help_sample({:bar, done, total}), do: bar(done, total, 6)
  defp help_sample({text, style}), do: [{text, style}]

  @help_key_w 14

  defp help_key(k, does, measure, ctx) do
    text_w = min(rule_w(ctx) - @help_key_w - 3, measure)

    [first | more] =
      Style.wrap(does, max(text_w, 10), ctx) |> then(&if(&1 == [], do: [""], else: &1))

    pad = String.duplicate(" ", @help_key_w + 2)

    [
      Style.line([{"  " <> Style.fit(k, @help_key_w, ctx), :bright}, {first, :text}], ctx)
      | Enum.map(more, &Style.line([{pad, :text}, {&1, :text}], ctx))
    ]
  end

  # == bottom: status, command line, footer ====================================

  defp bottom_lines(view, ctx) do
    status =
      cond do
        match?(%{purpose: :command}, view.composer) ->
          c = view.composer.composer
          {_row, col} = Composer.cursor_position(c)
          text = insert_at(c.text, col, "▏")

          menu =
            case Composer.menu(c) do
              %{matches: m} -> "   " <> Enum.map_join(m, " ", fn {name, _} -> "/" <> name end)
              nil -> ""
            end

          [
            Style.line(
              Style.fit_segs([{" ", :text}, {text, :bright}, {menu, :quiet}], ctx.width - 1, ctx),
              ctx
            )
          ]

        match?(%{state: :listening}, view.voice) ->
          dot = if rem(div(ctx.frame, 5), 2) == 0, do: "●", else: "○"

          [
            Style.line(
              Style.fit_segs(
                [
                  {" " <> dot <> " ", :stuck},
                  {"listening… ", :bright},
                  {view.voice.hint, :quiet}
                ],
                ctx.width - 1,
                ctx
              ),
              ctx
            )
          ] ++ heard_so_far(view.voice, :text, ctx)

        match?(%{state: :transcribing}, view.voice) ->
          [
            Style.line(
              Style.fit_segs(
                [{" ", :text}, spinner(ctx), {" turning speech into text, on this Mac", :quiet}],
                ctx.width - 1,
                ctx
              ),
              ctx
            )
          ] ++ heard_so_far(view.voice, :quiet, ctx)

        view.status ->
          [
            Style.line(
              Style.fit_segs([{" ", :text}, {view.status, :you}], ctx.width - 1, ctx),
              ctx
            )
          ]

        true ->
          []
      end

    status ++ [footer(view, ctx)]
  end

  defp footer(view, ctx) do
    pairs = footer_pairs(view, ctx)

    # `?` explains the screen, except where `?` is already the page or would
    # be typed into a message.
    help =
      if view.help? or match?(%{purpose: :to_session}, view.composer),
        do: [],
        else: [{"?", "help"}]

    budget = ctx.width - 2 - Enum.sum(Enum.map(help, &pair_w(&1, ctx)))

    {kept, _} =
      Enum.reduce_while(pairs, {[], 0}, fn pair, {acc, used} ->
        w = pair_w(pair, ctx)
        if used + w > budget, do: {:halt, {acc, used}}, else: {:cont, {acc ++ [pair], used + w}}
      end)

    segs =
      Enum.flat_map(kept ++ help, fn {k, label} ->
        [{k, :text}, {" " <> label <> "  ", :quiet}]
      end)

    Style.line([{" ", :text} | segs], ctx)
  end

  defp pair_w({k, label}, ctx), do: Style.w(k, ctx) + 1 + Style.w(label, ctx) + 2

  defp footer_pairs(%View{help?: true}, _ctx), do: [{"↑↓", "scroll"}, {"esc", "close"}]
  defp footer_pairs(%View{overlay: o}, _ctx) when not is_nil(o), do: [{"esc", "close brief"}]

  defp footer_pairs(%View{composer: %{purpose: :command}}, _ctx),
    do: [{"⏎", "run"}, {"tab", "complete"}, {"esc", "cancel"}]

  defp footer_pairs(%View{opened_ticket: id} = view, _ctx) when not is_nil(id) do
    t = View.ticket(view, id)

    cond do
      view.composer ->
        [{"⏎", "save"}, {"esc", "cancel"}]

      t && View.fire_text(view, t) ->
        [{"f", "send"}, {"e", "edit"}, {"x", "dismiss"}, {"←→", "ticket"}, {"esc", "fold"}]

      true ->
        [{"x", "done"}, {"⏎", "session"}, {"←→", "ticket"}, {"esc", "fold"}]
    end
  end

  defp footer_pairs(%View{screen: :board} = view, ctx) do
    narrow? = ctx.width < 60
    t = View.selected_ticket(view)
    fire = if t && View.fire_text(view, t), do: [{"f", "send"}], else: []

    move =
      if narrow?,
        do: [{"←→ ↑↓", "move"}],
        else: [{"←→", "ticket"}, {"↑↓", "project"}]

    case view.focus do
      :line ->
        move ++
          [{"⏎", "open"}, {"A", "autonomy"}, {"r", "roadmap"}, {"b", "brief"}, {"/", "command"}]

      :served ->
        move ++ [{"⏎", "open run"}, {"b", "brief"}, {"/", "command"}]

      _ ->
        if narrow?,
          do: move ++ fire ++ [{"⏎", "open"}, {"x", "dismiss"}],
          else:
            move ++
              [{"⏎", "open"}] ++
              fire ++
              [
                {"x", "dismiss"},
                {"a", "activity"},
                {"space", "talk"},
                {"b", "brief"},
                {"/", "command"}
              ]
    end
  end

  defp footer_pairs(%View{screen: {:project, _}}, _ctx),
    do: [
      {"↑↓", "move"},
      {"⏎", "open"},
      {"f", "send"},
      {"A", "autonomy"},
      {"e", "edit roadmap"},
      {"w", "write roadmap"},
      {"r", "re-read"},
      {"esc", "back"}
    ]

  defp footer_pairs(%View{screen: {:activity, nil}}, _ctx),
    do: [{"↑↓", "scroll"}, {"g", "newest"}, {"p", "processes"}, {"esc", "back"}]

  defp footer_pairs(%View{screen: {:activity, _}}, _ctx),
    do: [{"↑↓", "scroll"}, {"g", "newest"}, {"esc", "back"}]

  defp footer_pairs(%View{screen: {:processes, _}} = view, _ctx) do
    others =
      [{"p", "pulse", :pulse}, {"f", "fish tank", :tank}, {"t", "tree", :tree}]
      |> Enum.map(fn {k, label, mode} ->
        if view.procs_view == mode, do: {k, "grouped"}, else: {k, label}
      end)

    others ++ [{"esc", "back"}]
  end

  defp footer_pairs(%View{screen: {:session, _}, composer: %{purpose: :to_session}}, _ctx),
    do: [{"⏎", "send"}, {"esc", "cancel"}]

  defp footer_pairs(%View{screen: {:session, sid}} = view, _ctx) do
    cond do
      View.session_dialog?(view, sid) ->
        [{"1–9 ↑↓ ⏎", "answer"}, {"tab", "transcript"}, {"esc", "back"}]

      View.mirroring?(view, sid) ->
        [
          {"type", "message"},
          {"↑↓", "scroll"},
          {"space", "talk"},
          {"tab", "transcript"},
          {"^o", "its tab"},
          {"esc", "back"}
        ]

      view.session_mode == :recap ->
        tab =
          case View.session(view, sid) do
            {%{surface: "surface:" <> _}, _} -> [{"tab", "terminal"}, {"^o", "its tab"}]
            _ -> [{"tab", "transcript"}]
          end

        [{"type", "message"}, {"↑↓", "scroll"}, {"←→", "hours"}] ++ tab ++ [{"esc", "back"}]

      true ->
        tab =
          case View.session(view, sid) do
            {%{surface: "surface:" <> _}, _} -> [{"tab", "recap"}, {"^o", "its tab"}]
            _ -> [{"tab", "recap"}]
          end

        [{"type", "message"}, {"↑↓", "scroll"}, {"⏎", "expand"}] ++ tab ++ [{"esc", "back"}]
    end
  end

  # == formatting ==============================================================

  @doc false
  def hhmm(nil, _offset), do: "--:--"

  def hhmm(%DateTime{} = dt, offset) do
    dt = DateTime.add(dt, offset, :second)
    pad2(dt.hour) <> ":" <> pad2(dt.minute)
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  @days ~w(mon tue wed thu fri sat sun)
  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  defp date_label(now, offset) do
    d = now |> DateTime.add(offset, :second) |> DateTime.to_date()
    "#{Enum.at(@days, Date.day_of_week(d) - 1)} #{d.day} #{Enum.at(@months, d.month - 1)}"
  end

  defp day_or_time(now, at, offset) do
    today = View.local_date(now, offset)
    day = View.local_date(at, offset)

    cond do
      day == today -> hhmm(at, offset)
      Date.diff(today, day) == 1 -> "yest"
      true -> "#{Date.diff(today, day)}d"
    end
  end

  defp relative(now, at, offset) do
    days = Date.diff(View.local_date(now, offset), View.local_date(at, offset))

    cond do
      days == 0 -> hhmm(at, offset)
      days == 1 -> "yest"
      true -> "#{days}d ago"
    end
  end

  defp format_velocity(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp format_velocity(v), do: to_string(v)

  @doc false
  def money(%Decimal{} = d, :cents), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)
  def money(%Decimal{} = d, :short), do: d |> Decimal.to_float() |> money(:short)
  def money(n, :cents) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  def money(n, :short) when is_number(n) do
    if n == trunc(n),
      do: Integer.to_string(trunc(n)),
      else: :erlang.float_to_binary(n * 1.0, decimals: 2)
  end

  def money(other, _), do: to_string(other)
end
