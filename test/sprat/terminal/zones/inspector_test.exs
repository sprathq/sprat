defmodule Sprat.Terminal.Zones.InspectorTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Inspector
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{22, 10}, {18, 6}, {40, 20}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells" do
    state = Inspector.init([])

    for {w, h} <- @widths do
      rows = Inspector.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "an empty tab names what's missing, never a fake placeholder" do
    state = Inspector.init([])
    text = Inspector.render(state, %{x: 0, y: 0, w: 30, h: 10}, false, 0) |> rows_to_text()
    assert text =~ "No sources recorded yet."
  end

  test "switch_tab/2 cycles through all 8 tabs and back" do
    state = Inspector.init([])
    final = Enum.reduce(1..8, state, fn _, s -> Inspector.switch_tab(s, :next) end)
    assert final.tab_index == state.tab_index
  end

  test "the Usage tab renders unknown fields as the literal word 'unknown', never 0" do
    state =
      Inspector.init([])
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.handle_view_update(%{
        usage: %{
          calls: 3,
          cost: nil,
          input_tokens: 500,
          output_tokens: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil
        }
      })

    text = Inspector.render(state, %{x: 0, y: 0, w: 40, h: 10}, false, 0) |> rows_to_text()
    assert text =~ "cost:    unknown"
    assert text =~ "output:  unknown"
    refute text =~ "cost:    $0"
  end

  test "artifacts tab lists type, version and owning role; empty state names what's missing" do
    state =
      Inspector.init([])
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)

    empty_text = Inspector.render(state, %{x: 0, y: 0, w: 40, h: 10}, false, 0) |> rows_to_text()
    assert empty_text =~ "No artifacts written yet."

    state =
      Inspector.handle_view_update(state, %{
        artifacts: [%{type: "research_memo", latest_version: 2, owning_role: "researcher"}]
      })

    text = Inspector.render(state, %{x: 0, y: 0, w: 40, h: 10}, false, 0) |> rows_to_text()
    assert text =~ "research_memo v2 (researcher)"
  end

  test "Enter on a selected Evidence item emits {:open_detail, {:evidence, source}}" do
    source = %{title: "clubright.co.uk", url: "https://clubright.co.uk"}
    state = Inspector.init([]) |> Inspector.handle_view_update(%{sources: [source]})
    {_state, intents} = Inspector.handle_key(state, :enter)
    assert intents == [{:open_detail, {:evidence, source}}]
  end

  describe "Runs tab" do
    defp to_runs_tab(state),
      do: state |> Inspector.switch_tab(:next) |> Inspector.switch_tab(:next)

    test "empty state names what's missing" do
      state = Inspector.init([]) |> to_runs_tab()
      text = Inspector.render(state, %{x: 0, y: 0, w: 40, h: 10}, false, 0) |> rows_to_text()
      assert text =~ "No runs recorded for this mission yet."
    end

    test "lists purpose, command, exit status, duration and flags" do
      passed = run_fixture(exit_code: 0, purpose: "install", command: "npm", args: ["ci"])

      failed =
        run_fixture(
          exit_code: 1,
          purpose: "test",
          command: "mix",
          args: ["test"],
          truncated: true,
          network: true
        )

      state =
        Inspector.init([])
        |> to_runs_tab()
        |> Inspector.handle_view_update(%{runs: [passed, failed]})

      text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

      assert text =~ "install"
      assert text =~ "npm ci"
      assert text =~ "test"
      assert text =~ "mix test"
      assert text =~ "truncated, network"
    end

    test "a failed run is distinguishable from a passing one by glyph and word alone (NO_COLOR)" do
      System.put_env("NO_COLOR", "1")

      passed = run_fixture(exit_code: 0)
      failed = run_fixture(exit_code: 1)

      state =
        Inspector.init([])
        |> to_runs_tab()
        |> Inspector.handle_view_update(%{runs: [passed, failed]})

      text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

      assert text =~ "✓ passed"
      assert text =~ "! failed"
    after
      System.delete_env("NO_COLOR")
    end

    test "a run with no exit code (timed out) never reads as passing" do
      timed_out = run_fixture(exit_code: nil)

      state =
        Inspector.init([]) |> to_runs_tab() |> Inspector.handle_view_update(%{runs: [timed_out]})

      text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

      assert text =~ "timed out"
      refute text =~ "passed"
    end

    test "renders at several widths without exceeding the rect" do
      runs = [run_fixture(exit_code: 0), run_fixture(exit_code: 1), run_fixture(exit_code: nil)]

      state =
        Inspector.init([])
        |> to_runs_tab()
        |> Inspector.handle_view_update(%{runs: runs})

      for {w, h} <- [{20, 8}, {40, 10}, {80, 15}] do
        rows = Inspector.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
        assert length(rows) == h
        assert Enum.all?(rows, &(length(&1) == w))
      end
    end

    test "Enter emits {:open_detail, {:runs, run}}" do
      run = run_fixture(exit_code: 0)
      state = Inspector.init([]) |> to_runs_tab() |> Inspector.handle_view_update(%{runs: [run]})
      {_state, intents} = Inspector.handle_key(state, :enter)
      assert intents == [{:open_detail, {:runs, run}}]
    end
  end

  describe "Diff tab" do
    defp to_diff_tab(state), do: state |> to_runs_tab() |> Inspector.switch_tab(:next)

    test "empty state names what's missing" do
      state = Inspector.init([]) |> to_diff_tab()
      text = Inspector.render(state, %{x: 0, y: 0, w: 50, h: 10}, false, 0) |> rows_to_text()
      assert text =~ "No diffs recorded for this mission yet."
    end

    test "lists each entry's label with its added/removed line counts" do
      diff_text = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n+another\n"

      entries = [
        %{task_id: "task_1", label: "task_1", diff: diff_text},
        %{task_id: nil, label: "combined", diff: diff_text}
      ]

      state =
        Inspector.init([]) |> to_diff_tab() |> Inspector.handle_view_update(%{diffs: entries})

      text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

      assert text =~ "task_1 — +2 -1"
      assert text =~ "combined — +2 -1"
    end

    test "renders at several widths without exceeding the rect" do
      entries = [
        %{task_id: "task_1", label: "task_1", diff: "+a\n-b\n"},
        %{task_id: nil, label: "combined", diff: "+a\n-b\n"}
      ]

      state =
        Inspector.init([]) |> to_diff_tab() |> Inspector.handle_view_update(%{diffs: entries})

      for {w, h} <- [{20, 8}, {40, 10}, {80, 15}] do
        rows = Inspector.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
        assert length(rows) == h
        assert Enum.all?(rows, &(length(&1) == w))
      end
    end

    test "Enter emits {:open_detail, {:diff, entry}}" do
      entry = %{task_id: "task_1", label: "task_1", diff: "+x\n"}

      state =
        Inspector.init([]) |> to_diff_tab() |> Inspector.handle_view_update(%{diffs: [entry]})

      {_state, intents} = Inspector.handle_key(state, :enter)
      assert intents == [{:open_detail, {:diff, entry}}]
    end
  end

  defp run_fixture(overrides) do
    Map.merge(
      %{
        id: "run_1",
        mission_id: "mission_1",
        task_id: "task_1",
        command: "mix",
        args: ["test"],
        cwd: "/tmp/worktree",
        exit_code: 0,
        duration_ms: 120,
        output_blob_hash: "abc123",
        truncated: false,
        network: false,
        sandbox_strength: "partial",
        purpose: "test",
        created_at: "2026-01-01T00:00:00Z"
      },
      Map.new(overrides)
    )
  end
end
