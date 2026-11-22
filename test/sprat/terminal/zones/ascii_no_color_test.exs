defmodule Sprat.Terminal.Zones.AsciiNoColorTest do
  use ExUnit.Case, async: false

  alias Sprat.Terminal.ZoneFrame
  alias Sprat.Terminal.Zones.{Agents, Composer, Inspector}
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  # NO_COLOR/SPRAT_ASCII are read from the environment inside Terminal.Theme
  # by way of Terminal.Glyphs — not async-safe to flip alongside other tests.
  test "agent cards stay legible under SPRAT_ASCII=1 (no Unicode glyphs leak through)" do
    System.put_env("SPRAT_ASCII", "1")

    agents = [
      %{id: "pm", role: :pm, label: "PM", state: :done, elapsed_s: 5, tokens: 10, activity: nil}
    ]

    state = Agents.init([]) |> Agents.handle_view_update(%{agents: agents, messages: []})
    text = Agents.render(state, %{x: 0, y: 0, w: 40, h: 4}, false, 0) |> rows_to_text()

    assert text =~ "[x]"
    refute text =~ "✓"
  after
    System.delete_env("SPRAT_ASCII")
  end

  # Bug: every zone frame (`Terminal.ZoneFrame`), the Composer zone's own
  # border, and the Inspector's tab bar drew hardcoded Unicode box glyphs
  # regardless of `SPRAT_ASCII` — mojibake on a terminal without Unicode. A
  # real tmux capture with `SPRAT_ASCII=1` still showed `╭─╮│╰╯`, `‹ ›`,
  # and `…`. Every glyph now routes through `Terminal.Glyphs`.
  test "zone frame borders, the Inspector tab bar, and truncation are pure ASCII under SPRAT_ASCII=1" do
    System.put_env("SPRAT_ASCII", "1")

    frame_text =
      ZoneFrame.wrap(
        "Zone",
        true,
        %{x: 0, y: 0, w: 15, h: 3},
        ["this line is far too long to fit"]
      )
      |> rows_to_text()

    refute frame_text =~ ~r/[╭╮╰╯│─…▸]/
    assert frame_text =~ "+"
    assert frame_text =~ "-"
    assert frame_text =~ "|"
    assert frame_text =~ "..."

    composer_text =
      Composer.init([]) |> Composer.render(%{x: 0, y: 0, w: 20, h: 3}, true, 0) |> rows_to_text()

    refute composer_text =~ ~r/[╭╮╰╯│]/

    inspector_text =
      Inspector.init([])
      |> Inspector.render(%{x: 0, y: 0, w: 30, h: 6}, false, 0)
      |> rows_to_text()

    refute inspector_text =~ ~r/[‹›]/
    assert inspector_text =~ "<"
    assert inspector_text =~ ">"
  after
    System.delete_env("SPRAT_ASCII")
  end

  # Bug: the focused zone was signalled only by bold+cyan — under
  # `NO_COLOR=1` (zero escape bytes) there was nothing left to tell it
  # apart from every other zone, violating the design's "colour never
  # carries meaning alone" rule. `ZoneFrame.wrap/4` now also puts a `▸`
  # (`>` under `SPRAT_ASCII`) in the focused zone's own title text, a
  # structural marker that survives colour being off entirely.
  # docs/spec-v2.md §11: "A failed run must be unmistakable, not colour
  # alone" — the Runs tab's status glyph swaps to ASCII the same as every
  # other glyph this zone draws, and a failed run stays distinguishable
  # from a passed one by glyph + word text alone regardless of NO_COLOR
  # (this zone never embeds ANSI in its own body lines, so NO_COLOR has
  # nothing to strip — the pinned assertion is that word+glyph survive on
  # their own either way).
  test "the Runs tab's pass/fail glyphs swap to ASCII under SPRAT_ASCII=1" do
    System.put_env("SPRAT_ASCII", "1")

    runs = [
      run_fixture(exit_code: 0),
      run_fixture(exit_code: 1),
      run_fixture(exit_code: nil)
    ]

    state =
      Inspector.init([])
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.handle_view_update(%{runs: runs})

    text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

    assert text =~ "[x] passed"
    assert text =~ "(!) failed"
    assert text =~ "(t) timed out"
    refute text =~ "✓"
    refute text =~ "⏲"
  after
    System.delete_env("SPRAT_ASCII")
  end

  test "a failed run is distinguishable from a passing one with NO_COLOR=1 (glyph + word, not colour)" do
    System.put_env("NO_COLOR", "1")

    runs = [run_fixture(exit_code: 0), run_fixture(exit_code: 1)]

    state =
      Inspector.init([])
      |> Inspector.switch_tab(:next)
      |> Inspector.switch_tab(:next)
      |> Inspector.handle_view_update(%{runs: runs})

    text = Inspector.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()

    assert text =~ "✓ passed"
    assert text =~ "! failed"
  after
    System.delete_env("NO_COLOR")
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

  test "the focused zone carries a structural marker independent of color (NO_COLOR)" do
    focused =
      ZoneFrame.wrap("Conversation", true, %{x: 0, y: 0, w: 30, h: 4}, []) |> rows_to_text()

    unfocused =
      ZoneFrame.wrap("Conversation", false, %{x: 0, y: 0, w: 30, h: 4}, []) |> rows_to_text()

    assert focused =~ "▸ Conversation"
    refute unfocused =~ "▸"
  end
end
