defmodule Sprat.Demo do
  @moduledoc """
  A manual, one-flow demo of the Phase 1 terminal renderer: a welcome box, a
  user message, streaming Markdown from two fake roles concurrently,
  tool-call/tool-result blocks, checklist progress, a permission prompt
  mid-run, Shift+Tab mode cycling, Ctrl+O verbose toggle, and the composer
  accepting typed input while streaming continues in the background.

  Runnable both via `mix sprat.demo` and, from a built release, `bin/sprat
  eval "Sprat.Demo.run()"`.
  """

  alias IO.ANSI
  alias Sprat.Terminal.{Mode, Renderer, Transcript, ZonedRenderer}
  alias Sprat.UISupervisor

  @commands [
    {"idea", "Start the idea-shaping workflow"},
    {"research", "Start the opportunity-discovery workflow"},
    {"help", "Commands and keys"}
  ]

  @paragraphs %{
    "researcher_1" => [
      "**Researcher·1**\n\nOwner-operated gyms in the UK typically juggle three systems: booking, payments and access control. Most complaints on forums point at fragmentation, not any single missing feature.\n\n",
      "- Booking friction is the most cited pain point\n- Payment reconciliation eats several hours a week\n- Access control integration is a common deal-breaker\n\n"
    ],
    "researcher_2" => [
      "**Researcher·2**\n\nGlofox and TeamUp dominate mid-market UK gyms, but reviewers frequently mention `onboarding` friction and slow support responses during the first month of use.\n\n",
      "```\nsource: reddit.com/r/gymowners\nclaims: 3\n```\n\n"
    ]
  }

  def run(opts \\ []) do
    unless Mode.tty?() do
      IO.puts(:stderr, "Sprat.Demo requires a real TTY (stdin and stdout).")
      exit({:shutdown, 1})
    end

    # The UI supervisor (Input + Renderer, raw mode, exit traps) is normally
    # started by Sprat.Application on boot since we're on a real tty; start
    # it ourselves only if that didn't happen (e.g. this is the first thing
    # to touch the terminal in this run).
    ensure_ui_started()
    Renderer.subscribe(self())

    seed(opts)

    stream_task =
      Task.async(fn ->
        Task.await_many(
          [
            Task.async(fn -> stream_role("researcher_1") end),
            Task.async(fn -> stream_role("researcher_2") end)
          ],
          :infinity
        )
      end)

    permission_task = Task.async(fn -> mid_run_events() end)

    exit_reason = wait_for_exit(Keyword.get(opts, :timeout_ms, 120_000))

    Task.shutdown(stream_task, :brutal_kill)
    Task.shutdown(permission_task, :brutal_kill)

    report = Renderer.latency_report()
    IO.puts(:stderr, "keypress-to-echo latency: #{inspect(report)}")
    IO.puts(:stderr, "exit_reason=#{exit_reason}")
    report
  end

  defp ensure_ui_started do
    case Process.whereis(UISupervisor) do
      nil -> {:ok, _pid} = UISupervisor.start_link(mode: :inline, commands: @commands)
      _pid -> :ok
    end
  end

  @doc """
  The zoned-UI demo (`docs/design/tui-zones.md`): a full scripted mission
  end to end — the PM's questions, a user reply, researchers streaming
  findings into Conversation, an agent expanded live in Detail (via real
  `{:input_event, _}`s, the same events a keyboard produces — not a
  demo-only backdoor), the budget meter filling as fake usage settles, a
  source opened from Inspector into Detail, a permission prompt, and
  message-flow traffic animating in the Agents gutter and the `f` overlay
  — plus the same input loop as `run/1` for the person watching to take
  over. `mix sprat.demo --zones`.
  """
  @demo_agents [
    %{id: "pm", role: :pm, label: "PM", state: :idle, elapsed_s: nil, tokens: nil, activity: nil},
    %{
      id: "r1",
      role: :researcher,
      label: "Researcher·1",
      state: :idle,
      elapsed_s: nil,
      tokens: nil,
      activity: nil
    },
    %{
      id: "r2",
      role: :researcher,
      label: "Researcher·2",
      state: :idle,
      elapsed_s: nil,
      tokens: nil,
      activity: nil
    },
    %{
      id: "an",
      role: :analyst,
      label: "Analyst",
      state: :queued,
      elapsed_s: nil,
      tokens: nil,
      activity: nil
    }
  ]

  def run_zones(opts \\ []) do
    unless Mode.tty?() do
      IO.puts(:stderr, "Sprat.Demo requires a real TTY (stdin and stdout).")
      exit({:shutdown, 1})
    end

    case Process.whereis(UISupervisor) do
      nil -> {:ok, _pid} = UISupervisor.start_link(mode: :zoned, commands: @commands)
      _pid -> :ok
    end

    ZonedRenderer.subscribe(self())

    ZonedRenderer.commit([
      "Welcome to the Sprat zoned UI demo.",
      "Tab / Shift+Tab: next/previous zone (NAV) · 1..6 or Alt+1..6: jump · i / Enter: INSERT · Esc: NAV",
      "f / Alt+f: message-flow overlay · resize to see every breakpoint."
    ])

    ZonedRenderer.set_live(%{
      activity: %{verb: "Researching", elapsed_s: 0},
      checklist: %{stages: [{"Intake", :done}, {"Research", :active}, {"Analysis", :pending}]},
      budget: %{spent: nil, cap: Decimal.new("5.00")},
      mode: "normal"
    })

    ZonedRenderer.set_agents(%{agents: @demo_agents, messages: []})
    ZonedRenderer.set_inspector(%{sources: [], tasks: [], events: []})

    ZonedRenderer.start_animation()
    ticker = spawn_link(fn -> tick_zones_elapsed(0) end)
    story = spawn_link(fn -> run_story() end)

    exit_reason = wait_for_exit_zones(Keyword.get(opts, :timeout_ms, 300_000))

    Process.exit(ticker, :kill)
    Process.exit(story, :kill)
    ZonedRenderer.stop_animation()
    IO.puts(:stderr, "exit_reason=#{exit_reason}")
    exit_reason
  end

  defp tick_zones_elapsed(seconds) do
    Process.sleep(1_000)
    ZonedRenderer.set_live(%{activity: %{verb: "Researching", elapsed_s: seconds + 1}})
    tick_zones_elapsed(seconds + 1)
  end

  # Drives the demo end to end: the PM's questions and a user reply
  # (Conversation), researchers streaming findings, an agent expanded in
  # Detail and kept pinned (via real `{:input_event, _}`s sent to the
  # renderer — the exact same events a keyboard produces, not a
  # demo-only backdoor into Detail's state), the budget meter filling,
  # a source opened from Inspector into Detail, and a permission prompt —
  # this is the artefact the design is judged by, so every zone gets
  # something real in it, not just Conversation. Confined to this demo
  # path per the task brief: a real session with no agents/no orchestrator
  # renders every one of these zones honestly empty instead.
  @doc false
  def run_story do
    Process.sleep(800)

    ZonedRenderer.commit([
      "⏺ PM",
      "  Three questions change the direction:",
      "  1. Owner-operated gyms, or small chains?",
      "  2. A revenue tool, or one for gyms you already run?",
      "  3. Any constraint on mobile?"
    ])

    Process.sleep(1_400)
    ZonedRenderer.commit(["> owner-operated, revenue, web first"])

    Process.sleep(800)
    agents = wake(@demo_agents, "pm", :active, "scheduling research")
    agents = wake(agents, "r1", :active, "competitor matrix")
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("pm", "r1", :assignment))

    Process.sleep(600)
    agents = wake(agents, "r2", :active, "reddit complaints")
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("pm", "r2", :assignment))

    stream_findings()

    Process.sleep(400)

    agents =
      wake(agents, "r1", :waiting_on_tool, "web_fetch gymcatch.com/sales-1",
        stream_tail: ["3.1 KB fetched", "extracting claims…"]
      )

    ZonedRenderer.set_agents(%{agents: agents})

    # Expand Researcher·1 into Detail and pin it, through the real input
    # pipeline (NAV, jump to Agents, select, Enter, Space) — proves the
    # wiring end to end and gives Detail's live-refresh (see
    # `Zones.Detail.handle_view_update/2`) something to keep updating.
    # `Enter` always drops Focus back into INSERT (`Terminal.Focus`'s own
    # `:enter` clause, unconditionally — see its moduledoc), so getting
    # back to NAV for the follow-up `Space` (pin) needs its own `Esc`
    # rather than assuming Enter left NAV alone.
    send_key(:esc)
    send_key({:char, "2"})
    send_key(:down)
    send_key(:enter)
    send_key(:esc)
    send_key({:char, " "})
    send_key({:char, "i"})

    Process.sleep(1_200)

    agents =
      wake(agents, "r1", :waiting_on_tool, "web_fetch gymcatch.com/sales-1",
        elapsed_s: 4,
        tokens: 620
      )

    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.set_live(%{budget: %{spent: Decimal.new("0.38"), cap: Decimal.new("5.00")}})

    Process.sleep(1_000)
    agents = wake(agents, "r1", :done, "7 products · 12 sources", elapsed_s: 9, tokens: 1180)
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("r1", "pm", :evidence))
    ZonedRenderer.set_live(%{budget: %{spent: Decimal.new("0.91"), cap: Decimal.new("5.00")}})

    source = %{
      title: "clubright.co.uk",
      url: "https://clubright.co.uk/pricing",
      source_type: "website",
      retrieved_at: clock()
    }

    ZonedRenderer.set_inspector(%{sources: [source]})

    ZonedRenderer.set_live(%{
      permission: %{
        title: "Record source",
        lines: ["Researcher·1 wants to record a new source in the register:", "  #{source.url}"],
        options: ["Yes", "Yes, and trust clubright.co.uk for this mission", "No"],
        selected: 0
      }
    })

    Process.sleep(1_800)
    ZonedRenderer.set_live(%{permission: nil})

    # Open the source from Inspector into Detail — a second card joins
    # the still-pinned Researcher·1 (Inspector items don't pin — Space is
    # an Agents-only affordance per the design's "pinned with Space" —
    # this one just becomes Detail's unpinned preview slot, which is
    # exactly what `open/2`'s "never evicts a pinned card" rule is for).
    send_key(:esc)
    send_key({:char, "4"})
    send_key(:enter)
    send_key({:char, "i"})

    Process.sleep(1_200)
    agents = wake(agents, "r2", :done, "9 reviews · 3 claims", elapsed_s: 12, tokens: 940)
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("r2", "pm", :evidence))
    ZonedRenderer.set_live(%{budget: %{spent: Decimal.new("1.42"), cap: Decimal.new("5.00")}})

    Process.sleep(1_000)
    agents = wake(agents, "an", :active, "synthesising competitor matrix", elapsed_s: 0)
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("r1", "an", :handoff))

    Process.sleep(1_800)
    agents = wake(agents, "an", :done, "directions drafted", elapsed_s: 6, tokens: 2100)
    ZonedRenderer.set_agents(%{agents: agents})
    ZonedRenderer.add_message(msg("an", "pm", :review))
    ZonedRenderer.set_live(%{budget: %{spent: Decimal.new("1.87"), cap: Decimal.new("5.00")}})

    ZonedRenderer.set_live(%{
      checklist: %{stages: [{"Intake", :done}, {"Research", :done}, {"Analysis", :active}]}
    })
  end

  defp stream_findings do
    lines = [
      "⏺ Researcher·1",
      "  Owner-operated gyms juggle three systems: booking, payments,",
      "  access control. Complaints point at fragmentation.",
      "",
      "⏺ Researcher·2",
      "  Glofox and TeamUp dominate mid-market UK gyms; reviewers",
      "  mention onboarding friction and slow support."
    ]

    Enum.each(lines, fn line ->
      ZonedRenderer.commit([line])
      Process.sleep(140)
    end)
  end

  defp wake(agents, id, new_state, activity, extra \\ []) do
    Enum.map(agents, fn
      %{id: ^id} = a ->
        a
        |> Map.merge(%{state: new_state, activity: activity})
        |> Map.merge(Map.new(extra))

      a ->
        a
    end)
  end

  # No `:frame` here — `ZonedRenderer.add_message/2` stamps that itself
  # from the live `Terminal.Animate` clock (see its doc for why this
  # matters: a caller-supplied frame counter drifts from the real one).
  defp msg(from, to, type), do: %{from: from, to: to, type: type, at: clock()}

  defp send_key(event),
    do: send(Process.whereis(Sprat.Terminal.ZonedRenderer), {:input_event, event})

  defp clock, do: DateTime.utc_now() |> DateTime.to_string() |> String.slice(11, 8)

  defp wait_for_exit_zones(timeout_ms) do
    receive do
      {:sprat_intent, {:submit, text}} ->
        ZonedRenderer.commit(["> " <> text])
        wait_for_exit_zones(timeout_ms)

      {:sprat_intent, :exit} ->
        :exit

      {:sprat_intent, :input_closed} ->
        :input_closed

      {:sprat_intent, _other} ->
        wait_for_exit_zones(timeout_ms)
    after
      timeout_ms -> :timeout
    end
  end

  defp seed(opts) do
    Renderer.commit(welcome_box())

    Renderer.commit(
      Transcript.user_message("I want to build software for independent gyms in the UK",
        dim?: true
      )
    )

    Renderer.set_live(%{
      activity: %{verb: "Researching", elapsed_s: 0, tokens: 0},
      checklist: %{
        stages: [
          {"Intake", :done},
          {"Research", :active},
          {"Analysis", :pending},
          {"Directions", :pending},
          {"Brief + validation plan", :pending}
        ]
      }
    })

    Renderer.commit(
      Transcript.tool_call(
        "Researcher·1",
        "web_search(\"independent gym management software UK\")"
      )
    )

    Renderer.commit(Transcript.tool_result("10 results · 4 new sources recorded", 76))

    if Keyword.get(opts, :fixed_elapsed?, false), do: :ok, else: start_elapsed_ticker()
  end

  defp start_elapsed_ticker do
    spawn_link(fn -> tick_elapsed(0) end)
  end

  defp tick_elapsed(seconds) do
    Process.sleep(1_000)

    Renderer.set_live(%{
      activity: %{verb: "Researching", elapsed_s: seconds + 1, tokens: seconds * 40}
    })

    tick_elapsed(seconds + 1)
  end

  defp stream_role(role) do
    Enum.each(@paragraphs[role], fn chunk ->
      chunk
      |> String.split(~r/(?<=\s)/)
      |> Enum.each(fn token ->
        Renderer.stream_delta(role, token)
        Process.sleep(5)
      end)
    end)
  end

  defp mid_run_events do
    Process.sleep(2_000)

    Renderer.commit(Transcript.tool_call("Researcher·2", "web_fetch(reddit.com/r/gymowners/…)"))
    Renderer.commit(Transcript.tool_result("Fetched 3.1 KB · 2 claims recorded", 76))

    Process.sleep(2_000)

    Renderer.set_live(%{
      permission: %{
        title: "Fetch URL",
        lines: [
          "Researcher·2 wants to fetch a URL it composed itself:",
          "  https://example.com/api?q=booking+software"
        ],
        options: [
          "Yes",
          "Yes, and allow example.com for this mission",
          "No, and tell the Researcher what to do instead"
        ],
        selected: 0
      }
    })
  end

  defp wait_for_exit(timeout_ms) do
    receive do
      {:sprat_intent, {:submit, text}} ->
        Renderer.commit(Transcript.user_message(text))
        wait_for_exit(timeout_ms)

      {:sprat_intent, {:permission_result, n}} ->
        Renderer.commit(["  selected option #{n + 1}"])
        wait_for_exit(timeout_ms)

      {:sprat_intent, :permission_cancelled} ->
        Renderer.commit(["  permission cancelled"])
        wait_for_exit(timeout_ms)

      {:sprat_intent, :exit} ->
        :exit

      {:sprat_intent, :input_closed} ->
        :input_closed

      {:sprat_intent, _other} ->
        wait_for_exit(timeout_ms)
    after
      timeout_ms -> :timeout
    end
  end

  defp welcome_box do
    [
      ANSI.cyan() <>
        "╭──────────────────────────────────────────────────────────╮" <> ANSI.reset(),
      ANSI.cyan() <> "│ ✻ Sprat  v0.1.0" <> String.duplicate(" ", 44) <> "│" <> ANSI.reset(),
      ANSI.cyan() <>
        "│   /help for commands · Shift+Tab to change mode" <>
        String.duplicate(" ", 11) <>
        "│" <>
        ANSI.reset(),
      ANSI.cyan() <>
        "╰──────────────────────────────────────────────────────────╯" <> ANSI.reset()
    ]
  end
end
