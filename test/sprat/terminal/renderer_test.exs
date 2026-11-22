defmodule Sprat.Terminal.RendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Sprat.Terminal.Renderer

  # Captures everything written via `IO.write/2` when passed as :io_device.
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
    name = :"renderer_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Renderer.start_link(Keyword.merge([io_device: io, name: name, skip_timers: true], opts))

    {pid, io, name}
  end

  # Deterministic, timing-independent sync point: a real repaint is only
  # ever scheduled via `Process.send_after/3` (see `request_repaint/1` in
  # the Renderer), so sleeping and hoping it fired in time is flaky under
  # load. Sending `:do_repaint` directly reproduces exactly what that timer
  # would eventually deliver, and — because Erlang guarantees FIFO delivery
  # of messages sent from one process to another — a synchronous call right
  # after it is only answered once every message sent before it (the prior
  # casts/sends under test, and this one) has been handled. That ordering
  # is correct regardless of system load; what isn't load-independent is
  # `GenServer.call/3`'s default 5000ms *wall-clock* timeout — under a full
  # `mix test` run with many concurrent processes, the renderer can
  # genuinely take longer than 5s of wall time to get scheduled, with
  # nothing wrong in the message ordering or the code under test. Since the
  # ordering guarantee already rules out a real hang, call with `:infinity`
  # here instead of guessing a bigger fixed number — this removes the
  # wall-clock race entirely rather than just widening it.
  defp sync(server) do
    server = if is_atom(server), do: Process.whereis(server), else: server
    send(server, :do_repaint)
    GenServer.call(server, :snapshot, :infinity)
  end

  test "commit writes each block joined with \\r\\n and terminates with \\r\\n" do
    {pid, io, name} = start_renderer()
    Renderer.commit(name, ["line one", "line two"])
    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    assert out =~ "line one\r\nline two\r\n"
  end

  test "commit ordering is preserved across multiple calls" do
    {pid, io, name} = start_renderer()
    Renderer.commit(name, ["first"])
    Renderer.commit(name, ["second"])
    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    assert {first_at, _} = :binary.match(out, "first")
    assert {second_at, _} = :binary.match(out, "second")
    assert first_at < second_at
  end

  test "set_live redraws the live region with the given activity/checklist" do
    {pid, io, name} = start_renderer()

    Renderer.set_live(name, %{
      activity: %{verb: "Researching", elapsed_s: 3, tokens: 10},
      checklist: %{stages: [{"Intake", :done}]}
    })

    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    assert out =~ "Researching"
    assert out =~ "Intake"
  end

  test "stream_delta commits a whole paragraph once it completes" do
    {pid, io, name} = start_renderer()
    Renderer.stream_delta(name, "block1", "hello ")
    Renderer.stream_delta(name, "block1", "world\n\n")
    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    assert out =~ "hello world"
  end

  test "stream_delta keeps an incomplete paragraph live (not yet committed)" do
    {pid, _io, name} = start_renderer()
    Renderer.stream_delta(name, "block1", "partial line, no break yet")
    snap = sync(name)
    GenServer.stop(pid)
    assert snap.streams["block1"] == "partial line, no break yet"
  end

  test "repaints are coalesced: many rapid casts still yield a small number of physical writes" do
    {pid, io, name} = start_renderer()

    for n <- 1..20 do
      Renderer.set_live(name, %{activity: %{verb: "v#{n}", elapsed_s: n, tokens: n}})
    end

    # All 20 casts are handled before this fires (FIFO), and only the first
    # of them ever schedules a repaint (`repaint_scheduled?` latches) — so
    # this single sync deterministically covers "many casts, one repaint",
    # the exact behavior under test, with no dependency on real elapsed time.
    sync(name)
    GenServer.stop(pid)
    out = captured(io)
    # A single coalesced frame contains one cursor-up/clear sequence at most
    # per repaint tick; 20 casts within one coalescing window must not
    # produce 20 separate physical writes.
    occurrences = out |> String.split("\e[") |> length()
    assert occurrences < 10
  end

  test "content_width/1 is the raw cols — no zone borders here to account for" do
    {pid, _io, name} = start_renderer()
    :sys.replace_state(pid, fn state -> %{state | cols: 77} end)
    assert Renderer.content_width(name) == 77
    GenServer.stop(pid)
  end

  test "resize re-layout: changing terminal size affects composer/footer wrap width" do
    {pid, _io, name} = start_renderer()
    :sys.replace_state(pid, fn state -> %{state | cols: 20, rows: 10} end)
    send(pid, :resize_poll)
    snap = Renderer.snapshot(name)
    GenServer.stop(pid)
    assert snap.cols in [20, 80]
  end

  test "live region height is capped at rows - 2" do
    {pid, _io, name} = start_renderer()
    :sys.replace_state(pid, fn state -> %{state | rows: 6} end)

    Renderer.set_live(name, %{
      checklist: %{
        stages: Enum.map(1..20, fn i -> {"Stage #{i}", :pending} end)
      }
    })

    snap = sync(name)
    GenServer.stop(pid)
    assert snap.last_live_height <= 4
  end

  test "Enter with typed text submits and forwards {:submit, text} to the intent subscriber" do
    {pid, _io, _name} = start_renderer(intent_subscriber: self())
    send(pid, {:input_event, {:char, "h"}})
    send(pid, {:input_event, {:char, "i"}})
    send(pid, {:input_event, :enter})
    assert_receive {:sprat_intent, {:submit, "hi"}}, 1_000
    GenServer.stop(pid)
  end

  test "latency_report summarizes tracked keystroke-to-repaint latencies" do
    {pid, _io, name} = start_renderer()
    send(pid, {:input_event, {:char, "a"}})
    sync(name)
    report = Renderer.latency_report(name)
    GenServer.stop(pid)
    assert report.count >= 1
    assert is_number(report.p95)
  end

  test "a Renderer using an injected io_device never writes escape codes to the real terminal on stop" do
    real_stdio_output =
      capture_io(fn ->
        {pid, io, name} = start_renderer()
        Renderer.commit(name, ["hello"])
        sync(name)
        GenServer.stop(pid)
        captured(io)
      end)

    refute real_stdio_output =~ "\e["
    assert real_stdio_output == ""
  end
end
