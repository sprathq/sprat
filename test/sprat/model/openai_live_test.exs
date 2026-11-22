defmodule Sprat.Model.OpenAILiveTest do
  @moduledoc """
  Live smoke tests against the real OpenAI API. Skipped by `mix test`
  unless `SPRAT_LIVE=1` is set and a key is configured (`OPENAI_API_KEY`,
  `.env`, or the OS credential store — see `Sprat.Secrets`). Run with:

      SPRAT_LIVE=1 mix test test/sprat/model/openai_live_test.exs --include live

  Uses `gpt-5-nano`, the cheapest tested/streaming/tool-capable model on
  the shipped allowlist. Total spend across this whole file is a handful
  of cents (reported at the end of each test's output).
  """

  use ExUnit.Case

  alias Sprat.Model.OpenAI
  alias Sprat.Model.Pricing

  @moduletag :live
  @model "gpt-5-nano"

  setup_all do
    if System.get_env("SPRAT_LIVE") != "1" do
      {:ok, skip: true}
    else
      case Sprat.Secrets.resolve() do
        {:ok, key, _source} -> {:ok, api_key: key, skip: false}
        :error -> {:ok, skip: true}
      end
    end
  end

  defp opts(ctx), do: [api_key: ctx.api_key, receive_timeout: 30_000]

  test "one cheap call with a tool: streaming, tool round trip, usage reported, cost computed",
       ctx do
    if ctx.skip do
      IO.puts("skipping live test: set SPRAT_LIVE=1 and configure an OpenAI key to run it")
    else
      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_delta = fn delta -> Agent.update(agent, &[delta | &1]) end

      request = %{
        model: @model,
        messages: [
          %{
            "role" => "user",
            "content" => "What is 12 * 7? Use the calculate tool, then state the answer."
          }
        ],
        tools: [
          %{
            "type" => "function",
            "function" => %{
              "name" => "calculate",
              "description" => "Evaluate a basic arithmetic expression",
              "parameters" => %{
                "type" => "object",
                "properties" => %{"expression" => %{"type" => "string"}},
                "required" => ["expression"]
              }
            }
          }
        ],
        max_tokens: 2000
      }

      assert {:ok, response} = OpenAI.stream(request, opts(ctx) ++ [on_delta: on_delta])
      assert response.stop_reason == :tool_calls
      assert [%{name: "calculate", arguments: %{"expression" => expr}}] = response.tool_calls
      assert is_binary(expr)

      assert response.usage["prompt_tokens"] > 0
      assert response.usage["completion_tokens"] > 0

      catalog = Pricing.load()
      attrs = OpenAI.normalize_usage(response.usage, %{model: @model, catalog: catalog})
      assert attrs.coverage == "reported"
      assert %Decimal{} = attrs.cost
      assert Decimal.compare(attrs.cost, Decimal.new(0)) == :gt

      IO.puts(
        "live smoke test call cost (list-price estimate, not a billing figure): $#{Decimal.to_string(attrs.cost)}"
      )

      deltas = Agent.get(agent, & &1)
      assert Enum.any?(deltas, &(&1.type == :tool_call))
    end
  end

  test "cancellation mid-stream against the real API is marked estimated", ctx do
    if ctx.skip do
      IO.puts("skipping live test: set SPRAT_LIVE=1 and configure an OpenAI key to run it")
    else
      {:ok, seen_any} = Agent.start_link(fn -> false end)
      on_delta = fn _delta -> Agent.update(seen_any, fn _ -> true end) end
      cancel? = fn -> Agent.get(seen_any, & &1) end

      request = %{
        model: @model,
        messages: [
          %{
            "role" => "user",
            "content" => "Write a very long, detailed 500-word essay about the history of bread."
          }
        ],
        max_tokens: 2000
      }

      assert {:ok, response} =
               OpenAI.stream(request, opts(ctx) ++ [on_delta: on_delta, cancel?: cancel?])

      assert response.stop_reason == :cancelled

      attrs =
        OpenAI.normalize_usage(response.usage, %{
          model: @model,
          interrupted?: true,
          local_input_tokens: 20,
          streamed_output_estimate: max(div(byte_size(response.content || ""), 4), 1)
        })

      assert attrs.coverage == "estimated"

      IO.puts(
        "live cancellation test estimated cost: $#{Decimal.to_string(attrs.cost || Decimal.new(0))}"
      )
    end
  end
end
