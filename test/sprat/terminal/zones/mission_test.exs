defmodule Sprat.Terminal.Zones.MissionTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Mission
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{22, 10}, {18, 6}, {40, 3}, {12, 3}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells, at every breakpoint size" do
    state =
      Mission.init([])
      |> Mission.handle_view_update(%{
        activity: %{verb: "Researching", elapsed_s: 12},
        checklist: %{stages: [{"Intake", :done}, {"Research", :active}, {"Analysis", :pending}]},
        budget: %{spent: Decimal.new("1.42"), cap: Decimal.new("5.00")}
      })

    for {w, h} <- @widths do
      rect = %{x: 0, y: 0, w: w, h: h}
      rows = Mission.render(state, rect, false, 0)
      assert length(rows) == h, "expected #{h} rows at #{w}x#{h}, got #{length(rows)}"
      assert Enum.all?(rows, &(length(&1) == w)), "row width mismatch at #{w}x#{h}"
    end
  end

  test "below min_size renders the compact header strip instead of overlaying away" do
    state =
      Mission.init([])
      |> Mission.handle_view_update(%{
        checklist: %{stages: [{"Intake", :done}, {"Research", :active}]}
      })

    rect = %{x: 0, y: 0, w: 40, h: 3}
    rows = Mission.render(state, rect, false, 0)
    assert rows_to_text(rows) =~ "Research"
  end

  test "a :failed stage renders the failed glyph, not the spinner or the queued circle" do
    state =
      Mission.init([])
      |> Mission.handle_view_update(%{
        checklist: %{stages: [{"Intake", :done}, {"Research", :failed}, {"Analysis", :queued}]}
      })

    rect = %{x: 0, y: 0, w: 22, h: 10}
    text = Mission.render(state, rect, false, 0) |> rows_to_text()

    failed_glyph = Sprat.Terminal.Theme.state(:failed).glyph
    [failed_line] = text |> String.split("\n") |> Enum.filter(&(&1 =~ "Research"))
    assert failed_line =~ "#{failed_glyph} Research"
  end

  test "a :skipped stage renders its own glyph, distinct from :done — never the ✓ done glyph" do
    state =
      Mission.init([])
      |> Mission.handle_view_update(%{
        checklist: %{stages: [{"Intake", :skipped}, {"Research", :active}, {"Analysis", :queued}]}
      })

    rect = %{x: 0, y: 0, w: 22, h: 10}
    text = Mission.render(state, rect, false, 0) |> rows_to_text()

    skipped_glyph = Sprat.Terminal.Theme.state(:skipped).glyph
    done_glyph = Sprat.Terminal.Theme.state(:done).glyph
    [intake_line] = text |> String.split("\n") |> Enum.filter(&(&1 =~ "Intake"))

    assert intake_line =~ "#{skipped_glyph} Intake"
    refute intake_line =~ "#{done_glyph} Intake"
  end

  test "a :waiting_on_user stage renders the waiting glyph, distinct from the running spinner" do
    state =
      Mission.init([])
      |> Mission.handle_view_update(%{
        checklist: %{
          stages: [{"Intake", :done}, {"Research", :waiting_on_user}, {"Analysis", :queued}]
        }
      })

    rect = %{x: 0, y: 0, w: 22, h: 10}
    text = Mission.render(state, rect, false, 0) |> rows_to_text()

    waiting_glyph = Sprat.Terminal.Theme.state(:waiting_on_user).glyph
    [research_line] = text |> String.split("\n") |> Enum.filter(&(&1 =~ "Research"))

    assert research_line =~ "#{waiting_glyph} Research"
    # `:active`'s glyph is the atom `:spinner`, resolved through
    # `Terminal.Animate.spinner_frame/2` — it can never equal a literal
    # string, so this line proves a waiting stage isn't quietly falling
    # back to `:active`/`:queued`'s rendering instead of its own.
    refute Sprat.Terminal.Theme.state(:active).glyph == waiting_glyph
  end

  test "unknown budget renders the honest word 'unknown', never a fake $0.00" do
    state = Mission.init([])
    rect = %{x: 0, y: 0, w: 22, h: 10}
    rows = Mission.render(state, rect, false, 0)
    text = rows_to_text(rows)
    assert text =~ "unknown"
    refute text =~ "$0.00"
  end

  describe "dollars/1 (docs/spec-v1.md §12: a real cost under a cent must not read as $0.00)" do
    test "a real call costing $0.000676 shows as <$0.01, not $0.00" do
      assert Mission.dollars(Decimal.new("0.000676")) == "<$0.01"
    end

    test "exactly zero still shows as $0.00 (that one really is zero)" do
      assert Mission.dollars(Decimal.new("0")) == "$0.00"
    end

    test "an ordinary amount rounds to two decimals as before" do
      assert Mission.dollars(Decimal.new("1.4210")) == "$1.42"
    end

    test "budget_word/1 (shared with the footer) reflects the honest small-amount formatting" do
      assert Mission.budget_word(%{spent: Decimal.new("0.0005"), cap: Decimal.new("5.00")}) ==
               "<$0.01/$5.00"
    end

    test "the Mission zone's budget line never shows a real spend as $0.00" do
      state =
        Mission.init([])
        |> Mission.handle_view_update(%{
          budget: %{spent: Decimal.new("0.000676"), cap: Decimal.new("5.00")}
        })

      rect = %{x: 0, y: 0, w: 22, h: 10}
      text = Mission.render(state, rect, false, 0) |> rows_to_text()
      assert text =~ "<$0.01"
      refute text =~ "$0.00"
    end
  end
end
