defmodule Sprat.Engine.ProcessMapTest do
  # The processes screen: sprat serve's tree, and who messages whom.
  use ExUnit.Case, async: true

  alias Sprat.Engine.{ProcessMap, Tracer}
  alias Sprat.Terminal.Board
  alias Sprat.Terminal.Board.{Fixture, Keys, View}

  defmodule Pinger do
    use GenServer
    def start_link(peer), do: GenServer.start_link(__MODULE__, peer)

    def init(peer) do
      ProcessMap.label("pinger")
      ProcessMap.ref({:session, "pinger-session"})
      ProcessMap.did("started pinging")
      send(self(), :ping)
      {:ok, peer}
    end

    def handle_info(:ping, peer) do
      if pid = Process.whereis(peer), do: send(pid, {:ping, self()})
      Process.send_after(self(), :ping, 5)
      {:noreply, peer}
    end

    def handle_info(_, peer), do: {:noreply, peer}
  end

  defmodule Ponger do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(_), do: {:ok, nil}

    def handle_info({:ping, from}, s) do
      send(from, :pong)
      {:noreply, s}
    end
  end

  setup do
    n = System.unique_integer([:positive])
    sup = :"sup#{n}"
    tasks = :"tasks#{n}"
    ponger = :"ponger#{n}"
    tracer = :"tracer#{n}"

    start_supervised!(%{
      id: sup,
      start:
        {Supervisor, :start_link,
         [
           [
             %{id: :ponger, start: {Ponger, :start_link, [ponger]}},
             %{id: :pinger, start: {Pinger, :start_link, [ponger]}},
             {Task.Supervisor, name: tasks}
           ],
           [strategy: :one_for_one, name: sup]
         ]},
      type: :supervisor
    })

    start_supervised!({Tracer, name: tracer, every_ms: 20, window_ms: 100})
    %{sup: sup, tasks: tasks, tracer: tracer}
  end

  test "the tree: supervisors, workers by their label, depth and parent", %{
    sup: sup,
    tracer: tracer
  } do
    map = ProcessMap.snapshot(roots: [{sup, "sprat serve"}], tracer: tracer)
    [root | children] = map.nodes

    assert %{name: "sprat serve", kind: :supervisor, depth: 0, parent: nil} = root
    names = Enum.map(children, & &1.name)
    assert "pinger" in names
    assert Enum.all?(children, &(&1.parent == root.id and &1.depth == 1))

    # What it stands for and the last thing it did, for the grouped view.
    pinger = Enum.find(children, &(&1.name == "pinger"))
    assert pinger.ref == {:session, "pinger-session"}
    assert pinger.did == "started pinging"
    assert is_integer(pinger.did_ago_ms) and pinger.did_ago_ms >= 0
    assert Enum.find(children, &(&1.name != "pinger")).ref == nil
    assert map.processes > 0 and map.memory_mb > 0
  end

  test "messages are sampled only while asked, then counted per sender and receiver",
       %{sup: sup, tracer: tracer} do
    first = ProcessMap.snapshot(roots: [{sup, "sprat serve"}], tracer: tracer)
    assert first.flows == []

    flows =
      Enum.find_value(1..40, fn _ ->
        Process.sleep(50)
        f = ProcessMap.snapshot(roots: [{sup, "sprat serve"}], tracer: tracer).flows
        f != [] && f
      end)

    names = Map.new(first.nodes, &{&1.id, &1.name})
    pairs = Enum.map(flows, &{names[&1.from], names[&1.to], &1.tag})
    assert {"pinger", "ponger", "ping"} in pairs
    assert {"ponger", "pinger", "pong"} in pairs
  end

  test "message kinds in a word" do
    assert Tracer.tag({:"$gen_call", {self(), make_ref()}, {:command, :x}}) == "call command"
    assert Tracer.tag({:"$gen_call", {self(), make_ref()}, {:call, :x}}) == "call"
    assert Tracer.tag({:"$gen_cast", :dirty}) == "cast dirty"
    assert Tracer.tag({:sprat_snapshot, %{}}) == "snapshot"
    assert Tracer.tag({make_ref(), :ok}) == "reply"
    assert Tracer.tag("text") == "message"
  end

  describe "the screen" do
    @now ~U[2026-11-23 14:02:00Z]

    defp node(id, parent, depth, name, kind, reds),
      do: %{
        id: id,
        parent: parent,
        depth: depth,
        name: name,
        kind: kind,
        queue: 0,
        memory_kb: 40,
        reductions: reds
      }

    defp did(node, ref, text, ms), do: Map.merge(node, %{ref: ref, did: text, did_ago_ms: ms})

    # The daemon's parts and a watcher for session cf-4b (cafe-networks-4b in
    # the fixture) that has just read four lines.
    defp sprat_nodes(watcher_ms \\ 500) do
      [
        node("r", nil, 0, "sprat serve", :supervisor, 0),
        node("t", "r", 1, "tasks", :supervisor, 0),
        node("pm", "t", 2, "investigating dreamboard", :task, 0),
        node("ss", "r", 1, "sessions", :supervisor, 0),
        did(
          node("w", "ss", 2, "session cf-4b", :worker, 0),
          {:session, "cf-4b"},
          "read 4 new lines",
          watcher_ms
        ),
        did(node("e", "r", 1, "engine", :worker, 0), nil, "checked every session", 300),
        node("st", "r", 1, "store", :worker, 0),
        node("d", nil, 0, "door", :supervisor, 0),
        did(node("p", "d", 1, "publisher", :worker, 0), nil, "pushed a change to 1 board", 200),
        node("so", "d", 1, "socket", :worker, 0),
        did(
          node("b", "so", 2, "a board", :worker, 0),
          :board,
          "sent the change to its board",
          100
        )
      ]
    end

    defp map(at, nodes, flows \\ []),
      do: %{nodes: nodes, flows: flows, processes: 214, memory_mb: 118, at: at}

    defp text(view, w \\ 100, opts \\ %{}) do
      view
      |> Board.render(
        Map.merge(%{width: w, height: 30, color: :none, ascii?: false, frame: 0}, opts)
      )
      |> Enum.map_join("\n", &String.trim_trailing/1)
      |> String.replace(~r/\e\[[0-9;]*m/, "")
    end

    defp view(mode \\ :tree),
      do: %{View.new(Fixture.snapshot(@now)) | screen: {:processes, nil}, procs_view: mode}

    test "p opens it from activity; esc goes back" do
      v = %{View.new(Fixture.snapshot(@now)) | screen: {:activity, nil}}
      assert {%{screen: {:processes, nil}} = v, []} = Keys.handle(v, {:char, "p"})
      assert View.animating?(v)
      assert {%{screen: {:activity, nil}}, []} = Keys.handle(v, :esc)
      assert text(v) =~ "reading sprat serve's processes"
    end

    test "the tree with work meters, what is new and what ended; lanes of messages" do
      root = node("r", nil, 0, "sprat serve", :supervisor, 1_000)
      eng = node("e", "r", 1, "engine", :worker, 10_000)
      tasks = node("t", "r", 1, "tasks", :supervisor, 100)
      pm = node("pm", "t", 2, "investigating dreamboard", :task, 0)
      old = node("old", "t", 2, "moving studio-4", :task, 0)
      pub = node("p", "r", 1, "publisher", :worker, 50)

      v =
        view()
        |> View.put_process_map(map(0, [root, eng, tasks, old, pub]))
        |> View.put_process_map(
          map(
            1_000,
            [root, %{eng | reductions: 60_000}, tasks, pm, pub],
            [%{from: "e", to: "p", count: 12, tag: "cast dirty"}]
          )
        )

      assert v.procs.rates["e"] == [50_000.0]
      assert Map.has_key?(v.procs.born, "pm")
      assert [%{node: %{id: "old"}}] = v.procs.gone

      t = text(v)
      assert t =~ "processes  › " or t =~ "› processes"
      assert t =~ "214 BEAM processes · 118 MB"
      assert t =~ ~r/├─ ● engine .* 50\.0k/
      # The ended task keeps its row; the newcomer joins after it.
      assert t =~ ~r/│  ├─ · moving studio-4  ended/
      assert t =~ ~r/│  └─ ⠋ investigating dreamboard  new/
      assert t =~ ~r/engine +─*●.*▶ publisher +cast dirty +30/u
      assert text(v, 72, %{ascii?: true}) =~ ~r/engine +-*o.*> publisher/

      # A quiet sample: the lane rests a moment instead of blinking out.
      quiet = View.put_process_map(v, map(1_500, [root, eng, tasks, pm, pub]))
      assert text(quiet) =~ ~r/engine +─+▶ publisher +cast dirty +-/u

      # Ended, a few seconds later: gone from the screen.
      later = View.put_process_map(v, map(5_500, [root, eng, tasks, pm, pub]))
      refute text(later) =~ "moving studio-4"
      refute text(later) =~ "new"
      assert text(later) =~ "nothing sent in the last sample"
    end

    test "a crowd under one supervisor: the most recently busy, the rest counted" do
      root = node("r", nil, 0, "sessions", :supervisor, 0)
      kids = for i <- 1..12, do: node("s#{i}", "r", 1, "session #{i}", :worker, 0)
      busy = %{hd(kids) | reductions: 100_000}

      v =
        view()
        |> View.put_process_map(map(0, [root | kids]))
        |> View.put_process_map(map(1_000, [root, busy | tl(kids)]))

      t = text(v)
      assert t =~ "session 1 "
      refute t =~ "session 7 "
      # Always five rows for the crowd, whoever is busy.
      assert t =~ "└─ 7 more, resting"
      assert t =~ "nothing sent in the last sample"

      # Session 9 gets busy: it takes a row from one that has done nothing,
      # and session 1, busy a moment ago, keeps its own.
      s9 = Enum.at(kids, 8)
      busy9 = %{s9 | reductions: 100_000}
      kids2 = List.replace_at([busy | tl(kids)], 8, busy9)
      t2 = text(View.put_process_map(v, map(2_000, [root | kids2])))
      assert t2 =~ "session 1 "
      assert t2 =~ "session 9 "
      assert t2 =~ "└─ 7 more, resting"
    end

    test "rows stay put: the same number of lines whatever comes and goes" do
      root = node("r", nil, 0, "sprat serve", :supervisor, 0)
      tasks = node("t", "r", 1, "tasks", :supervisor, 0)
      pub = node("p", "r", 1, "publisher", :worker, 0)
      job = node("j", "t", 2, "a job", :task, 0)

      v = View.put_process_map(view(), map(0, [root, tasks, pub]))

      busy =
        View.put_process_map(
          v,
          map(1_000, [root, tasks, job, pub], [
            %{from: "p", to: "t", count: 3, tag: "cast"}
          ])
        )

      lines = fn v -> String.split(text(v), "\n") end
      assert length(lines.(v)) == length(lines.(busy))
      # The messages section starts on the same row either way.
      at = fn v -> Enum.find_index(lines.(v), &(&1 =~ "MESSAGES")) end
      assert at.(v) == at.(busy)
    end

    test "? opens its help page" do
      {v, []} = Keys.handle(view(), {:char, "?"})
      assert v.help?
      t = text(v)
      assert t =~ "› processes  › help"
      assert Board.help_max_offset(v, %{width: 100, height: 30, color: :none, ascii?: false}) >= 0
    end

    test "grouped: sessions under their projects, the parts, the hops to this screen" do
      v = View.put_process_map(view(:story), map(0, sprat_nodes()))
      t = text(v, 110, %{height: 50})

      assert t =~ "CLAUDE SESSIONS"
      assert t =~ ~r/\n  cupful\n/
      assert t =~ ~r/⏸ cafe-networks-4b +waiting on you .* read 4 new lines · now/
      # A session without a watcher says so.
      assert t =~ "no watcher"
      assert t =~ ~r/◆ engine +decides what each session needs +checked every session · now/
      assert t =~ ~r/◆ your board +this screen's line to sprat serve/
      assert t =~ "investigating dreamboard"
      assert t =~ ~r/plumbing +2 helpers · 80 KB +all quiet/
      # The hops, sparks on them while the change is new.
      assert t =~ ~r/cafe-networks-4b ─*●─*▶ watcher .*▶ engine .*▶ publisher .*▶ your board/u
      assert t =~ "read 4 new lines"
      refute t =~ "PROCESSES ─"

      # A minute later: quiet tracks, "last read".
      old = View.put_process_map(view(:story), map(0, sprat_nodes(125_000)))
      t = text(old, 110, %{height: 50})
      assert t =~ "last read 2m ago"
      refute t =~ ~r/cafe-networks-4b ─*●/u

      # Narrow: no meters, the hops one under another.
      narrow = text(v, 64, %{height: 50})
      assert narrow =~ "↓ watcher  read 4 new lines"
    end

    test "grouped: a daemon from before refs is matched by its labels" do
      nodes =
        Enum.map(sprat_nodes(), &Map.drop(&1, [:ref, :did, :did_ago_ms]))

      t = text(View.put_process_map(view(:story), map(0, nodes)), 110, %{height: 50})
      assert t =~ ~r/⏸ cafe-networks-4b +waiting on you .* watching/
      assert t =~ "nothing new from a Claude session yet"
    end

    test "p, f and t switch views; the same key goes back to grouped" do
      v = view(:story)
      assert {%{procs_view: :pulse} = v, []} = Keys.handle(v, {:char, "p"})
      assert {%{procs_view: :tank} = v, []} = Keys.handle(v, {:char, "f"})
      assert {%{procs_view: :tree} = v, []} = Keys.handle(v, {:char, "t"})
      assert {%{procs_view: :story}, []} = Keys.handle(v, {:char, "t"})
      assert View.new().procs_view == :story
    end

    # Two minutes of what cafe-networks-4b did, ending at the reading.
    defp with_beats(nodes, wall) do
      beats = [
        {wall - 100_000, :read, "board.ex"},
        {wall - 90_000, :edit, "board.ex"},
        {wall - 60_000, :run, "mix test"},
        {wall - 30_000, :fail, nil},
        {wall - 10_000, :edit, "view.ex"}
      ]

      Enum.map(nodes, fn
        %{id: "w"} = n -> Map.put(n, :beats, beats)
        n -> n
      end)
    end

    test "the pulse: a lane of marks per session, the latest at its end" do
      wall = 1_800_000_000_000
      m = Map.put(map(0, with_beats(sprat_nodes(), wall)), :wall_ms, wall)
      v = View.put_process_map(view(:pulse), m)
      t = text(v, 130, %{height: 50})

      assert t =~ "PULSE"
      assert t =~ ~r/⏸ cafe-networks-4b +.*◦.*✎.*▶─+✗.*✎/u
      assert t =~ "waiting on you"
      # The command's bar runs from its start to the next beat.
      assert t =~ ~r/▶─{10,}✗/u
      assert t =~ ~r/engine .* checks every session/
      assert t =~ ~r/your board .* redrawn \d+× a minute/
      refute text(v, 130, %{height: 50, ascii?: true}) =~ ~r/[✎▶◦✗⋅]/u
    end

    test "the tank: a fish per live session, where its state puts it" do
      v = View.put_process_map(view(:tank), map(0, sprat_nodes()))

      for {w, h} <- [{120, 40}, {100, 30}, {72, 24}, {50, 20}], frame <- [0, 7, 300] do
        lines = Board.render(v, %{width: w, height: h, color: :none, ascii?: false, frame: frame})
        t = lines |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
        assert length(lines) == h

        assert Enum.all?(
                 lines,
                 &(Sprat.Terminal.Width.width(String.replace(&1, ~r/\e\[[0-9;]*m/, "")) <= w)
               )

        if w >= 72, do: assert(t =~ "cafe-networks-4b · needs you")
      end

      t = text(v, 120, %{height: 40})
      lines = String.split(t, "\n")
      # Needs you: at the surface. Finished: on the sand.
      surface = Enum.find_index(lines, &(&1 =~ "needs you"))
      sand = Enum.find_index(lines, &(&1 =~ "liftlog-ios-12 · finished"))
      assert surface <= 4
      assert sand > 30
      assert t =~ ~r/><\(\(\(°>|<°\)\)\)></

      ascii = text(v, 120, %{height: 40, ascii?: true})
      refute ascii =~ ~r/[°～▁▂▃]/u

      assert text(v, 120, %{reduced_motion?: true, frame: 5}) ==
               text(v, 120, %{reduced_motion?: true, frame: 9})
    end

    test "an older daemon says to restart it" do
      v = View.put_process_error(view(), :old_daemon)
      assert text(v) =~ "older than the processes screen"
    end
  end
end
