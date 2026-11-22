defmodule Mix.Tasks.Sprat.Site do
  @shortdoc "Renders the board replay and screenshots for sprat.dev"
  @moduledoc """
  `mix sprat.site <site_dir>` writes, into the sprat.dev Phoenix app:

    * `lib/sprat_site_web/components/board_replay.ex`: the hero's replay,
      six frames of the real Pass board told as a story (a session stalls,
      Sprat investigates, a ticket for you, a usage limit carried to another
      account, talking to a session, help), each rendered by
      `Sprat.Terminal.Board` and turned into HTML text: wide (100 columns)
      and narrow (56 columns) for phones;
    * `priv/static/images/screens/*.webp`: the feature screenshots, via
      `mix sprat.screenshots` and `cwebp`.

  Demo data only (`Sprat.Terminal.Board.Fixture`, projects renamed to
  fictional ones); nothing from the machine's real sessions.
  """
  use Mix.Task

  alias Sprat.Terminal.Board
  alias Sprat.Observer.Model.Served
  alias Sprat.Terminal.Board.{Fixture, Keys, Style, View}

  @now ~U[2026-11-23 14:02:00Z]

  @impl true
  def run([site | _]) do
    Mix.Task.run("app.config")
    site = Path.expand(site)
    module = Path.join(site, "lib/sprat_site_web/components/board_replay.ex")

    File.write!(
      module,
      module_source(frames(100, 30), frames(56, 40), cycle_frames(100, 30), cycle_frames(56, 40))
    )

    Mix.shell().info("wrote #{module}")
  end

  def run(_), do: Mix.raise("usage: mix sprat.site <path to sprat_web>")

  # -- the story --------------------------------------------------------------------

  @doc false
  def story do
    base = Fixture.snapshot(@now) |> Mix.Tasks.Sprat.Screenshots.rename()
    by_id = Map.new(base.tickets, &{&1.id, &1})
    quiet_tickets = [by_id["t-limit"], by_id["t-search"]]

    expo = %{by_id["t-expo"] | headline: "investigating: stalled 2 days on 2.3 onboarding copy"}

    [
      {"Sprat watches every Claude Code session on your machine, and where each project stands on its roadmap.",
       board(%{base | tickets: quiet_tickets}, [])},
      {"An agent stops moving. Sprat notices and investigates: the roadmap, the decisions already written down, your other projects, the web.",
       board(%{base | tickets: [expo | quiet_tickets]}, [
         job(:running, "dreamboard", "investigating why 2.3 stalled",
           step: "reading PAUSE.md and the plan",
           started: 14
         )
       ])},
      {"What it can fix, it fixes. What only you can decide lands on the rail, and the fish turns to face you.",
       board(base, [
         job(:done, "dreamboard", "investigating why 2.3 stalled",
           result: "told the agent: resume 2.3 from PAUSE.md",
           finished: 20
         )
       ])},
      {"A session hits its usage limit? Sprat carries the conversation to another of your Claude accounts.",
       board(base, [
         job(:running, "studio", "moving studio-4 to .claude-work",
           step: "copying the conversation 82/153 MB",
           started: 12
         )
       ])},
      {"Open any session and talk to it from the board: its own terminal, live, in Claude's colours.",
       session(base)},
      {"Not sure what you're looking at? Press ? on any screen and Sprat explains it.",
       %{View.new(%{base | tickets: quiet_tickets}) | help?: true}}
    ]
  end

  @doc """
  The full cycle, frame by frame: one stall Sprat clears by itself, then a
  question only the owner can answer. Each frame is `{stage, caption, view}`;
  the stage lights its step on the site's cycle ring.
  """
  def cycle do
    base = Fixture.snapshot(@now) |> Mix.Tasks.Sprat.Screenshots.rename()
    by_id = Map.new(base.tickets, &{&1.id, &1})
    ago = fn s -> DateTime.add(@now, -s, :second) end

    # The story's agents: dreamboard's (stalls, then resumes) and cupful's
    # (asks a question nobody has answered).
    working = fn snap, sid, title, since ->
      put_session(
        snap,
        sid,
        &%{
          &1
          | status: :busy,
            title: title,
            status_since: ago.(since),
            last_activity_at: ago.(20)
        }
      )
    end

    stalled = fn snap ->
      put_session(
        snap,
        "id-1",
        &%{&1 | status: :idle, title: nil, status_since: ago.(2 * 86_400)}
      )
    end

    calm =
      %{base | tickets: [], served: Enum.reject(base.served, &(&1.text =~ "resumed 2.3"))}
      |> working.("id-1", "onboarding copy", 50 * 60)
      |> working.("cf-4b", "shared points ledger", 14 * 60)

    expo = by_id["t-expo"]
    noticed_f = %{expo.finding | state: :open}

    noticed = %{
      expo
      | headline: "noticed: no progress on 2.3 onboarding copy for 2 days",
        pm_running?: false,
        finding: noticed_f,
        since: ago.(3 * 60)
    }

    investigating = %{
      noticed
      | headline: "investigating: no progress on 2.3 for 2 days",
        pm_running?: true,
        pm_started_at: ago.(48),
        finding: %{noticed_f | state: :pm_running}
    }

    following = %{
      noticed
      | headline: "following up: told the agent to resume 2.3 from PAUSE.md",
        action_label: "⏎ open",
        finding: %{noticed_f | state: :acted}
    }

    resumed = %Served{at: ago.(40), project_name: "dreamboard", text: "resumed 2.3 from PAUSE.md"}

    asks = %{by_id["t-network"] | since: ago.(60)}

    answered = %Served{
      at: ago.(5),
      project_name: "cupful",
      text: "answered “keep network_id?”: keep it",
      by: :you
    }

    s1 = stalled.(calm)

    s2 =
      put_session(calm, "cf-4b", &%{&1 | status: :idle, title: nil, status_since: ago.(40 * 60)})

    s2 = %{s2 | served: [resumed | calm.served]}

    [
      {:watch,
       "Every Claude Code session on your Mac, and where each project stands on its roadmap. Agents work; Sprat watches.",
       board(calm, [])},
      {:notice,
       "An agent stops moving: two days on the same roadmap item. Sprat notices from what Claude Code already writes to disk.",
       board(%{s1 | tickets: [noticed]}, [])},
      {:investigate,
       "Sprat investigates on its own: the plan, PAUSE.md, decisions already written down, how your other projects solved it.",
       board(%{s1 | tickets: [investigating]}, [])},
      {:unblock,
       "It found the answer, so it unblocks the agent itself: a message typed into the session, and a follow-up to make sure it worked.",
       board(%{s1 | tickets: [following]}, [
         job(:done, "dreamboard", "unblocking 2.3",
           result: "told the agent: resume 2.3 from PAUSE.md",
           finished: 6
         )
       ])},
      {:moving, "The agent is moving again. What Sprat did is written down under served.",
       board(%{calm | served: [resumed | calm.served]}, [])},
      {:you,
       "Another agent asks something nobody decided. That's yours: it lands on the rail, the fish turns to face you, a notification goes out.",
       board(%{s2 | tickets: [asks]}, [])},
      {:you,
       "Open the ticket: what the agent asked, where Sprat looked, and the answer it suggests.",
       %{View.new(Map.put(%{s2 | tickets: [asks]}, :jobs, [])) | opened_ticket: asks.id}},
      {:unblock, "Press f and Sprat types your answer into that agent's session.",
       board(s2, [
         job(:running, "cupful", "sending your answer",
           step: "typing it into cafe-networks-4b",
           started: 2,
           kind: :message
         )
       ])},
      {:moving, "Both agents are moving. Sprat goes back to watching, until the next stall.",
       board(
         %{
           working.(calm, "cf-4b", "migrating the ledger", 30)
           | served: [answered, resumed | calm.served]
         },
         []
       )}
    ]
  end

  defp put_session(snap, sid, fun) do
    projects =
      Enum.map(snap.projects, fn p ->
        %{p | sessions: Enum.map(p.sessions, &if(&1.session_id == sid, do: fun.(&1), else: &1))}
      end)

    %{snap | projects: projects}
  end

  defp board(snap, jobs), do: View.new(Map.put(snap, :jobs, jobs))

  defp job(status, project, label, opts) do
    %{
      id: "job-#{project}",
      kind: Keyword.get(opts, :kind, :demo),
      label: label,
      step: opts[:step],
      status: status,
      result: opts[:result],
      project_root: "/Users/owner/Projects/#{project}",
      project_name: project,
      ticket_id: nil,
      started_at: DateTime.add(@now, -Keyword.get(opts, :started, 60), :second),
      finished_at: if(f = opts[:finished], do: DateTime.add(@now, -f, :second))
    }
  end

  @claude_screen """
  ❯ continue C.4 shared points ledger from the plan

  ⏺ Reading the plan and the current schema.
  ⏺ Read(plans/2026-11-14-cafe-networks.md)
    ⎿  Read 214 lines
  ⏺ Write(lib/networks/ledger.ex)
    ⎿  Wrote 88 lines to lib/networks/ledger.ex
  ⏺ Write(test/networks/ledger_test.exs)
    ⎿  Wrote 61 lines to test/networks/ledger_test.exs
  ⏺ Bash(mix test test/networks)
    ⎿  2 failures: points earned at one cafe don't show at another
  ⏺ The balance was read per cafe. Reading it per network instead.
  ⏺ Bash(mix test test/networks)
    ⎿  48 tests, 0 failures
  ⏺ Update(lib/networks/ledger.ex)
    ⎿  Updated lib/networks/ledger.ex with 3 additions and 1 removal
        41 -    points = member.points
        41 +    points = Ledger.balance(member, network_id)
  ⏺ The shared points ledger works across cafes in a network. One question
    before I migrate: keep the network_id column on members, or move it to a
    join table? Spec v3 doesn't say.

  ✻ Brewed for 2m 41s · done 13:44

  ────────────────────────────────────────────────────────────────────
  ❯
  ────────────────────────────────────────────────────────────────────
    ⏵⏵ accept edits on (shift+tab to cycle)
  """

  defp session(base) do
    projects =
      Enum.map(base.projects, fn p ->
        sessions =
          Enum.map(p.sessions, fn s ->
            if s.session_id == "cf-4b", do: %{s | surface: "surface:12"}, else: s
          end)

        %{p | sessions: sessions}
      end)

    v = View.new(%{base | projects: projects})
    v = %{View.put_session_screen(v, "cf-4b", @claude_screen) | screen: {:session, "cf-4b"}}

    "keep network_id on members, one network per cafe"
    |> String.graphemes()
    |> Enum.reduce(v, fn ch, v -> elem(Keys.handle(v, {:char, ch}), 0) end)
  end

  # -- rendering ----------------------------------------------------------------------

  defp cycle_frames(cols, rows) do
    for {stage, caption, view} <- cycle() do
      %{stage: stage, caption: caption, html: render_html(view, cols, rows)}
    end
  end

  defp render_html(view, cols, rows) do
    view
    |> Board.render(%{width: cols, height: rows, color: :truecolor, ascii?: false, frame: 0})
    |> Enum.map_join("\n", &line_html/1)
  end

  defp frames(cols, rows) do
    for {caption, view} <- story() do
      lines =
        Board.render(view, %{
          width: cols,
          height: rows,
          color: :truecolor,
          ascii?: false,
          frame: 0
        })

      %{caption: caption, html: Enum.map_join(lines, "\n", &line_html/1)}
    end
  end

  # SGR colour → the site's CSS class (the board's roles).
  @roles Map.new(
           [:text, :bright, :quiet, :rule, :you, :stuck, :progress, :claude],
           fn role -> {Style.sgr(role, %{color: :truecolor}), role} end
         )

  @doc false
  def line_html(line) do
    {html, open?} =
      Regex.split(~r/\e\[[0-9;]*m/, line, include_captures: true)
      |> Enum.reduce({"", false}, fn
        "\e[" <> _ = seq, {acc, open?} ->
          classes = classes(seq)
          acc = if open?, do: acc <> "</span>", else: acc
          if classes == "", do: {acc, false}, else: {acc <> ~s(<span class="#{classes}">), true}

        "", st ->
          st

        text, {acc, open?} ->
          {acc <> escape(text), open?}
      end)

    html = if open?, do: html <> "</span>", else: html

    html
    |> one_cell()
    # The NOW band's spinner turns on the page.
    |> String.replace(~s(<i class="g">⠋</i>), ~s(<i class="g spin">⠋</i>))
  end

  @doc false
  # A terminal gives every glyph one cell; a browser draws symbols the font
  # lacks (⏺ ⎿ ⏵ ✻ ⠋) from a fallback font, often wider, and on another
  # system it may do so for any character outside ASCII, box drawing and
  # `·` included. One wider glyph is enough to push a row's right border
  # out of view.
  #
  # So every run of such characters sits in a box exactly as many cells wide
  # as it has characters, each character in a one-cell box inside it. The
  # run's box keeps the row's width exact whatever the fonts do (one box per
  # run, not per character, so the browser's rounding of box widths cannot
  # add up along a long rule).
  def one_cell(html) do
    Regex.replace(~r/[^\x{0000}-\x{007F}]+/u, html, fn run ->
      cells = run |> String.graphemes() |> Enum.map_join(&~s(<i class="g">#{&1}</i>))

      case String.length(run) do
        1 -> cells
        n -> ~s(<i class="gs" style="width:#{n}ch">#{cells}</i>)
      end
    end)
  end

  defp classes(seq) do
    params = seq |> String.trim_leading("\e[") |> String.trim_trailing("m")

    if params in ["", "0"] do
      ""
    else
      role =
        Enum.find_value(@roles, fn {sgr, role} ->
          (sgr != "" and String.starts_with?(params, sgr_colour(sgr))) && role
        end)

      codes = params |> String.split(";") |> modifiers()

      [
        role && "t-#{role}",
        "1" in codes && "t-b",
        "2" in codes && "t-f",
        "7" in codes && "t-r"
      ]
      |> Enum.filter(& &1)
      |> Enum.uniq()
      |> Enum.join(" ")
    end
  end

  # The SGR parameters that are not part of a colour (`38;2;r;g;b`,
  # `38;5;n`): bold, faint, reverse.
  defp modifiers(["38", "2", _, _, _ | rest]), do: modifiers(rest)
  defp modifiers(["38", "5", _ | rest]), do: modifiers(rest)
  defp modifiers([code | rest]), do: [code | modifiers(rest)]
  defp modifiers([]), do: []

  # "38;2;255;250;240;1" → "38;2;255;250;240" (the colour part of a role).
  defp sgr_colour(sgr) do
    case String.split(sgr, ";") do
      ["38", "2", r, g, b | _] -> Enum.join(["38", "2", r, g, b], ";")
      _ -> sgr
    end
  end

  defp escape(t),
    do:
      t
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  # -- the generated module ----------------------------------------------------------

  defp module_source(wide, narrow, cycle_wide, cycle_narrow) do
    """
    defmodule SpratSiteWeb.BoardReplay do
      @moduledoc \"\"\"
      The hero's board replay: frames of the real Sprat board, rendered by
      `Sprat.Terminal.Board` from demo data and turned into HTML.

      Generated by `mix sprat.site` in the sprat repo. Do not edit by hand;
      re-run that task after the board changes.
      \"\"\"

      @doc "The frames: `:wide` (100 columns) or `:narrow` (56 columns, phones)."
      def frames(:wide), do: #{inspect(wide, limit: :infinity, printable_limit: :infinity)}
      def frames(:narrow), do: #{inspect(narrow, limit: :infinity, printable_limit: :infinity)}

      @doc "The full cycle, frame by frame, each with the stage it lights on the ring."
      def cycle(:wide), do: #{inspect(cycle_wide, limit: :infinity, printable_limit: :infinity)}
      def cycle(:narrow), do: #{inspect(cycle_narrow, limit: :infinity, printable_limit: :infinity)}
    end
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end
end
