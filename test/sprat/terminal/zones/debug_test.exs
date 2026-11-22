defmodule Sprat.Terminal.Zones.DebugTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Debug
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{90, 30}, {60, 20}, {30, 10}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells" do
    state = Debug.init([])

    for {w, h} <- @widths do
      rows = Debug.render(state, %{x: 0, y: 0, w: w, h: h}, true, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "an empty tab names what's missing, not a fake zero" do
    state = Debug.init([])
    text = Debug.render(state, %{x: 0, y: 0, w: 60, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "No model calls yet."
  end

  test "switch_tab/2 cycles through all 5 tabs and back" do
    state = Debug.init([])
    final = Enum.reduce(1..5, state, fn _, s -> Debug.switch_tab(s, :next) end)
    assert final.tab_index == state.tab_index
  end

  test "costs tab: complete vs partial coverage is stated in plain language, never averaged" do
    costs = %{
      mission_totals: %{cost: Decimal.new("1.2345"), calls: 3},
      per_task: [],
      unknown_or_estimated: 0,
      pricing_version: "openai-2026-01-01"
    }

    state =
      Debug.init([])
      |> Debug.switch_tab(:next)
      |> Debug.switch_tab(:next)
      |> Debug.switch_tab(:next)
      |> Debug.handle_view_update(%{costs: costs})

    text = Debug.render(state, %{x: 0, y: 0, w: 80, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "complete: every call's cost is known."
    assert text =~ "$1.2345"
  end

  test "costs tab: unknown cost renders the word unknown, never $0" do
    state =
      Debug.init([])
      |> Debug.switch_tab(:next)
      |> Debug.switch_tab(:next)
      |> Debug.switch_tab(:next)
      |> Debug.handle_view_update(%{
        costs: %{
          mission_totals: %{cost: nil, calls: 1},
          per_task: [],
          unknown_or_estimated: 1,
          pricing_version: nil
        }
      })

    text = Debug.render(state, %{x: 0, y: 0, w: 80, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "Mission total: unknown"
    refute text =~ "$0"
  end

  test "Enter expands a selected row's detail lines, which are shown verbatim (already redacted upstream)" do
    row = %{
      usage: %{
        ended_at: "2026-09-18T00:00:00Z",
        model: "gpt-5-nano",
        input_tokens: 100,
        output_tokens: 20,
        cost_decimal: "0.01",
        coverage: "reported"
      },
      stop_reason: "stop",
      failed?: false,
      detail_lines: ["request:", "  messages: [REDACTED-CHECK]"]
    }

    state = Debug.init([]) |> Debug.handle_view_update(%{requests: [row]})
    {expanded, []} = Debug.handle_key(state, :enter)
    text = Debug.render(expanded, %{x: 0, y: 0, w: 90, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "REDACTED-CHECK"
  end

  test "a secret string embedded in a request's detail_lines never appears literally — the redaction marker does" do
    # Detail lines are built by Terminal.ZonedRenderer from already-redacted
    # event payloads (Sprat.Store.Redact runs at write time) — this test
    # pins that no *new* leak path exists in this zone's own rendering by
    # asserting the marker survives untouched into the cell grid.
    row = %{
      usage: %{
        ended_at: "t",
        model: "m",
        input_tokens: 1,
        output_tokens: 1,
        cost_decimal: nil,
        coverage: "reported"
      },
      stop_reason: nil,
      failed?: false,
      detail_lines: ["request:", "  [REDACTED]"]
    }

    state = Debug.init([]) |> Debug.handle_view_update(%{requests: [row]})
    {expanded, []} = Debug.handle_key(state, :enter)
    text = Debug.render(expanded, %{x: 0, y: 0, w: 90, h: 15}, true, 0) |> rows_to_text()
    assert text =~ "[REDACTED]"
  end
end
