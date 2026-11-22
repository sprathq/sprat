defmodule Sprat.Terminal.AnimateTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Animate

  describe "tick/1" do
    test "advances the frame only while running" do
      state = Animate.new() |> Animate.start()
      state = Animate.tick(state)
      assert state.frame == 1
    end

    test "is a no-op while stopped" do
      state = Animate.new() |> Animate.tick() |> Animate.tick()
      assert state.frame == 0
    end

    test "stop/1 halts further advancement" do
      state =
        Animate.new() |> Animate.start() |> Animate.tick() |> Animate.stop() |> Animate.tick()

      assert state.frame == 1
    end
  end

  describe "enabled? (docs/design/tui-zones.md 'Animation' hard rule)" do
    test "disabled under --plain" do
      refute Animate.enabled?(plain?: true)
    end

    test "disabled under NO_COLOR" do
      refute Animate.enabled?(color: false)
    end

    test "disabled on a non-tty" do
      refute Animate.enabled?(tty?: false)
    end

    test "disabled below 80x24" do
      refute Animate.enabled?(size: {79, 24})
      refute Animate.enabled?(size: {80, 23})
    end

    test "enabled otherwise" do
      assert Animate.enabled?(size: {80, 24}, tty?: true, color: true, plain?: false)
    end
  end

  describe "spinner_frame/2 — pure function of frame, no sleeps needed" do
    test "cycles deterministically" do
      frames = Enum.map(0..9, &Animate.spinner_frame(&1))
      assert length(Enum.uniq(frames)) == 10
      assert Animate.spinner_frame(10) == Animate.spinner_frame(0)
    end

    test "ascii mode swaps the frame set" do
      assert Animate.spinner_frame(0, ascii: true) == "|"
    end
  end

  describe "easing" do
    test "all easing functions map 0 -> 0 and 1 -> 1" do
      for fun <- [&Animate.ease_linear/1, &Animate.ease_out/1, &Animate.ease_in_out/1] do
        assert_in_delta fun.(0.0), 0.0, 1.0e-9
        assert_in_delta fun.(1.0), 1.0, 1.0e-9
      end
    end

    test "progress/3 clamps to 0..1" do
      assert Animate.progress(0, 100, -50) == 0.0
      assert Animate.progress(0, 100, 200) == 1.0
      assert Animate.progress(0, 100, 50) == 0.5
    end
  end
end
