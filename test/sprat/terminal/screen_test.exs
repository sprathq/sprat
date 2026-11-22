defmodule Sprat.Terminal.ScreenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Terminal.Screen

  describe "text_cells/3" do
    test "pads short text with blanks to exactly width cells" do
      cells = Screen.text_cells("hi", 5)
      assert length(cells) == 5
      assert Enum.take(cells, 2) == [{"h", Screen.default_style()}, {"i", Screen.default_style()}]
      assert Enum.drop(cells, 2) == List.duplicate({" ", Screen.default_style()}, 3)
    end

    test "truncates text wider than the available width" do
      cells = Screen.text_cells("hello world", 5)
      assert length(cells) == 5
      assert Enum.map(cells, &elem(&1, 0)) == ~w(h e l l o)
    end

    test "a wide grapheme occupies two cells: itself then :cont" do
      cells = Screen.text_cells("中", 3)
      assert [{"中", _style}, :cont, {" ", _}] = cells
    end

    test "a wide grapheme that would land exactly on the last column is dropped, not split" do
      # width 1: "中" (width 2) cannot fit at all — must not emit a lone :cont
      cells = Screen.text_cells("中x", 1)
      assert cells == [{" ", Screen.default_style()}]
      refute :cont in cells
    end

    test "ANSI SGR escape codes are stripped, not laid out as one-column cells each" do
      # Root cause of the "streamed Markdown corruption" defect (found via
      # a real tmux repro of a heading rendered by `Sprat.Terminal.Markdown`,
      # which bakes ANSI styling into the string for the old inline
      # renderer): every byte of "\e[1m\e[36m" used to count as a real
      # column, pushing the actual text N columns right of where the
      # tracked frame — and every write after it on the row — thought it
      # was.
      styled = "\e[1m\e[36m## hi\e[0m"
      cells = Screen.text_cells(styled, 5)
      assert length(cells) == 5
      assert Enum.map(cells, &elem(&1, 0)) == ["#", "#", " ", "h", "i"]
    end

    test "a short ANSI-styled line is padded to width from its real (stripped) length" do
      styled = "\e[1mhi\e[0m"
      cells = Screen.text_cells(styled, 4)
      assert Enum.map(cells, &elem(&1, 0)) == ["h", "i", " ", " "]
    end
  end

  describe "put_rows/3 and diff/4" do
    test "placing rows and diffing against blank reports exactly the written cells" do
      blank = Screen.blank(10, 3)
      rows = [Screen.text_cells("ab", 3), Screen.text_cells("cd", 3)]
      frame = Screen.put_rows(blank, %{x: 1, y: 1, w: 3, h: 2}, rows)

      diff = Screen.diff(blank, frame, 10, 3)

      changed_coords =
        for {row, col, cells} <- diff, {_c, i} <- Enum.with_index(cells), do: {row, col + i}

      assert {1, 1} in changed_coords
      assert {2, 1} in changed_coords
      refute {0, 0} in changed_coords
    end

    test "never includes the very last cell of the very last row" do
      blank = Screen.blank(5, 2)
      full_row = Screen.text_cells("xxxxx", 5)
      frame = Screen.put_rows(blank, %{x: 0, y: 1, w: 5, h: 1}, [full_row])

      diff = Screen.diff(blank, frame, 5, 2)

      touched =
        for {row, col, cells} <- diff, {_c, i} <- Enum.with_index(cells), do: {row, col + i}

      refute {1, 4} in touched
    end

    test "identical frames produce no diff" do
      frame = Screen.blank(20, 5)
      assert Screen.diff(frame, frame, 20, 5) == []
    end
  end

  describe "diff/4 property: applying runs reproduces the target frame exactly" do
    property "a virtual repaint from diff runs matches the target frame everywhere but the reserved last cell" do
      check all(
              cols <- integer(5..15),
              rows <- integer(3..8),
              seed1 <- integer(0..1000),
              seed2 <- integer(0..1000)
            ) do
        old = random_frame(cols, rows, seed1)
        new = random_frame(cols, rows, seed2)

        runs = Screen.diff(old, new, cols, rows)
        repainted = apply_runs(old, runs)

        for row <- 0..(rows - 1), col <- 0..(cols - 1), {row, col} != {rows - 1, cols - 1} do
          assert Enum.at(Map.fetch!(repainted, row), col) == Enum.at(Map.fetch!(new, row), col),
                 "mismatch at #{row},#{col}"
        end
      end
    end
  end

  defp random_frame(cols, rows, seed) do
    :rand.seed(:exsplus, {seed, seed, seed})

    for r <- 0..(rows - 1), into: %{} do
      row =
        for _c <- 0..(cols - 1) do
          ch = Enum.random(["a", "b", " ", "x"])
          {ch, Screen.default_style()}
        end

      {r, row}
    end
  end

  # A minimal interpreter of `Screen.diff/4`'s runs, ignoring style/ANSI —
  # exactly enough to check the diff's *positions and characters* are
  # correct, without needing to parse `to_ansi/2`'s escape codes back out.
  defp apply_runs(frame, runs) do
    Enum.reduce(runs, frame, fn {row, start_col, cells}, frame ->
      Map.update!(frame, row, fn existing ->
        cells
        |> Enum.with_index(start_col)
        |> Enum.reduce(existing, fn
          {:cont, _col}, row_acc -> row_acc
          {cell, col}, row_acc -> List.replace_at(row_acc, col, cell)
        end)
      end)
    end)
  end
end
