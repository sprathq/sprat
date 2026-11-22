defmodule Sprat.Terminal.ViewTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.{Composer, View, Width}

  describe "activity_line/3" do
    test "includes verb, elapsed time and token count" do
      [line] =
        View.activity_line(
          %{spinner_index: 0, verb: "Researching", elapsed_s: 5, tokens: 120},
          80
        )

      assert line =~ "Researching"
      assert line =~ "5s"
      assert line =~ "120 tokens"
    end

    test "never exceeds width - 1" do
      lines =
        View.activity_line(%{spinner_index: 0, verb: "Working", elapsed_s: 1, tokens: 0}, 20)

      assert Enum.all?(lines, &(Width.width(&1) <= 19))
    end
  end

  describe "checklist_lines/3" do
    test "renders one line per stage with the right marker" do
      lines =
        View.checklist_lines(
          %{stages: [{"Intake", :done}, {"Research", :active}, {"Analysis", :pending}]},
          80
        )

      assert Enum.at(lines, 0) =~ "☒ Intake"
      assert Enum.at(lines, 1) =~ "◼ Research"
      assert Enum.at(lines, 2) =~ "☐ Analysis"
    end

    test "ascii mode uses bracketed markers" do
      lines =
        View.checklist_lines(%{stages: [{"Intake", :done}]}, 80, ascii: true)

      assert Enum.at(lines, 0) =~ "[x] Intake"
    end

    test "collapses to one summary line when collapsed?" do
      lines =
        View.checklist_lines(
          %{stages: [{"Intake", :done}, {"Research", :active}], collapsed?: true},
          80
        )

      assert length(lines) == 1
      assert Enum.at(lines, 0) =~ "1/2"
    end
  end

  describe "prompt_lines/3" do
    test "renders title, body lines and numbered options with the selected marker" do
      prompt = %{title: "Fetch URL", lines: ["do it?"], options: ["Yes", "No"], selected: 0}
      lines = View.prompt_lines(prompt, 60)
      assert Enum.any?(lines, &(&1 =~ "Fetch URL"))
      assert Enum.any?(lines, &(&1 =~ "do it?"))
      assert Enum.any?(lines, &(&1 =~ "1. Yes"))
      assert Enum.any?(lines, &(&1 =~ "❯"))
    end

    test "every line has the same display width (well-formed box)" do
      prompt = %{title: "T", lines: ["a"], options: ["x", "y"], selected: 0}
      lines = View.prompt_lines(prompt, 40)
      widths = Enum.map(lines, &Width.width/1)
      assert Enum.uniq(widths) |> length() == 1
    end
  end

  describe "composer_lines/3" do
    test "renders the current composer text inside the box" do
      composer = Composer.new()
      {:ok, composer} = Composer.handle_event(composer, {:char, "h"})
      {:ok, composer} = Composer.handle_event(composer, {:char, "i"})
      lines = View.composer_lines(composer, 40)
      assert Enum.any?(lines, &(&1 =~ "> hi"))
    end

    test "shows a bare prompt when empty" do
      lines = View.composer_lines(Composer.new(), 40)
      assert Enum.any?(lines, &(&1 =~ "> "))
    end
  end

  describe "footer_lines/3" do
    test "shows mode, cost and source count" do
      [line] = View.footer_lines(%{mode: "normal", cost: "$0.42", sources: 3}, 80)
      assert line =~ "normal mode"
      assert line =~ "$0.42"
      assert line =~ "3 sources"
    end
  end
end
