defmodule Sprat.Terminal.Board.MirrorTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Board.Mirror

  defp fake(test, reply) do
    fn bin, args, _opts ->
      send(test, {:cmd, bin, args})
      reply
    end
  end

  test "reads the surface's last lines" do
    assert {:ok, "screen"} =
             Mirror.read("surface:12", 30, cmux_bin: "cmux", cmd: fake(self(), {"screen", 0}))

    assert_received {:cmd, "cmux", ["read-screen", "--surface", "surface:12", "--lines", "30"]}

    assert {:error, "cmux read-screen 1: nope"} =
             Mirror.read("surface:12", 30, cmux_bin: "cmux", cmd: fake(self(), {"nope", 1}))

    assert {:error, "cmux is not installed"} = Mirror.read("surface:12", 30, cmux_bin: nil)
  end

  test "a digit is typed, a named key is pressed" do
    assert :ok = Mirror.key("surface:12", "2", cmux_bin: "cmux", cmd: fake(self(), {"", 0}))
    assert_received {:cmd, "cmux", ["send", "--surface", "surface:12", "2"]}
    assert :ok = Mirror.key("surface:12", "enter", cmux_bin: "cmux", cmd: fake(self(), {"", 0}))
    assert_received {:cmd, "cmux", ["send-key", "--surface", "surface:12", "enter"]}
  end
end
