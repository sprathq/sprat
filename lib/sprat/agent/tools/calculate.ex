defmodule Sprat.Agent.Tools.Calculate do
  @moduledoc """
  `calculate` tool (docs/spec-v1.md §9, Analyst): evaluates a basic
  arithmetic expression. A hand-rolled recursive-descent parser, not
  `Code.eval_string/1` — the expression is model-composed, untrusted input
  (§2 "untrusted input stays data"), so it must never reach the BEAM's own
  code evaluator.

  Grammar: `+ - * / ( )`, integers and decimals, unary minus. No
  variables, no functions — `ponytail: that's the whole scope Analyst
  needs (§9); add functions/variables only if a real task calls for them.`
  """

  @behaviour Sprat.Agent.Tool

  @impl true
  def name, do: "calculate"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "calculate",
        "description" => "Evaluate a basic arithmetic expression (+ - * / and parentheses).",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"expression" => %{"type" => "string"}},
          "required" => ["expression"]
        }
      }
    }
  end

  @impl true
  def call(%{"expression" => expr}, _context) when is_binary(expr) do
    case eval(expr) do
      {:ok, result} -> {:ok, %{"result" => result}}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"expression\": \"...\"}"}

  @doc "Evaluates `expr`, returning `{:ok, number}` or `{:error, reason}`. Never raises."
  def eval(expr) do
    with {:ok, tokens} <- tokenize(expr),
         {value, []} <- parse_expr(tokens) do
      {:ok, value}
    else
      {:error, reason} -> {:error, reason}
      {_value, _leftover} -> {:error, "unexpected trailing input"}
    end
  rescue
    _ -> {:error, "could not evaluate expression"}
  end

  # -- tokenizer ------------------------------------------------------------

  defp tokenize(expr) do
    tokens =
      Regex.scan(~r/\s*([0-9]+\.[0-9]+|[0-9]+|[()+\-*\/])\s*/, expr)
      |> Enum.map(fn [_, tok] -> tok end)

    consumed = tokens |> Enum.join() |> String.length()

    if String.length(String.replace(expr, ~r/\s/, "")) != consumed do
      {:error, "expression contains characters outside + - * / ( ) and numbers"}
    else
      {:ok, tokens}
    end
  end

  # -- recursive-descent parser: expr = term (('+'|'-') term)* ----------------

  defp parse_expr(tokens) do
    {left, rest} = parse_term(tokens)
    parse_expr_rest(left, rest)
  end

  defp parse_expr_rest(left, ["+" | rest]) do
    {right, rest2} = parse_term(rest)
    parse_expr_rest(left + right, rest2)
  end

  defp parse_expr_rest(left, ["-" | rest]) do
    {right, rest2} = parse_term(rest)
    parse_expr_rest(left - right, rest2)
  end

  defp parse_expr_rest(left, rest), do: {left, rest}

  # term = factor (('*'|'/') factor)*

  defp parse_term(tokens) do
    {left, rest} = parse_factor(tokens)
    parse_term_rest(left, rest)
  end

  defp parse_term_rest(left, ["*" | rest]) do
    {right, rest2} = parse_factor(rest)
    parse_term_rest(left * right, rest2)
  end

  defp parse_term_rest(left, ["/" | rest]) do
    {right, rest2} = parse_factor(rest)
    if right == 0, do: raise("division by zero")
    parse_term_rest(left / right, rest2)
  end

  defp parse_term_rest(left, rest), do: {left, rest}

  # factor = number | '(' expr ')' | '-' factor

  defp parse_factor(["-" | rest]) do
    {value, rest2} = parse_factor(rest)
    {-value, rest2}
  end

  defp parse_factor(["(" | rest]) do
    {value, rest2} = parse_expr(rest)

    case rest2 do
      [")" | rest3] -> {value, rest3}
      _ -> raise("missing closing parenthesis")
    end
  end

  defp parse_factor([num | rest]) when is_binary(num) do
    case Integer.parse(num) do
      {int, ""} -> {int, rest}
      _ -> {String.to_float(num), rest}
    end
  end

  defp parse_factor([]), do: raise("unexpected end of expression")
end
