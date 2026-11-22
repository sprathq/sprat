defmodule Sprat.Agent.Tools.WebSearch.OpenAITest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.WebSearch.OpenAI, as: Backend

  defp respond_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, JSON.encode!(body))
  end

  defp responses_output(sources_urls, results) do
    [
      %{
        "type" => "web_search_call",
        "status" => "completed",
        "action" => %{
          "type" => "search",
          "queries" => ["elixir latest release"],
          "sources" => Enum.map(sources_urls, &%{"type" => "url", "url" => &1})
        }
      },
      %{
        "type" => "message",
        "content" => [
          %{"type" => "output_text", "text" => JSON.encode!(%{"results" => results})}
        ]
      }
    ]
  end

  test "search/2 parses results and keeps only URLs present in web_search_call.action.sources" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      output =
        responses_output(
          ["https://elixir-lang.org/blog/x", "https://github.com/elixir-lang/elixir"],
          [
            %{
              "url" => "https://elixir-lang.org/blog/x",
              "title" => "Elixir v1.20 released",
              "snippet" => "A summary the model wrote.",
              "published" => "2026-06-03"
            },
            %{
              "url" => "https://a-url-the-model-made-up.example/nope",
              "title" => "Fabricated",
              "snippet" => "Not real.",
              "published" => nil
            }
          ]
        )

      respond_json(conn, 200, %{
        "output" => output,
        "usage" => %{"input_tokens" => 8413, "output_tokens" => 104}
      })
    end)

    assert {:ok, result} =
             Backend.search("elixir latest release",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             )

    assert [%{url: "https://elixir-lang.org/blog/x"} = kept] = result.results
    assert kept.snippet_origin == "model_summary"
    # published is never trusted from the model, even when it supplied one
    assert kept.published == nil

    assert result.dropped == ["https://a-url-the-model-made-up.example/nope"]
    assert result.queries == ["elixir latest release"]
    assert result.search_calls == 1
    assert result.usage == %{"input_tokens" => 8413, "output_tokens" => 104}
  end

  test "search/2 strips utm_source=openai before the provenance check and before returning the URL" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      output =
        responses_output(
          ["https://example.com/page"],
          [
            %{
              "url" => "https://example.com/page?utm_source=openai",
              "title" => "Example",
              "snippet" => "...",
              "published" => nil
            }
          ]
        )

      respond_json(conn, 200, %{"output" => output, "usage" => nil})
    end)

    assert {:ok, %{results: [%{url: "https://example.com/page"}], dropped: []}} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             )
  end

  test "search/2 respects max_results by capping how many candidate rows are even considered" do
    bypass = Bypass.open()
    urls = for n <- 1..5, do: "https://example.com/#{n}"

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      results =
        Enum.map(urls, &%{"url" => &1, "title" => "t", "snippet" => "s", "published" => nil})

      respond_json(conn, 200, %{"output" => responses_output(urls, results), "usage" => nil})
    end)

    assert {:ok, result} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}",
               max_results: 2
             )

    assert length(result.results) == 2
  end

  test "search/2 returns :rate_limited on HTTP 429, distinct from other failures" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      respond_json(conn, 429, %{"error" => %{"message" => "rate limit exceeded"}})
    end)

    assert {:error, :rate_limited, message} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             )

    assert message =~ "rate limit"
  end

  test "search/2 returns :search_unavailable on a server error" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      respond_json(conn, 500, %{"error" => %{"message" => "internal error"}})
    end)

    assert {:error, :search_unavailable, message} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             )

    assert message =~ "500"
  end

  test "search/2 returns :network_error on a transport failure, never claiming there are no results" do
    assert {:error, :network_error, message} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:1"
             )

    refute message =~ "no results"
  end

  @tag :live
  test "live check: a real search against gpt-5.6-luna returns provenance-checked results (report cost)" do
    {:ok, key, _source} = Sprat.Secrets.resolve()

    assert {:ok, result} =
             Backend.search("current stable Elixir language version 2026",
               model: "gpt-5.6-luna",
               api_key: key,
               max_results: 3
             )

    assert result.results != []
    assert Enum.all?(result.results, &(&1.url in result.source_urls))
    assert Enum.all?(result.results, &(&1.snippet_origin == "model_summary"))
    assert Enum.all?(result.results, &(&1.published == nil))
    assert result.search_calls == 1

    catalog = Sprat.Model.Pricing.load()
    entry = Sprat.Model.Pricing.find(catalog, "gpt-5.6-luna")
    fee = Sprat.Model.Pricing.tool_fee(catalog, "web_search")
    cached = get_in(result.usage, ["input_tokens_details", "cached_tokens"]) || 0
    input = result.usage["input_tokens"] - cached

    cost =
      Sprat.Model.Pricing.cost(entry, %{
        input_tokens: input,
        output_tokens: result.usage["output_tokens"],
        cache_read_tokens: cached
      })
      |> Decimal.add(fee)

    IO.puts(
      "web_search live check: gpt-5.6-luna  #{length(result.results)} results, " <>
        "#{length(result.source_urls)} sources, usage=#{inspect(result.usage)}, cost=$#{cost}"
    )
  end

  test "search/2 tolerates a response with no message item (e.g. only a search call so far)" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
      output = [
        %{
          "type" => "web_search_call",
          "status" => "completed",
          "action" => %{"type" => "search", "queries" => ["q"], "sources" => []}
        }
      ]

      respond_json(conn, 200, %{"output" => output, "usage" => nil})
    end)

    assert {:ok, %{results: [], dropped: []}} =
             Backend.search("q",
               model: "gpt-5.6-luna",
               api_key: "test-key",
               base_url: "http://localhost:#{bypass.port}"
             )
  end
end
