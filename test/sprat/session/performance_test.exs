defmodule Sprat.Session.PerformanceTest do
  @moduledoc """
  Measures the number docs/spec-v1.md §16 names for resume: "Resume and
  render a 2,000-event session: < 1.5 s p95". Populates a session with
  2,000 blocks first (not timed — that's write throughput, covered by
  `Sprat.Store.PerformanceTest`), then times only what resuming actually
  costs: `Sprat.Session.init/1`'s replay from the store (a real process
  restart, not a mock) plus `Sprat.Session.Subscriber`'s single batched
  commit through a real `Sprat.Terminal.Renderer`.
  """

  use Sprat.StoreCase, async: true

  alias Sprat.{Session, SessionSupervisor}
  alias Sprat.Session.Subscriber
  alias Sprat.Store.Sessions
  alias Sprat.Terminal.Renderer

  @tag :performance
  test "resuming and rendering a 2,000-block session is under 1.5s", %{store: store} do
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/proj-perf"})
    {:ok, pid} = SessionSupervisor.open(session.id, store: store)

    n = 2_000

    for i <- 1..n do
      if rem(i, 2) == 0 do
        Session.submit_user_message(pid, "message number #{i}")
      else
        Session.add_block(pid, %{kind: :agent_message, role: "PM", markdown: "reply number #{i}"})
      end
    end

    :ok = DynamicSupervisor.terminate_child(Sprat.SessionSupervisor, pid)

    {resume_us, {:ok, new_pid}} =
      :timer.tc(fn -> SessionSupervisor.open(session.id, store: store) end)

    assert length(Session.snapshot(new_pid).blocks) == n

    {:ok, io} = StringIO.open("")
    name = :"perf_renderer_#{System.unique_integer([:positive])}"
    {:ok, renderer_pid} = Renderer.start_link(io_device: io, name: name, skip_timers: true)

    {render_us, {:ok, sub_pid}} =
      :timer.tc(fn -> Subscriber.start_link(session_id: session.id, renderer: name, cols: 80) end)

    total_ms = (resume_us + render_us) / 1000

    IO.puts("\nSprat.Session resume+render performance (n=#{n} blocks):")
    IO.puts("  Session.init (store replay): #{Float.round(resume_us / 1000, 2)} ms")
    IO.puts("  Subscriber replay (batched commit): #{Float.round(render_us / 1000, 2)} ms")
    IO.puts("  total: #{Float.round(total_ms, 2)} ms")

    GenServer.stop(sub_pid)
    GenServer.stop(renderer_pid)

    assert total_ms < 1_500, "resume+render took #{total_ms}ms, target < 1500ms"
  end
end
