defmodule Sprat.Agent.Tools.CalculateTest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.Calculate

  test "evaluates basic arithmetic with precedence and parens" do
    assert Calculate.eval("2 + 3 * 4") == {:ok, 14}
    assert Calculate.eval("(2 + 3) * 4") == {:ok, 20}
    assert Calculate.eval("10 / 4") == {:ok, 2.5}
    assert Calculate.eval("-5 + 2") == {:ok, -3}
    assert Calculate.eval("2 * (3 + -1)") == {:ok, 4}
  end

  test "division by zero is an error, not a crash" do
    assert {:error, _} = Calculate.eval("1 / 0")
  end

  test "rejects anything outside the arithmetic grammar" do
    assert {:error, _} = Calculate.eval("System.halt()")
    assert {:error, _} = Calculate.eval("1 + File.read!(\"/etc/passwd\")")
  end

  test "call/2 via the tool interface" do
    assert {:ok, %{"result" => 12}} = Calculate.call(%{"expression" => "3 * 4"}, %{})
    assert {:error, _} = Calculate.call(%{"expression" => "nope"}, %{})
  end
end
