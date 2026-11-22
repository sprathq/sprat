defmodule Sprat.Test.CellText do
  @moduledoc "Test helper: flattens `Terminal.Screen` cell rows back to plain text for content assertions."

  def rows_to_text(rows) do
    Enum.map_join(rows, "\n", fn row ->
      Enum.map_join(row, "", fn
        :cont -> ""
        {grapheme, _style} -> grapheme
      end)
    end)
  end
end
