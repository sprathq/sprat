defmodule Sprat.Terminal.Zones.FlowTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Flow
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  # Every size the overlay must degrade gracefully at, per the design's
  # responsive-layout breakpoints, down to a very small terminal.
  @widths [{100, 30}, {80, 24}, {40, 10}, {20, 8}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells at every size" do
    state =
      Flow.init([])
      |> Flow.handle_view_update(%{
        agents: [%{id: "pm", label: "PM"}, %{id: "r1", label: "Researcher·1"}],
        messages: [%{from: "pm", to: "r1", type: :assignment, frame: 0, at: "14:00"}]
      })

    for {w, h} <- @widths do
      rows = Flow.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "no traffic yet renders honestly, not a fake graph" do
    state = Flow.init([])
    text = Flow.render(state, %{x: 0, y: 0, w: 60, h: 15}, false, 0) |> rows_to_text()
    assert text =~ "No traffic yet."
  end

  test "edge volumes are labelled with role names, not raw ids" do
    state =
      Flow.init([])
      |> Flow.handle_view_update(%{
        agents: [%{id: "pm", label: "PM"}, %{id: "r1", label: "Researcher·1"}],
        messages: [
          %{from: "pm", to: "r1", type: :assignment, frame: 0, at: "14:00"},
          %{from: "pm", to: "r1", type: :assignment, frame: 1, at: "14:01"}
        ]
      })

    text = Flow.render(state, %{x: 0, y: 0, w: 60, h: 15}, false, 5) |> rows_to_text()
    assert text =~ "PM -> Researcher·1"
    assert text =~ "x2"
  end
end
