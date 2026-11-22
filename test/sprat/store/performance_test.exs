defmodule Sprat.Store.PerformanceTest do
  @moduledoc """
  Measures the two numbers docs/spec-v1.md §16 names: event append p95
  (< 100 ms) and reading back a 10,000-event session (< 1.5 s). Prints
  what it measured so the numbers end up in test output, not just a
  pass/fail.
  """

  use Sprat.StoreCase, async: true

  alias Sprat.Store.Events

  @tag :performance
  test "event append p95 is under 100ms, and a 10,000-event session reads back under 1.5s", %{
    store: store
  } do
    {session, _mission, _task} = fixture_chain(store)

    n = 10_000

    durations_us =
      for i <- 1..n do
        {t, {:ok, _event}} =
          :timer.tc(fn ->
            Events.append(store, session.id, "perf_#{i}", %{payload: %{"i" => i}})
          end)

        t
      end

    sorted = Enum.sort(durations_us)
    p95_us = Enum.at(sorted, ceil(n * 0.95) - 1)
    p95_ms = p95_us / 1000

    {read_us, events} = :timer.tc(fn -> Events.by_session(store, session.id, limit: n) end)
    read_ms = read_us / 1000

    IO.puts("\nSprat.Store performance (n=#{n}):")
    IO.puts("  event append p50: #{(Enum.at(sorted, div(n, 2)) / 1000) |> Float.round(3)} ms")
    IO.puts("  event append p95: #{Float.round(p95_ms, 3)} ms")
    IO.puts("  10,000-event session read: #{Float.round(read_ms, 3)} ms")

    assert length(events) == n
    assert p95_ms < 100, "event append p95 was #{p95_ms}ms, target < 100ms"
    assert read_ms < 1_500, "10,000-event read took #{read_ms}ms, target < 1500ms"
  end
end
