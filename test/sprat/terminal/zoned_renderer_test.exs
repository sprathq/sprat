defmodule Sprat.Terminal.ZonedRendererTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.ZonedRenderer

  defp start_capture do
    {:ok, pid} = StringIO.open("")
    pid
  end

  defp captured(pid) do
    {:ok, {_in, out}} = StringIO.close(pid)
    out
  end

  defp start_renderer(opts \\ []) do
    io = start_capture()
    name = :"zoned_renderer_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ZonedRenderer.start_link(
        Keyword.merge([io_device: io, name: name, skip_timers: true, size: {100, 30}], opts)
      )

    {pid, io, name}
  end

  # Same deterministic sync trick as RendererTest: `:do_repaint` is only
  # ever scheduled via `Process.send_after/3`, so sending it directly
  # reproduces the eventual timer fire without sleeping. Uses `:infinity`
  # for the same reason as RendererTest.sync/1: FIFO delivery already
  # guarantees correct ordering, so the only thing a fixed timeout could
  # catch is wall-clock scheduler contention under a loaded test run, not
  # a real bug — `:infinity` removes that race instead of widening it.
  defp sync(server) do
    server = if is_atom(server), do: Process.whereis(server), else: server
    send(server, :do_repaint)
    GenServer.call(server, :snapshot, :infinity)
  end

  test "does not write any escape bytes when io_device is injected (test guarantee)" do
    {pid, io, name} = start_renderer()
    ZonedRenderer.commit(name, ["hello from conversation"])
    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    # The alternate-screen enter/leave is only written for the real :stdio
    # device (see init/1 and terminate/2) — never for an injected one.
    refute out =~ "?1049h"
  end

  test "commit/2 appends to the Conversation zone, visible on the next repaint" do
    {pid, _io, name} = start_renderer()
    ZonedRenderer.commit(name, ["a-distinctive-token"])
    state = sync(name)
    GenServer.stop(pid)
    # Assert on the actual flushed cell frame (`state.screen`), not the
    # raw ANSI byte stream: damage tracking may legitimately skip a cell
    # whose character already matches the previous frame (the empty
    # Conversation zone's first-run hint text, in this case — see
    # `Zones.Conversation`), which can split a word across a cursor-jump
    # escape in the bytes without it being wrong on screen — the frame is
    # what's actually rendered.
    assert screen_text(state.screen) =~ "a-distinctive-token"
  end

  defp screen_text(frame) do
    frame
    |> Enum.sort_by(fn {row, _} -> row end)
    |> Enum.map_join("\n", fn {_row, cells} ->
      Enum.map_join(cells, fn
        :cont -> ""
        {g, _style} -> g
      end)
    end)
  end

  test "set_live/2 updates the Mission zone's checklist/activity text" do
    {pid, _io, name} = start_renderer()

    ZonedRenderer.set_live(name, %{
      activity: %{verb: "Researching", elapsed_s: 3},
      checklist: %{stages: [{"Intake", :done}, {"Research", :active}]}
    })

    snap = sync(name)
    GenServer.stop(pid)
    # Damage-tracked diff output only ever contains *changed* bytes, so a
    # cell that coincidentally already showed the right character (e.g.
    # "checklist"'s 'c' landing where "Researching"'s 'c' now does) is
    # never rewritten — asserting on the raw write stream can't
    # reconstruct the full word. Assert on the zone's own state instead,
    # which is what actually drives every cell.
    {Sprat.Terminal.Zones.Mission, mission} = snap.zones.mission
    assert mission.activity.verb == "Researching"
    assert {"Intake", :done} in mission.checklist.stages
  end

  test "snapshot/1 reports the terminal size" do
    {pid, _io, name} = start_renderer(size: {123, 45})
    snap = ZonedRenderer.snapshot(name)
    assert snap.cols == 123
    assert snap.rows == 45
    GenServer.stop(pid)
  end

  test "Ctrl+C then Ctrl+C again (empty composer) exits, forwarded as :exit" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())
    send(Process.whereis(name), {:input_event, :ctrl_c})
    send(Process.whereis(name), {:input_event, :ctrl_c})
    assert_receive {:sprat_intent, :exit}, 500
    GenServer.stop(pid)
  end

  # Bug: `Terminal.Keybindings.handle_ctrl_c/3` returns `:clear_composer`
  # for a Ctrl+C with unsent text, but nothing ever handled that intent —
  # it fell through to `notify/2`, forwarded to the shell process, and the
  # composer's own text never cleared. Confirmed live: with the BREAK-menu
  # bug fixed (`rel/vm.args.eex`/`Sprat.Terminal.Mode`), Ctrl+C on a
  # non-empty composer silently did nothing at all.
  test "Ctrl+C on a non-empty composer clears it (does not exit or forward)" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())
    send(Process.whereis(name), {:input_event, {:char, "h"}})
    send(Process.whereis(name), {:input_event, :ctrl_c})
    snap = sync(name)
    GenServer.stop(pid)

    {Sprat.Terminal.Zones.Composer, composer} = snap.zones.composer
    assert composer.composer.text == ""
    refute_received {:sprat_intent, :exit}
  end

  test "typing in INSERT mode routes to the composer and Enter submits" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())
    for ch <- ["h", "i"], do: send(Process.whereis(name), {:input_event, {:char, ch}})
    send(Process.whereis(name), {:input_event, :enter})
    assert_receive {:sprat_intent, {:submit, "hi"}}, 500
    GenServer.stop(pid)
  end

  test "Esc leaves INSERT for NAV; in NAV, digit 1 jumps focus to Mission" do
    {pid, _io, name} = start_renderer()
    send(Process.whereis(name), {:input_event, :esc})
    send(Process.whereis(name), {:input_event, {:char, "1"}})
    snap = sync(name)
    assert snap.focus.mode == :nav
    assert Sprat.Terminal.Focus.current(snap.focus) == :mission
    GenServer.stop(pid)
  end

  test "an unhandled NAV key sets a footer hint instead of vanishing" do
    {pid, _io, name} = start_renderer()
    send(Process.whereis(name), {:input_event, :esc})
    send(Process.whereis(name), {:input_event, {:char, "z"}})
    snap = sync(name)
    assert snap.hint.text =~ "z"
    GenServer.stop(pid)
  end

  test "a set_live permission prompt takes over input until answered" do
    {pid, io, name} = start_renderer(intent_subscriber: self())

    ZonedRenderer.set_live(name, %{
      permission: %{title: "Fetch URL", lines: ["proceed?"], options: ["Yes", "No"], selected: 0}
    })

    sync(name)
    out = captured(io)
    assert out =~ "Fetch"
    assert out =~ "proceed?"

    send(Process.whereis(name), {:input_event, :down})
    send(Process.whereis(name), {:input_event, :enter})
    assert_receive {:sprat_intent, {:permission_result, 1}}, 500
    GenServer.stop(pid)
  end

  test "Esc cancels a pending permission prompt" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())

    ZonedRenderer.set_live(name, %{
      permission: %{title: "Fetch URL", lines: [], options: ["Yes", "No"], selected: 0}
    })

    sync(name)
    send(Process.whereis(name), {:input_event, :esc})
    assert_receive {:sprat_intent, :permission_cancelled}, 500
    GenServer.stop(pid)
  end

  # Regression for the zoned-UI defect a live run caught: `paint/1` used to
  # have a separate clause for `state.permission` that painted from
  # `Screen.blank/2` instead of the real zone layout, so the Mission
  # checklist and Conversation history vanished behind the prompt. The
  # permission box must now composite on top of the normal frame, the same
  # way the flow/settings/debug overlays already do.
  test "a permission prompt does not blank the Mission checklist or Conversation history" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())

    ZonedRenderer.commit(name, ["a-distinctive-conversation-line"])

    ZonedRenderer.set_live(name, %{
      checklist: %{stages: [{"a-distinctive-checklist-item", :active}]},
      permission: %{title: "Fetch URL", lines: ["proceed?"], options: ["Yes", "No"], selected: 0}
    })

    state = sync(name)
    GenServer.stop(pid)

    text = screen_text(state.screen)
    assert text =~ "Fetch URL"
    assert text =~ "a-distinctive-conversation-line"
    # The Mission zone's own width may ellipsis-truncate a long checklist
    # item — assert on a prefix that survives that truncation rather than
    # the full literal.
    assert text =~ "a-distinctive-checklist"
  end

  # A paste can legitimately race an open permission prompt (an agent
  # asks for approval while the user is mid-paste) — it must not crash
  # the renderer or leak into the composer once the prompt is answered.
  test "a paste event while a permission prompt is open is ignored, not crashed on or queued" do
    {pid, _io, name} = start_renderer(intent_subscriber: self())

    ZonedRenderer.set_live(name, %{
      permission: %{title: "Fetch URL", lines: [], options: ["Yes", "No"], selected: 0}
    })

    sync(name)
    send(Process.whereis(name), {:input_event, {:paste, "some pasted text\nmore"}})
    snap = sync(name)
    assert Process.alive?(pid)
    assert snap.permission != nil

    {Sprat.Terminal.Zones.Composer, composer} = snap.zones.composer
    assert composer.composer.text == ""
    GenServer.stop(pid)
  end

  test "no animation timer is armed unless start_animation/1 is called" do
    {pid, _io, name} = start_renderer()
    snap = ZonedRenderer.snapshot(name)
    refute snap.animate.running?
    GenServer.stop(pid)
  end

  describe "content_width/1 (the Conversation zone's real interior width)" do
    test "is narrower than raw cols once Mission/Agents/Inspector share the wide layout" do
      # 100x30 lands in the >=100 breakpoint (two_column): a 28-col left
      # rail plus a 1-col gutter is carved out of `cols` before the
      # Conversation zone gets anything, and its own border eats 2 more.
      {pid, _io, name} = start_renderer(size: {100, 30})
      width = ZonedRenderer.content_width(name)
      snap = ZonedRenderer.snapshot(name)
      assert width < snap.cols
      assert width == snap.cols - 28 - 1 - 2
      GenServer.stop(pid)
    end

    test "at the narrow single-column breakpoint, is close to the full width minus the border" do
      {pid, _io, name} = start_renderer(size: {90, 30})
      width = ZonedRenderer.content_width(name)
      snap = ZonedRenderer.snapshot(name)
      assert width == snap.cols - 2
      GenServer.stop(pid)
    end
  end

  describe "defect 3 regression: only expected ANSI/cell bytes ever land on the device" do
    test "crashing the renderer writes no raw crash-report text to its io_device" do
      Process.flag(:trap_exit, true)
      {pid, io, name} = start_renderer()
      ZonedRenderer.commit(name, ["a-distinctive-token"])
      sync(name)

      # An unmatched `handle_info` is a real crash (`Sprat.LogHandler`'s
      # target — installed as a `:logger` handler — is what actually gets
      # a crash report, never this GenServer's own `io_device`; this test
      # pins the other half of defect 3's contract: whatever OTP does with
      # a crash, this module's `io_device` writes stay ANSI/cell writes,
      # never raw text, `terminate/2` included). Mirrors
      # `test/tty/verify.sh`'s `:force_a_crash_for_verify_sh` trigger
      # against the real release.
      send(pid, :not_a_real_message)

      receive do
        {:EXIT, ^pid, _reason} -> :ok
      after
        1000 -> flunk("renderer did not crash/exit as expected")
      end

      out = captured(io)
      refute out =~ "** ("
      refute out =~ "FunctionClauseError"
      refute out =~ "GenServer"
      refute out =~ "terminating"
      # Nothing that made it onto the device before the crash is raw text
      # either — always a cursor-position escape followed by styled cells.
      assert out == "" or out =~ "\e["
    end
  end
end
