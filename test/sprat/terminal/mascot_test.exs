defmodule Sprat.Terminal.MascotTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Mascot

  describe "state_of/1" do
    test "a pending prompt wins over activity" do
      assert Mascot.state_of(%{permission: %{title: "Fetch URL"}, animating?: true}) ==
               :waiting_input
    end

    test "running work swims, nothing running is idle" do
      assert Mascot.state_of(%{permission: nil, animating?: true}) == :working
      assert Mascot.state_of(%{permission: nil, animating?: false}) == :idle
    end
  end

  describe "render/4" do
    test "idle is a still fish, identical on every frame" do
      frames = Enum.map(0..20, &Mascot.render(:idle, &1, 10))
      assert Enum.uniq(frames) == ["><>       "]
    end

    test "working swims, turns around, and stays inside the track" do
      width = 8
      frames = Enum.map(0..200, &Mascot.render(:working, &1, width))

      assert Enum.all?(frames, &(String.length(&1) == width))
      assert Enum.all?(frames, &(String.trim(&1) in ["><>", "<><"]))

      # It reaches both ends and faces the way it is going.
      assert Enum.any?(frames, &(&1 == "><>" <> String.duplicate(" ", width - 3)))
      assert Enum.any?(frames, &String.ends_with?(&1, "><>"))
      assert Enum.any?(frames, &(String.trim(&1) == "<><"))

      # And it actually moves: more than one position is visited.
      offsets = frames |> Enum.map(&(String.length(&1) - String.length(String.trim_leading(&1))))
      assert length(Enum.uniq(offsets)) > 1
    end

    test "waiting for input faces the user, stays put, and blinks" do
      frames = Enum.map(0..40, &Mascot.render(:waiting_input, &1, 6))

      assert Enum.all?(frames, &String.starts_with?(&1, "<"))
      assert Enum.any?(frames, &String.starts_with?(&1, "<><"))
      assert Enum.any?(frames, &String.starts_with?(&1, "<•<"))
    end

    test "ascii mode blinks without a unicode bullet" do
      frames = Enum.map(0..40, &Mascot.render(:waiting_input, &1, 6, ascii?: true))

      assert Enum.any?(frames, &String.starts_with?(&1, "<o<"))
      refute Enum.any?(frames, &String.contains?(&1, "•"))
    end

    test "a track too narrow for the fish drops it rather than clipping it" do
      assert Mascot.render(:working, 7, 2) == ""
      assert Mascot.render(:idle, 0, 1) == ""
    end

    test "a track exactly the body width still renders" do
      assert Mascot.render(:working, 3, 3) == "><>"
    end
  end
end
