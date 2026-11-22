defmodule Mix.Tasks.Sprat.Screenshots do
  @shortdoc "Renders the Pass board's views to PNG screenshots for the website"
  @moduledoc """
  `mix sprat.screenshots [out_dir]` renders the Pass board from demo data
  (the board fixture with every project renamed to a fictional one), turns
  the ANSI output into HTML inside a terminal window, and captures PNGs at 2x
  with headless Chrome. Also writes the `.html` sources next to them.

  Demo data only: nothing from the machine's real sessions is used.
  """
  use Mix.Task

  alias Sprat.Terminal.Board
  alias Sprat.Terminal.Board.{Fixture, View}

  @now ~U[2026-11-23 14:02:00Z]

  # Names to swap in the demo data before it is drawn, longest first. The
  # fixture's names are already fictional; empty until one isn't.
  @renames []

  @bg "#141210"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    out = List.first(args) || "screenshots"
    File.mkdir_p!(out)

    snap = Fixture.snapshot(@now) |> rename()
    base = View.new(snap)

    first_yours = Enum.find(View.rail(base), &(&1.owner == :yours))

    # The story frames of `mix sprat.site`: a job in the NOW band, a
    # session's own terminal, help.
    story = Mix.Tasks.Sprat.Site.story() |> Enum.map(&elem(&1, 1))

    views = [
      {"board", base, 120, 34},
      {"board-pane", base, 88, 40},
      {"now", Enum.at(story, 3), 100, 34},
      {"ticket", %{base | opened_ticket: first_yours.id}, 100, 40},
      {"project", View.clamp(%{base | screen: {:project, "/Users/owner/Projects/cupful"}}), 100,
       36},
      {"session", Enum.at(story, 4), 100, 34},
      {"transcript", %{base | screen: {:session, "cf-4b"}, session_index: 7}, 100, 30},
      {"help", Enum.at(story, 5), 100, 44},
      {"activity", activity(base), 100, 34},
      {"brief", %{base | overlay: {:brief, brief_text()}}, 100, 34},
      {"processes", %{processes(base) | procs_view: :pulse}, 100, 34},
      {"tank", %{processes(base) | procs_view: :tank}, 100, 30},
      {"voice", voice(Enum.at(story, 4)), 100, 34},
      {"narrow", base, 56, 44}
    ]

    for {name, view, w, h} <- views do
      lines =
        Board.render(view, %{width: w, height: h, color: :truecolor, ascii?: false, frame: 0})

      html_path = Path.join(out, name <> ".html")
      File.write!(html_path, html(lines, w, name))
      png = Path.join(out, name <> ".png")
      capture(html_path, png, w, h)
      Mix.shell().info("#{png}  (#{w}×#{h})")
    end
  end

  # The activity screen with a morning's worth of events.
  defp activity(view) do
    at = fn m -> DateTime.add(@now, -m * 60, :second) end
    p = fn name -> "/Users/owner/Projects/" <> name end

    events = [
      %{
        at: at.(1),
        kind: :job,
        project_root: p.("studio"),
        status: :running,
        text: "moving studio-4 to .claude-work · copying the conversation 82/153 MB"
      },
      %{
        at: at.(4),
        kind: :served,
        project_root: p.("dreamboard"),
        status: :ok,
        text: "resumed 2.3 from PAUSE.md"
      },
      %{
        at: at.(6),
        kind: :pm,
        project_root: p.("dreamboard"),
        status: :ok,
        text: "investigated: resume · $0.18"
      },
      %{
        at: at.(9),
        kind: :delivery,
        project_root: p.("cupful"),
        status: :ok,
        text: "sent to cafe-networks-4b via cmux: keep network_id on members"
      },
      %{
        at: at.(14),
        kind: :finding,
        project_root: p.("liftlog-ios"),
        status: :info,
        text: "for you: import the iOS Distribution cert to unblock B.7"
      },
      %{
        at: at.(18),
        kind: :session,
        project_root: p.("homescout"),
        status: :info,
        text: "session homescout-2 started (.claude-work)"
      },
      %{
        at: at.(26),
        kind: :finding,
        project_root: p.("dreamboard"),
        status: :info,
        text: "noticed (P2): no progress on 2.3 for 2 days"
      },
      %{
        at: at.(40),
        kind: :engine,
        project_root: nil,
        status: :failed,
        text: "the slow scan took 6.1s (the board waited)"
      }
    ]

    system = %{
      processes: 214,
      memory_mb: 118,
      uptime_s: 6 * 3600 + 720,
      tasks: 1,
      jobs_running: 1,
      pm_running: 0,
      tree: [
        %{name: "store", alive?: true, queue: 0, memory_kb: 64},
        %{name: "tasks", alive?: true, queue: 0, memory_kb: 6},
        %{name: "sessions ×17", alive?: true, queue: 0, memory_kb: 74},
        %{name: "projects ×9", alive?: true, queue: 0, memory_kb: 33},
        %{name: "cmux", alive?: true, queue: 0, memory_kb: 139},
        %{name: "engine", alive?: true, queue: 0, memory_kb: 17_400}
      ]
    }

    commands = [
      %{
        name: "ps",
        running: 0,
        runs: 10_412,
        avg_ms: 104,
        max_ms: 832,
        last_ms: 98,
        last_status: 0,
        last_at: @now
      },
      %{
        name: "cmux top",
        running: 0,
        runs: 1_440,
        avg_ms: 210,
        max_ms: 556,
        last_ms: 180,
        last_status: 0,
        last_at: @now
      },
      %{
        name: "git log",
        running: 0,
        runs: 324,
        avg_ms: 130,
        max_ms: 388,
        last_ms: 120,
        last_status: 0,
        last_at: @now
      }
    ]

    snap =
      view.snapshot
      |> Map.put(:activity, events)
      |> Map.put(:system, system)
      |> Map.put(:commands, commands)

    %{View.put_snapshot(view, snap) | screen: {:activity, nil}}
  end

  # Talking on a session's screen: the words appear while you speak.
  defp voice(view) do
    %{
      view
      | composer: nil,
        voice: %{
          state: :listening,
          hint: "let go of space to stop · esc cancels",
          partial: "keep network_id on members, one network per"
        }
    }
  end

  # The processes screen: sprat serve's tree a moment after an investigation
  # started and a session was moved, with messages on their way.
  @doc false
  def __processes__(view), do: processes(view)

  defp processes(view) do
    node = fn id, parent, depth, name, kind, reds, kb ->
      %{
        id: id,
        parent: parent,
        depth: depth,
        name: name,
        kind: kind,
        queue: 0,
        memory_kb: kb,
        reductions: reds,
        ref: nil,
        did: nil,
        did_ago_ms: nil
      }
    end

    did = fn n, text, ms -> %{n | did: text, did_ago_ms: ms} end

    # The wall clock of the last reading, and what each session did over the
    # two minutes before it: a few rhythms (testing, editing, a long build,
    # reading around), by session.
    wall = DateTime.to_unix(@now, :millisecond)

    rhythms = [
      [
        {-112, :read, "board.ex"},
        {-108, :edit, "board.ex"},
        {-101, :run, "mix test"},
        {-80, :done, nil},
        {-78, :say, nil},
        {-74, :edit, "view.ex"},
        {-70, :edit, "view.ex"},
        {-66, :run, "mix test"},
        {-41, :fail, nil},
        {-39, :read, "view.ex"},
        {-35, :edit, "view.ex"},
        {-30, :run, "mix test"},
        {-12, :done, nil},
        {-10, :say, nil},
        {-6, :edit, "board.ex"},
        {-2, :run, "mix format"}
      ],
      [
        {-118, :you, nil},
        {-115, :say, nil},
        {-110, :read, "feed.ex"},
        {-100, :read, "feed_test.exs"},
        {-92, :edit, "feed.ex"},
        {-86, :edit, "feed.ex"},
        {-79, :edit, "feed_live.ex"},
        {-60, :edit, "feed.ex"},
        {-52, :say, nil},
        {-44, :edit, "feed.ex"},
        {-30, :edit, "feed.html.heex"},
        {-18, :edit, "feed.ex"},
        {-4, :edit, "feed.ex"}
      ],
      [{-119, :run, "npm run build"}],
      [{-95, :say, nil}, {-90, :ask, nil}],
      [
        {-60, :web, "hexdocs.pm"},
        {-50, :read, "router.ex"},
        {-46, :read, "endpoint.ex"},
        {-40, :agent, "survey the auth code"},
        {-8, :done, nil},
        {-6, :say, nil}
      ]
    ]

    beats = fn i ->
      case Enum.at(rhythms, i) do
        nil -> []
        r -> Enum.map(r, fn {s, k, l} -> {wall + s * 1000, k, l} end)
      end
    end

    # A watcher for every session on the board; two have just read lines.
    all_sessions = for p <- view.snapshot.projects, s <- p.sessions, do: s
    reads = [{1_200, "read 4 new lines"}, {800, "read 12 new lines"}, {21_000, "read 1 new line"}]

    sessions =
      for {s, i} <- Enum.with_index(all_sessions) do
        n =
          node.(
            "s#{i}",
            "sess",
            2,
            "session " <> String.slice(s.session_id, 0, 8),
            :worker,
            1_000 * i,
            160 + 40 * i
          )

        n = %{n | ref: {:session, s.session_id}} |> Map.put(:beats, beats.(i))

        case Enum.at(reads, i) do
          {ms, text} -> did.(n, text, ms)
          nil -> did.(n, "read 2 new lines", 240_000 + 60_000 * i)
        end
      end

    projects =
      for {p, i} <- Enum.with_index(view.snapshot.projects) do
        n = node.("p#{i}", "proj", 2, Path.basename(p.root), :worker, 400 * i, 12)
        n = %{n | ref: {:project, p.root}}
        if i == 2, do: did.(n, "re-read the roadmap and git history", 95_000), else: n
      end

    base_nodes =
      [
        node.("r", nil, 0, "sprat serve", :supervisor, 9_000, 33),
        node.("st", "r", 1, "store", :worker, 40_000, 41),
        node.("t", "r", 1, "tasks", :supervisor, 2_000, 6),
        node.("pm", "t", 2, "investigating dreamboard", :task, 0, 220),
        node.("obs", "r", 1, "observers", :supervisor, 3_000, 21),
        node.("sess", "obs", 1, "sessions", :supervisor, 5_000, 21)
      ] ++
        sessions ++
        [node.("proj", "obs", 1, "projects", :supervisor, 2_000, 5)] ++
        projects ++
        [
          node.("scan", "obs", 1, "session scan", :worker, 200_000, 1100),
          did.(
            node.("eng", "r", 1, "engine", :worker, 300_000, 17_400),
            "checked every session",
            400
          ),
          node.("d", nil, 0, "door", :supervisor, 1_000, 6),
          did.(
            node.("pub", "d", 1, "publisher", :worker, 20_000, 2_400),
            "pushed a change to 1 board",
            300
          ),
          node.("sock", "d", 1, "socket", :worker, 100, 8),
          %{
            did.(
              node.("b1", "sock", 2, "a board", :worker, 20_000, 1_500),
              "sent the change to its board",
              300
            )
            | ref: :board
          }
        ]

    moving = node.("mv", "t", 2, "moving studio-4 to .claude-work", :task, 0, 300)
    first = [moving | base_nodes]

    # A few seconds of readings, so the meters have a history.
    bumps = %{
      "eng" => 220_000,
      "st" => 146_000,
      "scan" => 1_400_000,
      "pub" => 24_000,
      "b1" => 25_000,
      "s1" => 11_000,
      "pm" => 48_000
    }

    waves = [0.4, 1.3, 0.7, 1.0, 0.2, 1.6, 0.9, 1.0]

    # Reductions only grow: each reading adds a varying half-second's work.
    reading = fn k ->
      Enum.map(base_nodes, fn n ->
        added =
          Enum.sum(
            for j <- 1..k,
                do: Map.get(bumps, n.id, 300) * Enum.at(waves, rem(j + String.length(n.id), 8))
          )

        %{n | reductions: n.reductions + round(added)}
      end)
    end

    flows = [
      %{from: "eng", to: "st", count: 34, tag: "call"},
      %{from: "pm", to: "eng", count: 6, tag: "step"},
      %{from: "eng", to: "pub", count: 4, tag: "dirty"},
      %{from: "pub", to: "b1", count: 2, tag: "snapshot"},
      %{from: "s1", to: "eng", count: 3, tag: "reply"}
    ]

    map = fn nodes, at, flows ->
      %{
        nodes: nodes,
        flows: flows,
        processes: 214,
        memory_mb: 118,
        at: at,
        wall_ms: DateTime.to_unix(@now, :millisecond) - 3_500 + at
      }
    end

    view = %{view | screen: {:processes, nil}}

    view = View.put_process_map(view, map.(first, 0, []))

    Enum.reduce(1..7, view, fn k, v ->
      View.put_process_map(v, map.(reading.(k), k * 500, if(k == 7, do: flows, else: [])))
    end)
  end

  defp brief_text do
    """
    brief · mon 23 nov · 9 projects · 4 items done yesterday · 6 nudges, 5 resolved

    cupful: C 3/9; cafe-networks-4b waiting on you 18m (network_id column)
    liftlog-ios: B 5/10; signing cert missing, sprat moved the agent to B.5; you: import the cert
    liftlog: A 7/10, merch checkout done yesterday, on course
    dreamboard: stalled 2 days at 2.3 (onboarding copy); resume prompt ready
    fieldnotes: done 9 days ago; archive or add a roadmap

    net: 2 decisions for you, 1 resume, 5 moving
    """
  end

  # -- demo data ---------------------------------------------------------------

  @doc false
  # Also used by `mix sprat.site`.
  def rename(term) when is_binary(term),
    do: Enum.reduce(@renames, term, fn {a, b}, acc -> String.replace(acc, a, b) end)

  def rename(%DateTime{} = d), do: d
  def rename(%Date{} = d), do: d
  def rename(%MapSet{} = s), do: s |> Enum.map(&rename/1) |> MapSet.new()

  def rename(%{__struct__: mod} = s),
    do: struct(mod, s |> Map.from_struct() |> Map.new(fn {k, v} -> {k, rename(v)} end))

  def rename(m) when is_map(m), do: Map.new(m, fn {k, v} -> {rename(k), rename(v)} end)
  def rename(l) when is_list(l), do: Enum.map(l, &rename/1)

  def rename(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&rename/1) |> List.to_tuple()

  def rename(other), do: other

  # -- ANSI → HTML -------------------------------------------------------------

  defp html(lines, cols, title) do
    body = Enum.map_join(lines, "\n", &ansi_line/1)

    """
    <!doctype html><html><head><meta charset="utf-8"><title>sprat · #{title}</title>
    <style>
      html,body{margin:0;background:transparent}
      .win{display:inline-block;background:#{@bg};border-radius:12px;overflow:hidden;
           box-shadow:0 0 0 1px #2a2621}
      .bar{height:30px;display:flex;align-items:center;gap:8px;padding:0 14px;background:#1c1916;
           border-bottom:1px solid #26221d;font:12px -apple-system,system-ui,sans-serif;color:#7c7468}
      .dot{width:12px;height:12px;border-radius:50%;background:#3a352e}
      .bar span{margin-left:10px}
      pre{margin:0;padding:14px 16px 16px;font:13px/18px "SF Mono",Menlo,"JetBrains Mono",monospace;
          color:#efe8da;white-space:pre;width:#{cols}ch;font-variant-ligatures:none}
      b{font-weight:700} .f{opacity:.55} .r{filter:invert(0)}
      i.g{font-style:normal;display:inline-block;width:1ch;text-align:center;overflow:visible}
      i.gs{font-style:normal;display:inline-block;white-space:pre;overflow:visible}
    </style></head><body><div class="win"><div class="bar"><i class="dot"></i><i class="dot"></i><i class="dot"></i><span>sprat</span></div><pre>#{body}</pre></div></body></html>
    """
  end

  defp ansi_line(line) do
    {html, _st} =
      Regex.split(~r/\e\[[0-9;]*m/, line, include_captures: true)
      |> Enum.reduce({"", %{}}, fn part, {acc, st} ->
        if String.starts_with?(part, "\e[") do
          {acc, apply_sgr(st, part)}
        else
          if part == "", do: {acc, st}, else: {acc <> span(part, st), st}
        end
      end)

    html
  end

  defp apply_sgr(st, seq) do
    codes =
      seq
      |> String.trim_leading("\e[")
      |> String.trim_trailing("m")
      |> String.split(";", trim: true)

    codes = if codes == [], do: ["0"], else: codes
    sgr(codes, st)
  end

  defp sgr([], st), do: st
  defp sgr(["0" | rest], _st), do: sgr(rest, %{})
  defp sgr(["1" | rest], st), do: sgr(rest, Map.put(st, :bold, true))
  defp sgr(["2" | rest], st), do: sgr(rest, Map.put(st, :faint, true))
  defp sgr(["7" | rest], st), do: sgr(rest, Map.put(st, :reverse, true))
  defp sgr(["22" | rest], st), do: sgr(rest, st |> Map.delete(:bold) |> Map.delete(:faint))
  defp sgr(["27" | rest], st), do: sgr(rest, Map.delete(st, :reverse))
  defp sgr(["39" | rest], st), do: sgr(rest, Map.delete(st, :fg))

  defp sgr(["38", "2", r, g, b | rest], st),
    do: sgr(rest, Map.put(st, :fg, "rgb(#{r},#{g},#{b})"))

  defp sgr([_ | rest], st), do: sgr(rest, st)

  defp span(text, st) when map_size(st) == 0, do: Mix.Tasks.Sprat.Site.one_cell(escape(text))

  defp span(text, st) do
    fg = st[:fg] || "#efe8da"

    style =
      if st[:reverse],
        do: "background:#{fg};color:#{@bg};",
        else: "color:#{fg};"

    style = if st[:bold], do: style <> "font-weight:700;", else: style
    style = if st[:faint], do: style <> "opacity:.55;", else: style
    ~s(<span style="#{style}">#{Mix.Tasks.Sprat.Site.one_cell(escape(text))}</span>)
  end

  defp escape(t),
    do:
      t
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  # -- capture -----------------------------------------------------------------

  defp capture(html_path, png, cols, rows) do
    chrome =
      System.get_env("CHROME") ||
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    # 13px SF Mono ≈ 7.83px per column; 18px rows; padding + title bar.
    w = round(cols * 7.83) + 32 + 24
    h = rows * 18 + 30 + 30 + 2

    {_, 0} =
      System.cmd(
        chrome,
        [
          "--headless=new",
          "--disable-gpu",
          "--hide-scrollbars",
          "--default-background-color=00000000",
          "--force-device-scale-factor=2",
          "--window-size=#{w},#{h}",
          "--screenshot=#{Path.expand(png)}",
          "file://" <> Path.expand(html_path)
        ],
        stderr_to_stdout: true
      )
  end
end
