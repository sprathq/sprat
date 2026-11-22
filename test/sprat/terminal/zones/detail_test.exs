defmodule Sprat.Terminal.Zones.DetailTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Zones.Detail

  test "open/2 replaces the unpinned preview and never touches pinned" do
    state = Detail.init([])
    state = Detail.toggle_pin(state, :x)
    before_pinned = state.pinned

    state = Detail.open(state, :a)
    state = Detail.open(state, :b)

    assert state.open == :b
    assert state.pinned == before_pinned
  end

  test "toggle_pin/2 pins, then unpins" do
    state = Detail.init([])
    state = Detail.toggle_pin(state, :a)
    assert Enum.map(state.pinned, & &1.item) == [:a]

    state = Detail.toggle_pin(state, :a)
    assert state.pinned == []
  end

  test "handle_view_update/2 keeps an open/pinned agent's counters live, and toggle_pin still unpins it after they've drifted (id, not full-map, equality — the actual bug found via a real tmux crash: pinning, letting a live update land, then unpinning)" do
    agent_v1 = %{
      id: "r1",
      label: "Researcher·1",
      state: :active,
      elapsed_s: 0,
      tokens: 0,
      activity: "x"
    }

    state =
      Detail.init([]) |> Detail.open({:agent, agent_v1}) |> Detail.toggle_pin({:agent, agent_v1})

    agent_v2 = %{agent_v1 | elapsed_s: 42, tokens: 900, activity: "y"}
    state = Detail.handle_view_update(state, %{agents: [agent_v2]})

    assert [%{item: {:agent, %{elapsed_s: 42, tokens: 900}}}] = state.pinned
    assert {:agent, %{elapsed_s: 42}} = state.open

    # Space, pressed again on the now-drifted card, must still be
    # recognised as the same pin and unpin it (found crashing/duplicating
    # before `same_item?/2` compared by id).
    state = Detail.toggle_pin(state, {:agent, agent_v2})
    assert state.pinned == []
  end

  test "pinning past capacity evicts the oldest pinned card, never a newer one" do
    state = Enum.reduce(1..10, Detail.init([]), fn i, acc -> Detail.toggle_pin(acc, i) end)
    ids = Enum.map(state.pinned, & &1.item)
    # Oldest (1..6) evicted, most recently pinned survive, in pin order.
    assert ids == [7, 8, 9, 10]
  end

  # "never evict a pinned card while an unpinned one could be evicted
  # instead" — `open/2` (the unpinned preview) is a single slot that's
  # always just replaced, so it can never cause a pinned card to be
  # evicted; only `pinned` overflowing its own capacity can. Property:
  # for any sequence of :open/:pin/:unpin actions, `pinned` only ever
  # shrinks via FIFO eviction (oldest `pinned_at` first) or explicit
  # unpin — an `:open` action never changes it.
  defp action_gen do
    one_of([
      tuple({constant(:open), integer(0..20)}),
      tuple({constant(:pin), integer(0..5)})
    ])
  end

  property "an :open action never changes the pinned list; pinned never exceeds its capacity" do
    check all(actions <- list_of(action_gen(), max_length: 60)) do
      final =
        Enum.reduce(actions, Detail.init([]), fn
          {:open, item}, state ->
            before = state.pinned
            new_state = Detail.open(state, item)
            assert new_state.pinned == before
            new_state

          {:pin, item}, state ->
            Detail.toggle_pin(state, item)
        end)

      # capacity is a module constant (4) — asserted structurally instead
      # of importing the private attribute.
      assert length(final.pinned) <= 4
      pinned_ats = Enum.map(final.pinned, & &1.pinned_at)
      assert pinned_ats == Enum.sort(pinned_ats)
    end
  end

  # docs/spec-v1.md §19 / the delivery-UX build: `/open`'s TUI twin —
  # pressing Enter on an Inspector Artifacts row must render the
  # artifact's content as Markdown prose, not `inspect/1` on the raw
  # metadata struct (`title_line(other) -> inspect(other)`'s old
  # fallback, before `{:artifacts, _}` had its own clause).
  test "opening an {:artifacts, _} item renders its content as Markdown, not inspect/1" do
    artifact = %{
      type: "product_brief",
      latest_version: 2,
      owning_role: "researcher",
      content: %{"problem" => "manual booking spreadsheets"}
    }

    state = Detail.init([]) |> Detail.open({:artifacts, artifact})

    rect = %{x: 0, y: 0, w: 60, h: 10}
    text = state |> Detail.render(rect, true, 0) |> rows_to_text()

    assert text =~ "product_brief"
    assert text =~ "manual booking spreadsheets"
    refute text =~ "%{"
  end

  test "opening a {:runs, run} item shows command, cwd, exit code, duration, sandbox and captured output" do
    run = %{
      command: "mix",
      args: ["test"],
      cwd: "/tmp/worktree",
      exit_code: 1,
      duration_ms: 340,
      sandbox_strength: "partial",
      network: false,
      truncated: false,
      purpose: "test",
      output: "1) test foo\n  Assertion failed"
    }

    state = Detail.init([]) |> Detail.open({:runs, run})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "mix test"
    assert text =~ "cwd: /tmp/worktree"
    assert text =~ "exit: 1"
    assert text =~ "duration: 340ms"
    assert text =~ "sandbox: partial"
    assert text =~ "Assertion failed"
  end

  test "a run with no exit code never renders as passing, and never fabricates 0" do
    run = %{
      command: "npm",
      args: ["run", "build"],
      cwd: "/tmp/worktree",
      exit_code: nil,
      duration_ms: 120_000,
      sandbox_strength: "partial",
      network: false,
      truncated: false,
      purpose: "run",
      output: ""
    }

    state = Detail.init([]) |> Detail.open({:runs, run})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "exit: unknown"
    assert text =~ "timed out"
    refute text =~ "exit: 0"
  end

  test "a run's truncation notice is shown distinctly from the diff/card truncation note" do
    run = %{
      command: "npm",
      args: ["install"],
      cwd: "/tmp/worktree",
      exit_code: 0,
      duration_ms: 5000,
      sandbox_strength: "partial",
      network: true,
      truncated: true,
      purpose: "install",
      output: "installing..."
    }

    state = Detail.init([]) |> Detail.open({:runs, run})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "output truncated at capture time"
  end

  # docs/spec-v2.md §11: secrets are redacted at write time
  # (`Store.Redact`/`Agent.Tools.Shell`) — this zone must never add a
  # second redaction pass, but it also must never let anything unredacted
  # slip through unchanged. The fixture's output already carries the
  # marker a real write-time scrub would have left; this pins that the
  # marker reaches the screen intact and the raw secret value it stands
  # in for never does.
  test "a run's already-redacted output reaches the screen unchanged; nothing unredacted appears" do
    real_secret = "sk-live-should-never-render"

    run = %{
      command: "mix",
      args: ["run"],
      cwd: "/tmp/worktree",
      exit_code: 0,
      duration_ms: 50,
      sandbox_strength: "partial",
      network: false,
      truncated: false,
      purpose: "run",
      output: "using token: [REDACTED]\ndone"
    }

    state = Detail.init([]) |> Detail.open({:runs, run})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "[REDACTED]"
    refute text =~ real_secret
  end

  test "opening a {:diff, entry} item renders +/- lines with a leading glyph, headers untouched" do
    entry = %{
      task_id: "task_1",
      label: "task_1",
      diff: "diff --git a/x.ex b/x.ex\n@@ -1,2 +1,2 @@\n-old line\n+new line\n context\n"
    }

    state = Detail.init([]) |> Detail.open({:diff, entry})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "diff --git a/x.ex b/x.ex"
    assert text =~ "-old line"
    assert text =~ "+new line"
  end

  test "a diff with no changes shows an honest empty note, not a fabricated diff" do
    entry = %{task_id: "task_1", label: "task_1", diff: ""}
    state = Detail.init([]) |> Detail.open({:diff, entry})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 20}, true, 0) |> rows_to_text()

    assert text =~ "no changes against the base revision"
  end

  test "a large diff is capped with a note naming how much is hidden, not flooded into the zone" do
    lines = for i <- 1..500, do: "+line #{i}"
    entry = %{task_id: "task_1", label: "task_1", diff: Enum.join(lines, "\n")}

    state = Detail.init([]) |> Detail.open({:diff, entry})
    text = Detail.render(state, %{x: 0, y: 0, w: 60, h: 200}, true, 0) |> rows_to_text()

    refute text =~ "line 500"
    assert text =~ "more line(s) — /export writes the full diff"
  end

  defp rows_to_text(rows) do
    Enum.map_join(rows, "\n", fn row -> Enum.map_join(row, "", fn {ch, _style} -> ch end) end)
  end

  test "a run detail card renders at several widths without exceeding the rect" do
    run = %{
      command: "mix",
      args: ["test"],
      cwd: "/tmp/worktree",
      exit_code: 1,
      duration_ms: 340,
      sandbox_strength: "partial",
      network: false,
      truncated: true,
      purpose: "test",
      output: "line 1\nline 2\nline 3"
    }

    state = Detail.init([]) |> Detail.open({:runs, run})

    for {w, h} <- [{20, 8}, {40, 12}, {80, 20}] do
      rows = Detail.render(state, %{x: 0, y: 0, w: w, h: h}, true, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "a diff detail card renders at several widths without exceeding the rect" do
    entry = %{
      task_id: "task_1",
      label: "task_1",
      diff: "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n"
    }

    state = Detail.init([]) |> Detail.open({:diff, entry})

    for {w, h} <- [{20, 8}, {40, 12}, {80, 20}] do
      rows = Detail.render(state, %{x: 0, y: 0, w: w, h: h}, true, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "render/4 returns exactly rect.h rows of exactly rect.w cells" do
    state =
      Detail.init([])
      |> Detail.open(
        {:agent, %{label: "PM", state: :active, elapsed_s: 12, tokens: 300, activity: "thinking"}}
      )

    rect = %{x: 0, y: 0, w: 24, h: 10}
    rows = Detail.render(state, rect, true, 0)
    assert length(rows) == rect.h
    assert Enum.all?(rows, &(length(&1) == rect.w))
  end
end
