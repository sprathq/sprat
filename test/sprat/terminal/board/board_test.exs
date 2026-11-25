defmodule Sprat.Terminal.BoardTest do
  use ExUnit.Case, async: true

  alias Sprat.Observer.Model.{Account, Finding, Position, Project, Roadmap, Session, Ticket}
  alias Sprat.Terminal.{Board, Width}
  alias Sprat.Terminal.Board.{Fixture, View}

  @now ~U[2026-11-23 14:02:00Z]
  @golden "test/fixtures/v4/board"

  defp view(opts \\ []) do
    snap = Fixture.snapshot(@now)
    snap = Keyword.get(opts, :map, & &1).(snap)
    View.new(snap)
  end

  defp render(view, w, h, opts \\ %{}) do
    Board.render(
      view,
      Map.merge(%{width: w, height: h, color: :none, ascii?: false, frame: 0}, opts)
    )
  end

  defp plain(lines), do: Enum.map(lines, &(&1 |> Width.strip_ansi() |> String.trim_trailing()))
  defp text(lines), do: lines |> plain() |> Enum.join("\n")

  defp assert_fits(lines, w, h) do
    assert length(lines) == h

    for l <- lines,
        do: assert(Width.width(l) <= w, "line wider than #{w}: #{inspect(Width.strip_ansi(l))}")
  end

  defp golden(name, lines) do
    path = Path.join(@golden, name <> ".txt")
    actual = Enum.join(plain(lines), "\n") <> "\n"

    if System.get_env("UPDATE_GOLDEN") == "1" do
      File.mkdir_p!(@golden)
      File.write!(path, actual)
    end

    assert actual == File.read!(path), "golden #{path} differs; UPDATE_GOLDEN=1 to accept"
  end

  defp open(view), do: %{view | opened_ticket: View.selected_ticket(view).id}

  describe "widths (§10.5)" do
    test "120 columns: four cards, more marker, last-progress column" do
      lines = render(view(), 120, 40)
      assert_fits(lines, 120, 40)
      t = text(lines)
      card_row = lines |> plain() |> Enum.find(&String.contains?(&1, "┏"))
      assert length(String.split(card_row, ["┏", "┌"])) - 1 == 4
      assert t =~ "+1 more →"
      assert t =~ "2d ago"
      golden("board_120", lines)
    end

    test "84 and 88 columns: three outlined cards" do
      for w <- [84, 88] do
        lines = render(view(), w, 40)
        assert_fits(lines, w, 40)
        card_row = lines |> plain() |> Enum.find(&String.contains?(&1, "┏"))
        assert length(String.split(card_row, ["┏", "┌"])) - 1 == 3
        assert text(lines) =~ "+2 more →"
        assert text(lines) =~ "liftlog-ios"
      end

      golden("board_88", render(view(), 88, 40))
      golden("board_84", render(view(), 84, 40))
    end

    test "60 to 83 columns: one-line strips, every ticket on the rail" do
      lines = render(view(), 72, 40)
      assert_fits(lines, 72, 40)
      t = text(lines)
      refute t =~ "┏"
      assert t =~ "▌ 25M  yours liftlog-ios"

      for name <- ~w(liftlog-ios cupful tipjar homescout dreamboard),
          do: assert(t =~ name)

      golden("board_72", lines)
    end

    test "56 columns: two-line strips and two-line project rows" do
      lines = render(view(), 56, 50)
      assert_fits(lines, 56, 50)
      p = plain(lines)
      i = Enum.find_index(p, &(&1 =~ "yours liftlog-ios"))
      assert Enum.at(p, i + 1) =~ "import the iOS"
      j = Enum.find_index(p, &String.starts_with?(&1, " cupful"))
      assert Enum.at(p, j + 1) =~ "C 3/9"
      golden("board_56", lines)
    end

    test "every width and height stays inside the terminal, on every screen" do
      base = view()

      views = [
        base,
        open(base),
        %{base | rail_index: 1} |> open(),
        %{base | focus: :line, line_index: 4},
        %{base | screen: {:project, "/Users/owner/Projects/cupful"}},
        %{base | screen: {:session, "cf-4b"}, session_expanded: MapSet.new([7])},
        %{base | help?: true},
        View.new(%{now: @now, projects: [], tickets: [], served: []})
      ]

      for v <- views,
          w <- [20, 33, 45, 59, 60, 75, 89, 90, 119, 120, 140, 180],
          h <- [5, 12, 24, 41],
          ascii <- [true, false] do
        assert_fits(render(v, w, h, %{ascii?: ascii, color: :truecolor}), w, h)
      end
    end
  end

  describe "height" do
    test "engine-shaped snapshot with nils everywhere renders" do
      now = @now
      past = DateTime.add(now, -3600)
      soon = DateTime.add(now, 70 * 60)

      snap = %{
        now: now,
        projects: [
          %Project{
            root: "/p/bare",
            config_dirs: ["/c/a"],
            sessions: [%Session{session_id: "s1", config_dir: "/c/a"}]
          },
          %Project{root: "/p/roadmap-only", roadmap: %Roadmap{}, position: nil},
          %Project{root: "/p/thin-pos", name: nil, position: %Position{}, config_dirs: ["/c/b"]},
          %Project{
            root: "/p/old-limit",
            position: %Position{phase_id: "A", done: 1, total: 3},
            config_dirs: ["/c/old"]
          }
        ],
        tickets: [
          %Ticket{id: "t1", owner: :yours, project_root: "/p/bare"},
          %Ticket{id: "t2", owner: :sprat, project_root: "/p/gone", session_id: "nope", did: nil}
        ],
        served: [],
        accounts: [
          %Account{config_dir: "/c/b", limited_until: soon},
          %Account{config_dir: "/c/old", limited_until: past}
        ],
        header: %{pm_spend: nil, fleet_cap: nil, limited_accounts: [], pm_running: 0, sessions: 1}
      }

      base = View.new(snap)

      for v <- [
            base,
            %{base | opened_ticket: "t1"},
            %{base | opened_ticket: "t2"},
            %{base | screen: {:project, "/p/bare"}},
            %{base | screen: {:project, "/p/roadmap-only"}},
            %{base | screen: {:session, "s1"}}
          ],
          w <- [40, 72, 100, 150] do
        assert_fits(render(v, w, 30), w, 30)
      end

      t = text(render(base, 100, 30))
      assert t =~ "thin-pos"
      assert t =~ "limited"
      assert t =~ "resumes 15:12"
      refute t =~ ~r/old-limit.*limited/
      assert t =~ "roadmap read · no position yet"
      assert t =~ "no roadmap yet"
      assert text(render(base, 100, 30)) =~ ~r/--\s+yours bare/
    end

    test "a short pane drops served first, then truncates the line; never the rail" do
      lines = render(view(), 100, 20)
      t = text(lines)
      refute t =~ "SERVED TODAY"
      assert t =~ ~r/…\d+ more/
      assert t =~ "+2 more →"
      assert length(lines |> plain() |> Enum.filter(&(&1 =~ "┏" or &1 =~ "┌"))) == 1
      golden("board_100_short", lines)
    end

    test "strips are never cut even when the line goes" do
      lines = render(view(), 72, 12)
      t = text(lines)

      for name <- ~w(liftlog-ios cupful tipjar homescout dreamboard),
          do: assert(t =~ name)
    end
  end

  describe "bands" do
    test "header shows spend, fish and clock" do
      [header | _] = plain(render(view(), 88, 30))
      assert header =~ "SPRAT <•<"
      assert header =~ "mon 23 nov  14:02 · pm $2.40/15"
    end

    test "empty rail collapses to one dim line" do
      v = view(map: &%{&1 | tickets: []})
      t = text(render(v, 88, 30))
      assert t =~ "ON THE RAIL ─ clear · nothing needs attention"
      assert text(render(v, 88, 30)) =~ "SPRAT ><>"
    end

    test "the line sorts by worst state and shows positions, limits, what sprat is doing and autonomy" do
      p = plain(render(view(), 88, 40))

      rows =
        Enum.filter(
          p,
          &(&1 =~
              ~r/^[ ›](cupful|liftlog-ios|dreamboard|liftlog |forge|homescout|tipjar|studio|fieldnotes)/)
        )

      names = Enum.map(rows, &(&1 |> String.trim() |> String.split(" ") |> hd()))
      assert hd(names) == "cupful"
      assert List.last(names) == "fieldnotes"
      t = Enum.join(p, "\n")
      assert t =~ ~r/tipjar .* payouts · limited +resumes 15:10/
      assert t =~ "no roadmap yet · r propose"
      assert t =~ "✓ all phases done"
      assert t =~ "search API · inferred"
      # Under 90 columns the right edge says what Sprat is doing...
      assert t =~ ~r/cupful .* waiting on you$/m
      # ...and from 90 the autonomy word comes back beside it.
      wide = render(view(), 120, 40) |> plain() |> Enum.join("\n")
      assert wide =~ ~r/forge .* watching +watch/
    end

    test "served today keeps five lines, newest first" do
      p = plain(render(view(), 88, 40))
      i = Enum.find_index(p, &(&1 =~ "SERVED TODAY"))
      served = Enum.slice(p, (i + 1)..(i + 5))
      assert hd(served) =~ "13:44  liftlog-ios"
      assert List.last(served) =~ "(you)"
      refute Enum.join(p) =~ "pr #212"
    end
  end

  describe "a ticket, opened (§10.4)" do
    test "shows the whole PM run in place, the line dimmed" do
      lines = render(open(view()), 88, 40)
      t = text(lines)
      for label <- ["you ", "found ", "tried ", "did ", "pm run "], do: assert(t =~ label)
      assert t =~ "u revert"
      assert t =~ "$0.31 · 11 turns · confidence high"
      assert t =~ "THE LINE ─ dimmed"
      golden("board_88_opened", lines)
    end

    test "a question ticket shows the suggested answer, editable" do
      v = %{view() | rail_index: 1} |> open()
      t = text(render(v, 88, 40))
      assert t =~ "Keep the old network_id column"
      assert t =~ "e edit"
      assert t =~ "f send"
    end
  end

  describe "project and session screens (§10.6)" do
    test "project screen: rail, roadmap, sessions, served, sources" do
      v = View.clamp(%{view() | screen: {:project, "/Users/owner/Projects/cupful"}})
      lines = render(v, 88, 40)
      t = text(lines)
      assert t =~ "› cupful"
      assert t =~ "C · 3/9 · 1.2 items/day"
      assert t =~ "▸ C  Cafe networks"
      assert t =~ "shared points ledger  cafe-networks-4b ⏸"
      assert t =~ "…3 more"
      assert t =~ "⏸ cafe-networks-4b     waiting on you 18m"
      assert t =~ "sources  2026-11-14-cafe-networks.md"
      golden("project_88", lines)
    end

    test "project screen at 140+ puts roadmap and sessions side by side" do
      v = %{view() | screen: {:project, "/Users/owner/Projects/cupful"}}
      row = v |> render(150, 40) |> plain() |> Enum.find(&(&1 =~ "ROADMAP"))
      assert row =~ "SESSIONS"
    end

    test "session screen: condensed transcript, errors marked, expandable" do
      v = %{view() | screen: {:session, "cf-4b"}, session_index: 7}

      engine = View.put_session_lines(v, "cf-4b", [%{at: @now, kind: :error, text: "boom"}])
      assert text(render(engine, 88, 30)) =~ "error  ⚠ boom"
      lines = render(v, 88, 30)
      t = text(lines)
      assert t =~ "TRANSCRIPT ─ condensed"
      assert t =~ "result ⚠ 2 failures"
      assert t =~ "›13:44  agent"
      expanded = text(render(%{v | session_expanded: MapSet.new([7])}, 88, 30))
      assert expanded =~ "breaks the v1 export."
      golden("session_88", lines)
    end
  end

  describe "a session's recap" do
    test "counts, the repos it worked in and a timeline, newest at the bottom" do
      v = %{view() | screen: {:session, "cf-4b"}, session_mode: :recap}
      assert text(render(v, 88, 30)) =~ "reading its transcript"

      recap = %{
        since: @now,
        from: @now,
        cut?: false,
        counts: %{
          you: 2,
          sprat: 1,
          turns: 3,
          edits: 5,
          commits: 1,
          tests: 4,
          failed: 1,
          limits: 0
        },
        repos: [{"cupful_ios", 12}, {"cupful", 2}],
        timeline: [
          %{at: @now, kind: :you, text: "Drop flutter; build the iOS app"},
          %{at: @now, kind: :failed, text: "xcodebuild test"},
          %{at: @now, kind: :commit, text: "feat: iOS scan shortcuts"},
          %{at: @now, kind: :said, text: "Task 5 passed review."}
        ]
      }

      t = text(render(View.put_recap(v, "cf-4b", 4, recap), 120, 30))
      assert t =~ "RECAP ─ last 4h"
      assert t =~ "1h [4h] 12h 24h"

      assert t =~
               "2 prompts from you · 1 from sprat · 3 turns · 5 edits · 1 commit · 4 test runs, 1 failed"

      assert t =~ "worked in  cupful_ios 12 · cupful 2"
      assert t =~ ~r/you +Drop flutter; build the iOS app\n.*failed +xcodebuild test/
      assert t =~ ~r/commit +feat: iOS scan shortcuts\n.*agent +Task 5 passed review\./
      assert t =~ "←→ hours"

      # A recap read for other hours is not shown as this span's.
      refute text(render(%{View.put_recap(v, "cf-4b", 12, recap) | recap_hours: 4}, 88, 30)) =~
               "worked in"
    end
  end

  describe "palette and ASCII (§10.7–10.8)" do
    test "the selected row of the line sits on a faint band, full width; nothing else does" do
      v = %{view() | focus: :line, line_index: 1}
      lines = render(v, 120, 40, %{color: :truecolor})
      banded = Enum.filter(lines, &(&1 =~ "48;2;52;48;42"))
      assert [row] = banded
      assert Width.strip_ansi(row) =~ ~r/^›/
      # The band runs to the row's right-hand columns, not just its name.
      assert row =~ ~r/48;2;52;48;42m +11:42\e\[0m$/

      assert Enum.join(render(v, 120, 40, %{color: :c256})) =~ "48;5;236"
      refute Enum.join(render(v, 120, 40, %{color: :c16})) =~ "\e[4"
    end

    test "no background colour is painted unless a row is selected" do
      for color <- [:truecolor, :c256, :c16, :none], v <- [view(), open(view())] do
        out = Enum.join(render(v, 120, 40, %{color: color}))

        for [params] <- Regex.scan(~r/\e\[([0-9;]*)m/, out, capture: :all_but_first) do
          refute background?(String.split(params, ";")), "background SGR: #{params}"
        end
      end
    end

    # Walks SGR params, skipping the colour arguments of 38;5;n and 38;2;r;g;b.
    defp background?([]), do: false
    defp background?(["38", "5", _ | rest]), do: background?(rest)
    defp background?(["38", "2", _, _, _ | rest]), do: background?(rest)

    defp background?([p | rest]),
      do:
        p in ~w(40 41 42 43 44 45 46 47 48 49 100 101 102 103 104 105 106 107) or
          background?(rest)

    test "truecolor and 256 colour roles" do
      tc = Enum.join(render(view(), 88, 40, %{color: :truecolor}))
      assert tc =~ "38;2;224;169;59"
      assert tc =~ "38;2;200;67;47;7"
      c256 = Enum.join(render(view(), 88, 40, %{color: :c256}))
      assert c256 =~ "38;5;179"
      c16 = Enum.join(render(view(), 88, 40, %{color: :c16}))
      assert c16 =~ "\e[33m"
    end

    test "NO_COLOR: no colour codes, bold and faint and the reversed chip remain" do
      out = Enum.join(render(view(), 88, 40, %{color: :none}))
      refute out =~ ~r/\e\[[0-9;]*3[0-8]/
      assert out =~ "\e[1m"
      assert out =~ "\e[2m"
      assert out =~ "\e[7m"
    end

    test "ASCII mode swaps every glyph" do
      lines =
        render(view(), 100, 40, %{ascii?: true}) ++ render(open(view()), 88, 40, %{ascii?: true})

      t = text(lines)
      for g <- ~w(┏ ┃ ┌ │ ─ ▰ ▱ ● ◌ ⏸ ✓ ⏎ ← → •), do: refute(t =~ g, "#{g} left in ASCII mode")
      assert t =~ "+===="
      assert t =~ "###"
      assert t =~ "SPRAT <o<"
      golden("board_100_ascii", render(view(), 100, 40, %{ascii?: true}))
    end
  end

  describe "overlay" do
    test "the brief shows as an in-place band under the rail" do
      v = %{view() | overlay: {:brief, "brief · mon 23 nov\n\ncupful: C 3/9"}}
      t = text(render(v, 88, 40))
      assert t =~ "BRIEF"
      assert t =~ "cupful: C 3/9"
      refute t =~ "THE LINE"
      assert t =~ "esc close"
      p = %{v | screen: {:project, "/Users/owner/Projects/cupful"}}
      assert text(render(p, 88, 40)) =~ "BRIEF"
    end
  end

  describe "the age chip" do
    test "steps quiet → amber → red at the rule's thresholds" do
      v = view()
      role = fn id -> Board.age_role(v, View.ticket(v, id)) end
      assert role.("t-expo") == :quiet
      assert role.("t-network") == :you
      assert role.("t-cert") == :stuck
      assert role.("t-limit") == :quiet
    end

    test "an unresolved nudge is red at any age" do
      v = view()
      %Ticket{finding: %Finding{} = f} = t = View.ticket(v, "t-expo")
      t = %{t | finding: %{f | data: %{unresolved_nudge: true}}}
      assert Board.age_role(v, t) == :stuck
    end

    test "labels" do
      assert Board.age_label(@now, DateTime.add(@now, -25 * 60)) == "25M"
      assert Board.age_label(@now, DateTime.add(@now, -5 * 3600)) == "5H"
      assert Board.age_label(@now, DateTime.add(@now, -3 * 86_400)) == "3D"
    end
  end

  describe "the fish" do
    defp only(tickets), do: view(map: &%{&1 | tickets: tickets})

    defp ticket(id, owner, running?),
      do: %Ticket{
        id: id,
        owner: owner,
        project_root: "/Users/owner/Projects/liftlog",
        since: @now,
        pm_running?: running?
      }

    test "faces you with a yours ticket, swims with a PM run, else still" do
      assert View.fish_state(view()) == :facing
      assert View.fish_state(only([ticket("a", :sprat, true)])) == :swimming
      assert View.fish_state(only([ticket("a", :sprat, false)])) == :still
      assert View.fish_state(only([])) == :still
    end

    test "swimming moves with the frame, idle animates nothing" do
      v = only([ticket("a", :sprat, true)])
      a = hd(plain(render(v, 88, 20, %{frame: 0})))
      b = hd(plain(render(v, 88, 20, %{frame: 6})))
      assert a != b
      assert View.animating?(v)
      refute View.animating?(v, reduced_motion?: true)
      refute View.animating?(only([ticket("a", :sprat, false)]))
    end

    test "blinks for ten seconds when a new yours ticket lands, not on the first snapshot" do
      v = only([])
      refute View.blinking?(v)
      snap = Fixture.snapshot(@now) |> Map.put(:tickets, [ticket("y", :yours, false)])
      v = View.put_snapshot(v, snap)
      assert View.blinking?(v)
      assert View.animating?(v)
      frames = for f <- 0..10, do: hd(plain(render(v, 88, 20, %{frame: f})))
      assert Enum.any?(frames, &(&1 =~ "<><")) and Enum.any?(frames, &(&1 =~ "<•<"))

      later = View.put_snapshot(v, %{snap | now: DateTime.add(@now, 11)})
      refute View.blinking?(later)
      assert hd(plain(render(later, 88, 20, %{frame: 5}))) =~ "<•<"

      first = View.new(snap)
      refute View.blinking?(first)
    end
  end

  describe "NOW: what sprat is doing this moment" do
    defp job(attrs) do
      Map.merge(
        %{
          id: "job-1",
          kind: :switch_account,
          label: "moving studio-67 to .claude-work",
          step: "copying the conversation 82/153 MB",
          status: :running,
          result: nil,
          project_root: "/Users/owner/Projects/dreamboard",
          project_name: "dreamboard",
          ticket_id: nil,
          started_at: DateTime.add(@now, -12),
          finished_at: nil
        },
        Map.new(attrs)
      )
    end

    defp with_jobs(jobs), do: view(map: &Map.put(&1, :jobs, jobs))

    test "nothing running, no band" do
      idle =
        view(
          map: fn snap ->
            %{snap | tickets: Enum.map(snap.tickets, &%{&1 | pm_running?: false})}
          end
        )

      refute text(render(idle, 120, 34)) =~ "NOW"
    end

    test "an investigation in progress: spinner, project, what, elapsed" do
      t = text(render(view(), 120, 34))
      assert t =~ ~r/NOW ─/
      assert t =~ ~r/dreamboard · investigating · researching Expo build error.* 3m 0s/
      assert t =~ ~r/dreamboard .* investigating 3m +act/
    end

    test "the header counts every live agent; sessions say how long they've worked" do
      v = view()
      t = text(render(v, 120, 34))
      assert t =~ "● 7 working  ✓ 1 finished  ⏸ 2 need you"
      assert text(render(v, 88, 34)) =~ "●7 ✓1 ⏸2"
      refute text(render(v, 60, 34)) =~ "working"

      forge = View.clamp(%{v | screen: {:project, "/Users/owner/Projects/forge"}})
      assert View.animating?(forge)
      assert text(render(forge, 100, 24)) =~ ~r"forge +working 34m · quiet 7m"

      gi = View.clamp(%{v | screen: {:project, "/Users/owner/Projects/liftlog-ios"}})
      assert text(render(gi, 100, 24)) =~ "✓ liftlog-ios-12       finished its turn 7m ago"
    end

    test "a running job: spinner, project, what and the current step, elapsed; the row says it" do
      v = with_jobs([job([])])
      assert View.animating?(v)
      lines = render(v, 120, 34)
      assert_fits(lines, 120, 34)
      t = text(lines)
      assert t =~ "NOW"

      assert t =~
               ~r/⠋ dreamboard · moving studio-67 to \.claude-work · copying the conversation 82\/153 MB +12s/

      # The row says it in a few words; the step is in the NOW band.
      assert t =~ ~r/dreamboard .* moving session +act/
      # The spinner turns with the frame.
      assert text(render(v, 120, 34, %{frame: 1})) =~ "⠙ dreamboard"
    end

    test "finished jobs stay a while: done quiet, failed red with why" do
      done =
        job(id: "job-2", status: :done, result: "started on .claude-work", finished_at: @now)

      failed =
        job(
          id: "job-3",
          status: :failed,
          result: "Claude didn't start in cmux workspace:9; it shows: Not logged in",
          finished_at: DateTime.add(@now, -180)
        )

      v = with_jobs([done, failed])
      t = text(render(v, 120, 34))
      assert t =~ ~r/✓ dreamboard · moving studio-67 .* started on \.claude-work +just now/
      assert t =~ ~r/✗ dreamboard · moving studio-67 to \.claude-work +3m ago/
      assert t =~ ~r/\n   Claude didn't start in cmux workspace:9; it shows: Not logged in\n/
      assert t =~ ~r/dreamboard .* moving session failed/
    end

    test "a command on its way shows at once, in words" do
      v = view()
      t = Enum.find(v.snapshot.tickets, &match?("f " <> _, &1.action_label || ""))
      label = View.pending_label(v, {:fire, t.id, "x"})
      refute label =~ "  "
      pending = %{v | pending: %{ref: make_ref(), label: label}}
      assert View.animating?(pending)
      assert text(render(pending, 120, 34)) =~ "⠋ " <> label <> "…"
      assert View.pending_label(v, {:open_session_terminal, "s"}) == "switching to the session"
    end
  end

  describe "the activity screen" do
    defp activity_view(screen) do
      events = [
        %{
          at: DateTime.add(@now, -5),
          kind: :job,
          type: :failed,
          project_root: "/Users/owner/Projects/dreamboard",
          text: "moving studio-67 to .claude-work · couldn't start: Not logged in",
          status: :failed
        },
        %{
          at: DateTime.add(@now, -60),
          kind: :pm,
          type: :started,
          project_root: "/Users/owner/Projects/cupful",
          text: "investigating: the agent asked about network_id",
          status: :running
        },
        %{
          at: DateTime.add(@now, -90),
          kind: :command,
          type: nil,
          project_root: nil,
          text: "cmux top took 9.0s",
          status: :info
        }
      ]

      system = %{
        processes: 412,
        memory_mb: 96,
        uptime_s: 7_300,
        tasks: 1,
        jobs_running: 0,
        pm_running: 1,
        tree: [
          %{name: "engine", alive?: true, queue: 0, memory_kb: 3_300},
          %{name: "store", alive?: true, queue: 0, memory_kb: 900},
          %{name: "tasks", alive?: true, queue: 0, memory_kb: 40}
        ]
      }

      commands = [
        %{
          name: "ps",
          running: 0,
          runs: 1820,
          avg_ms: 40,
          max_ms: 11_200,
          last_ms: 30,
          last_status: 0,
          last_at: @now
        },
        %{
          name: "cmux top",
          running: 1,
          runs: 320,
          avg_ms: 300,
          max_ms: 9_000,
          last_ms: 200,
          last_status: :timeout,
          last_at: @now
        }
      ]

      v =
        view(
          map: fn snap ->
            snap
            |> Map.put(:activity, events)
            |> Map.put(:system, system)
            |> Map.put(:commands, commands)
          end
        )

      %{v | screen: screen}
    end

    test "every project: timeline, the VM's processes, the programs sprat runs" do
      lines = render(activity_view({:activity, nil}), 120, 34)
      assert_fits(lines, 120, 34)
      t = text(lines)
      assert hd(plain(lines)) =~ "› activity"
      assert t =~ ~r/ACTIVITY ─ every project .* newest first · 3/

      assert t =~
               ~r/14:01:55  dreamboard +✗ job +moving studio-67 to \.claude-work · couldn't start: Not logged in/

      assert t =~ ~r/14:01:00  cupful +▸ pm +investigating: the agent asked about network_id/
      assert t =~ ~r/14:00:30  sprat +· program +cmux top took 9\.0s/
      assert t =~ ~r/PROCESSES ─ 412 BEAM processes · 96 MB · up 2h 1m/
      assert t =~ ~r/engine +running +mailbox +0 +3\.2 MB/
      assert t =~ ~r/tasks .* 1 task: 0 jobs, 1 investigation/
      assert t =~ ~r/ps +1820 runs +avg +40ms +max +11\.2s +exit 0/
      assert t =~ ~r/cmux top +320 runs .* stopped \(too slow\) +1 running now/
    end

    test "one project's slice: its events only, no machine bands" do
      root = "/Users/owner/Projects/dreamboard"
      t = text(render(activity_view({:activity, root}), 120, 34))
      assert t =~ "› dreamboard  › activity"
      assert t =~ "couldn't start: Not logged in"
      refute t =~ "network_id"
      refute t =~ "PROCESSES"
    end

    test "keys: a opens it from the board and a project, esc goes back, arrows scroll" do
      alias Sprat.Terminal.Board.Keys
      v = activity_view(:board)
      {v, []} = Keys.handle(v, {:char, "a"})
      assert v.screen == {:activity, nil}
      {v, []} = Keys.handle(v, :down)
      assert v.activity_index == 1
      assert text(render(v, 120, 34)) =~ "2–3 of 3"
      {v, []} = Keys.handle(v, {:char, "g"})
      assert v.activity_index == 0
      {v, []} = Keys.handle(v, :esc)
      assert v.screen == :board

      root = "/Users/owner/Projects/dreamboard"
      {v, []} = Keys.handle(%{v | screen: {:project, root}}, {:char, "a"})
      assert v.screen == {:activity, root}
      {v, []} = Keys.handle(v, :esc)
      assert v.screen == {:project, root}
    end
  end

  describe "a session's screen mirrors its terminal" do
    defp mirrored(screen_text) do
      v = view()

      projects =
        Enum.map(v.snapshot.projects, fn p ->
          %{
            p
            | sessions:
                Enum.map(p.sessions, fn s ->
                  if s.session_id == "cf-4b", do: %{s | surface: "surface:12"}, else: s
                end)
          }
        end)

      v = View.put_snapshot(v, %{v.snapshot | projects: projects})
      v = %{v | screen: {:session, "cf-4b"}}
      if screen_text, do: View.put_session_screen(v, "cf-4b", screen_text), else: v
    end

    test "the newest lines of its terminal, live, with the message line at the bottom" do
      screen = Enum.map_join(1..60, "\n", &"line #{&1}") <> "\n\n> \n\n"
      lines = render(mirrored(screen), 100, 30)
      assert_fits(lines, 100, 30)
      p = plain(lines)
      t = Enum.join(p, "\n")
      # Why it is quiet and what Sprat will do, above its window.
      assert Enum.at(p, 1) =~ ~r/^ why   asked you: Keep network_id/
      assert Enum.at(p, 2) =~ ~r/^ next  waits for you; sprat sends it nothing/
      # Claude's window, not Sprat's: framed and titled as Claude Code, with
      # the session's name and account.
      assert Enum.at(p, 4) =~
               ~r/^ ╭─ Claude Code · cafe-networks-4b · .*claude ─+ live · surface:12 ─╮$/u

      assert Enum.at(p, -3) =~ ~r/^ ╰─+╯$/u
      assert t =~ ~r/│ line 60 +│/
      refute t =~ "line 30 "
      assert Enum.at(p, -2) =~ "› type to talk to cafe-networks-4b"

      assert List.last(p) =~
               "type message  ↑↓ scroll  space talk  tab transcript  ^o its tab  esc back"
    end

    test "↑↓ and pgup/pgdn scroll its terminal back; ↓ to the bottom follows it live" do
      alias Sprat.Terminal.Board.Keys
      screen = Enum.map_join(1..60, "\n", &"line #{&1}") <> "\n\n> \n\n"
      v = mirrored(screen)

      {v, []} = Keys.handle(v, :page_up)
      {v, []} = Keys.handle(v, :up)
      assert v.mirror_scroll == 11
      assert v.screen == {:session, "cf-4b"}

      p = plain(render(v, 100, 30))
      t = Enum.join(p, "\n")
      assert Enum.at(p, 4) =~ "↑ 11 lines up · ↓ back to live"
      # 60 lines plus the blank and the prompt: the newest 11 are hidden.
      assert t =~ ~r/│ line 51 +│/
      refute t =~ ~r/│ line 52 +│/

      {v, []} = Keys.handle(v, :page_down)
      {v, []} = Keys.handle(v, :down)
      {v, []} = Keys.handle(v, :down)
      assert v.mirror_scroll == 0
      assert Enum.at(plain(render(v, 100, 30)), 4) =~ "live · surface:12"
    end

    test "the frame is drawn in Claude's coral, its title bold; the inside keeps Claude's colours" do
      lines =
        render(mirrored("⏺ Bash(mix test)\n  ⎿  2 tests, 0 failures\n"), 100, 30, %{
          color: :truecolor
        })

      top = Enum.at(lines, 4)
      assert top =~ "\e[38;2;217;119;87m╭─"
      assert top =~ "\e[38;2;217;119;87;1m Claude Code"

      ascii = plain(render(mirrored("hello"), 100, 30, %{ascii?: true}))
      assert Enum.at(ascii, 4) =~ ~r/^ \+- Claude Code/
      assert Enum.at(ascii, -3) =~ ~r/^ \+-+\+$/
    end

    test "before the first read; while typing; with a dialog open" do
      assert text(render(mirrored(nil), 100, 30)) =~ "reading the session's terminal…"

      {typing, []} =
        Sprat.Terminal.Board.Keys.handle(mirrored("> "), {:char, "h"})

      p = plain(render(typing, 100, 30))
      assert Enum.at(p, -2) =~ "› to cafe-networks-4b  h▏"
      assert List.last(p) =~ "⏎ send  esc cancel"

      dialog = "Do you want to proceed?\n❯ 1. Yes\n  2. No\n"
      p = plain(render(mirrored(dialog), 100, 30))
      assert Enum.at(p, -2) =~ "a dialog is open in cafe-networks-4b: answer it here"
      assert List.last(p) =~ "1–9 ↑↓ ⏎ answer"
    end
  end

  describe "? explains the screen you are on" do
    alias Sprat.Terminal.Board.Keys

    defp help_text(v, w \\ 100, h \\ 200) do
      {v, []} = Keys.handle(v, {:char, "?"})
      assert v.help?
      text(render(v, w, h))
    end

    test "the board: what Sprat is, every part with its glyphs, the keys" do
      t = help_text(view())
      assert t =~ "› the board  › help"
      assert t =~ "THE BOARD ─ what this screen is"
      assert t =~ "Sprat watches every Claude Code session on this machine"
      assert t =~ ~r/ 9M   40M   2H +How long the ticket has waited/
      assert t =~ ~r/● ✓ ◌ ⏸ ⚠ · +One mark per Claude session/
      assert t =~ ~r/autonomy +How much Sprat may do by itself/
      assert t =~ ~r/f +send the selected ticket's suggested message/
      assert t =~ ~r/a +activity: everything Sprat did/
    end

    test "each screen gets its own page" do
      v = view()
      t = hd(View.rail(v))
      assert help_text(%{v | opened_ticket: t.id}) =~ "A TICKET ─ what this screen is"

      assert help_text(%{v | screen: {:project, "/Users/owner/Projects/cupful"}}) =~
               "› cupful  › help"

      session = help_text(%{v | screen: {:session, "cf-4b"}})
      assert session =~ "A SESSION ─ what this screen is"
      assert session =~ ~r/1–9 ↑↓ ⏎ +answer a question the agent is asking/

      assert help_text(%{v | screen: {:activity, nil}}) =~ ~r/PROCESSES +Sprat's own parts/
      assert help_text(%{v | overlay: {:brief, "b"}}) =~ "THE BRIEF"
    end

    test "long pages scroll; esc, ? or q close; the footer says so" do
      {v, []} = Keys.handle(view(), {:char, "?"})
      top = plain(render(v, 100, 30))
      assert hd(tl(tl(top))) =~ "↑↓ scroll"
      assert List.last(top) =~ "↑↓ scroll  esc close"
      refute List.last(top) =~ "? help"

      {down, []} = Keys.handle(v, :down)
      assert down.help_index == 1
      refute plain(render(down, 100, 30)) == top

      max = Board.help_max_offset(v, %{width: 100, height: 30})
      assert max > 0
      assert Board.help_max_offset(v, %{width: 100, height: 400}) == 0
      refute text(render(v, 100, 400)) =~ "↑↓ scroll ─"

      for k <- [:esc, {:char, "?"}, {:char, "q"}],
          do: assert({%{help?: false}, []} = Keys.handle(v, k))
    end

    test "a first run says where to start, until help was opened once" do
      v = %{view() | first_run?: true}
      assert text(render(v, 100, 40)) =~ "new here? press ? on any screen and Sprat explains"
      {v, []} = Keys.handle(v, {:char, "?"})
      {v, []} = Keys.handle(v, :esc)
      refute text(render(v, 100, 40)) =~ "new here?"
    end

    test "the line has column headings" do
      t = text(render(view(), 120, 40))
      assert t =~ ~r/project +roadmap +working on +agents +sprat is autonomy +moved/
      assert text(render(view(), 72, 40)) =~ ~r/project +roadmap +working on +agents +sprat is/
    end
  end

  describe "Claude's colours, rebuilt from its line markers" do
    test "each kind of line gets the style Claude gives it" do
      assert [{"⏺ ", :progress}, {"Bash", :bright}, {"(mix test)", :text}] =
               Board.claude_line("⏺ Bash(mix test)")

      assert [{"⏺ ", :progress}, {"elixir-expert", :bright}, {"(Fix it all)", :text}] =
               Board.claude_line("⏺ elixir-expert(Fix it all)")

      assert [{"⏺", :text}, {" Both sites are clean.", :text}] =
               Board.claude_line("⏺ Both sites are clean.")

      assert [{"  ", :text}, {"⎿  42 tests, 0 failures", :quiet}] =
               Board.claude_line("  ⎿  42 tests, 0 failures")

      assert [{"❯ merge it", :bright}] = Board.claude_line("❯ merge it")

      assert [{"✻ Baked for 3m 19s · done 16:11", :claude}] =
               Board.claude_line("✻ Baked for 3m 19s · done 16:11")

      assert [{"✶ Thinking…", :claude}] = Board.claude_line("✶ Thinking…")

      assert [{_, :text}, {"12 +    slug = slugify(title)", :progress}] =
               Board.claude_line("      12 +    slug = slugify(title)")

      assert [{_, :text}, {"12 -    slug = old(title)", :stuck}] =
               Board.claude_line("      12 -    slug = old(title)")

      assert [{"Error: boom", :stuck}] = Board.claude_line("Error: boom")
      assert [{"──────────", :rule}] = Board.claude_line("──────────")

      assert [{_, :text}, {"⏵⏵ bypass permissions on", :rule}] =
               Board.claude_line("  ⏵⏵ bypass permissions on")
    end

    test "unknown lines stay plain text; a bullet in prose is not a status line" do
      assert [{"| Site | Posts |", :text}] = Board.claude_line("| Site | Posts |")
      assert [{"· a note in a list", :text}] = Board.claude_line("· a note in a list")
      assert [{"* not bold", :text}] = Board.claude_line("* not bold")
      assert [] = Board.claude_line("")
    end
  end

  test "the header says when cmux refuses sprat, and rows say what sprat is doing" do
    denied = view(map: fn snap -> put_in(snap, [:header, :cmux], :denied) end)
    lines = render(denied, 120, 34)
    assert_fits(lines, 120, 34)
    assert hd(plain(lines)) =~ "✗ cmux refused sprat"

    refute render(view(), 120, 34) |> plain() |> hd() =~ "cmux"

    t = text(render(view(), 120, 34))
    assert t =~ ~r/cupful .* waiting on you +act/
    assert t =~ ~r/dreamboard .* investigating 3m +act/
  end

  test "a project on two accounts is limited only while both are" do
    alias Sprat.Observer.Model.{Account, Project}
    now = ~U[2026-11-24 12:00:00Z]
    later = ~U[2026-11-24 17:00:00Z]
    p = %Project{root: "/p/studio", config_dirs: ["/c/main", "/c/second"]}

    view = fn accounts ->
      View.new(%{
        now: now,
        projects: [p],
        tickets: [],
        served: [],
        accounts: accounts,
        header: %{limited_accounts: []}
      })
    end

    one = view.([%Account{config_dir: "/c/main", limited_until: later}])
    assert View.limited_until(one, p) == nil

    both =
      view.([
        %Account{config_dir: "/c/main", limited_until: later},
        %Account{config_dir: "/c/second", limited_until: ~U[2026-11-24 13:00:00Z]}
      ])

    assert View.limited_until(both, p) == ~U[2026-11-24 13:00:00Z]
  end

  test "a rail card is marked active only while the rail has focus" do
    on_rail = view()
    assert on_rail.focus == :rail
    assert text(render(on_rail, 120, 34)) =~ "┏"

    on_line = %{on_rail | focus: :line}
    t = text(render(on_line, 120, 34))
    refute t =~ "┏"
    assert t =~ "┌"

    # The active card's border is the accent colour, not plain white.
    colored = render(on_rail, 120, 34, %{color: :truecolor}) |> Enum.join("\n")
    assert colored =~ "\e[38;2;224;169;59m┏"
  end
end
