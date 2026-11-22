defmodule Sprat.Terminal.DiffTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Diff

  describe "counts/1" do
    test "counts +/- lines, ignoring +++/--- file headers" do
      text = """
      diff --git a/x.ex b/x.ex
      --- a/x.ex
      +++ b/x.ex
      @@ -1,3 +1,3 @@
      -old one
      -old two
      +new one
      +new two
      +new three
       context line
      """

      assert Diff.counts(text) == {3, 2}
    end

    test "nil or blank text counts as {0, 0}" do
      assert Diff.counts(nil) == {0, 0}
      assert Diff.counts("") == {0, 0}
    end
  end

  describe "render/2" do
    test "keeps +/- lines' leading character as the glyph, indents context lines" do
      text = "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n context\n"
      lines = Diff.render(text)

      assert Enum.at(lines, 0) == "diff --git a/x b/x"
      assert Enum.at(lines, 1) == "@@ -1 +1 @@"
      assert Enum.at(lines, 2) == "-old"
      assert Enum.at(lines, 3) == "+new"
      assert Enum.at(lines, 4) == "   context"
    end

    test "nil or blank text renders as no lines" do
      assert Diff.render(nil) == []
      assert Diff.render("") == []
    end

    test "a diff longer than max_lines is capped with a note naming how much is hidden" do
      text = 1..50 |> Enum.map(&"+line #{&1}") |> Enum.join("\n")
      lines = Diff.render(text, 10)

      assert length(lines) == 11
      assert List.last(lines) == "… 40 more line(s) — /export writes the full diff"
      refute Enum.any?(lines, &(&1 == "+line 50"))
    end

    test "a diff within max_lines is not capped" do
      text = "+line 1\n+line 2"
      lines = Diff.render(text, 10)

      assert lines == ["+line 1", "+line 2"]
    end
  end
end
