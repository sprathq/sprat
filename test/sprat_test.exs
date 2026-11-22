defmodule SpratTest do
  use ExUnit.Case
  doctest Sprat

  test "greets the world" do
    assert Sprat.hello() == :world
  end
end
