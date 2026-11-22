defmodule Sprat.Agent.Tools.WebSearchTest do
  use Sprat.StoreCase, async: false

  alias Sprat.Agent.Tools.{WebFetch, WebSearch}
  alias Sprat.Model.Pricing
  alias Sprat.Store.{Events, Usage}

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
          "queries" => ["elixir version"],
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

  defp ok_response(
         sources_urls,
         results,
         usage \\ %{"input_tokens" => 1000, "output_tokens" => 50}
       ) do
    %{"output" => responses_output(sources_urls, results), "usage" => usage}
  end

  setup %{store: store} do
    {session, mission, task} = fixture_chain(store)

    {:ok, budget} =
      Sprat.Budget.start_link(name: :"budget_#{System.unique_integer([:positive])}", store: store)

    Sprat.Budget.set_cap(budget, mission.id, Decimal.new("5.00"))

    context = %{
      search_provider: "openai",
      search_model: "gpt-5.6-luna",
      api_key: "test-key",
      budget: budget,
      catalog: Pricing.load(),
      store: store,
      session_id: session.id,
      mission_id: mission.id,
      task_id: task.id,
      secrets: []
    }

    on_exit(fn -> WebSearch.clear_auto_fetch_urls(mission.id) end)

    %{context: context, store: store, session: session, mission: mission, task: task}
  end

  test "name/0 and spec/0" do
    assert WebSearch.name() == "web_search"
    spec = WebSearch.spec()
    assert spec["function"]["name"] == "web_search"
    assert "query" in spec["function"]["parameters"]["required"]
  end

  test "call/2 rejects a missing or empty query" do
    assert {:error, message} = WebSearch.call(%{}, %{})
    assert message =~ "query"
    assert {:error, _} = WebSearch.call(%{"query" => ""}, %{})
  end

  describe "call/2 against a stubbed backend" do
    test "returns candidate results tagged model_summary, never a published date", %{
      context: context
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(
          conn,
          200,
          ok_response(
            ["https://elixir-lang.org/blog/x"],
            [
              %{
                "url" => "https://elixir-lang.org/blog/x",
                "title" => "Elixir v1.20",
                "snippet" => "model paraphrase",
                "published" => "2026-06-03"
              }
            ]
          )
        )
      end)

      context = with_backend(context, bypass)
      assert {:ok, result} = WebSearch.call(%{"query" => "elixir version"}, context)
      assert [row] = result["results"]
      assert row["snippet_origin"] == "model_summary"
      assert row["published"] == nil
      assert result["note"] =~ "never cite"
    end

    test "drops a result URL not present in web_search_call.action.sources, and logs it", %{
      context: context,
      store: store,
      session: session
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(
          conn,
          200,
          ok_response(
            ["https://real.example/a"],
            [
              %{
                "url" => "https://real.example/a",
                "title" => "t",
                "snippet" => "s",
                "published" => nil
              },
              %{
                "url" => "https://hallucinated.example/b",
                "title" => "fake",
                "snippet" => "fake",
                "published" => nil
              }
            ]
          )
        )
      end)

      context = with_backend(context, bypass)
      assert {:ok, result} = WebSearch.call(%{"query" => "q"}, context)
      urls = Enum.map(result["results"], & &1["url"])
      assert urls == ["https://real.example/a"]
      refute "https://hallucinated.example/b" in urls

      [dropped_event] = Events.by_type(store, session.id, "search.url_dropped")
      payload = JSON.decode!(dropped_event.payload)
      assert payload["urls"] == ["https://hallucinated.example/b"]
    end

    test "max_results defaults to 5", %{context: context} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body)["input"] =~ "up to 5 results"
        respond_json(conn, 200, ok_response([], []))
      end)

      context = with_backend(context, bypass)
      assert {:ok, _} = WebSearch.call(%{"query" => "q"}, context)
    end

    test "max_results caps at 10 even if the model asks for more", %{context: context} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body)["input"] =~ "up to 10 results"
        respond_json(conn, 200, ok_response([], []))
      end)

      context = with_backend(context, bypass)
      assert {:ok, _} = WebSearch.call(%{"query" => "q", "max_results" => 999}, context)
    end

    test "records a usage record with cost = token cost + web_search per-call fee", %{
      context: context,
      store: store,
      mission: mission
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(
          conn,
          200,
          ok_response([], [], %{"input_tokens" => 8413, "output_tokens" => 104})
        )
      end)

      context = with_backend(context, bypass)
      assert {:ok, _} = WebSearch.call(%{"query" => "q"}, context)

      [usage] = Usage.by_mission(store, mission.id)
      assert usage.provider == "openai"
      assert usage.model == "gpt-5.6-luna"
      assert usage.input_tokens == 8413
      assert usage.output_tokens == 104
      assert usage.coverage == "reported"
      assert usage.server_tool_counts == %{"searches" => 1}

      catalog = Pricing.load()
      entry = Pricing.find(catalog, "gpt-5.6-luna")

      token_cost =
        Pricing.cost(entry, %{input_tokens: 8413, output_tokens: 104, cache_read_tokens: 0})

      fee = Pricing.tool_fee(catalog, "web_search")
      expected = Decimal.add(token_cost, fee)

      assert Decimal.equal?(Decimal.new(usage.cost_decimal), expected)
    end

    test "reserves against the mission budget before the call, and refuses when it would exceed the cap",
         %{
           context: context,
           mission: mission
         } do
      # A cap far below any plausible search cost forces `reserve_budget/2`
      # to fail before any HTTP request is made (no Bypass expectation set
      # -- a request would blow up the test if one were attempted).
      Sprat.Budget.set_cap(context.budget, mission.id, Decimal.new("0.00"))

      assert {:error, %{"kind" => "search_unavailable", "message" => message}} =
               WebSearch.call(%{"query" => "q"}, context)

      assert message =~ "budget"
    end

    test "adds every kept result URL to the mission's auto-fetch set, so web_fetch does not prompt for it",
         %{
           context: context,
           mission: mission
         } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(
          conn,
          200,
          ok_response(
            ["https://found-by-search.example/x"],
            [
              %{
                "url" => "https://found-by-search.example/x",
                "title" => "t",
                "snippet" => "s",
                "published" => nil
              }
            ]
          )
        )
      end)

      context = with_backend(context, bypass)

      refute WebFetch.auto_approved?("https://found-by-search.example/x", %{
               mission_id: mission.id
             })

      assert {:ok, _} = WebSearch.call(%{"query" => "q"}, context)

      assert WebFetch.auto_approved?("https://found-by-search.example/x", %{
               mission_id: mission.id
             })

      # a URL the model composed itself, never returned by search, still prompts
      refute WebFetch.auto_approved?("https://not-from-search.example/y", %{
               mission_id: mission.id
             })
    end

    test "clear_auto_fetch_urls/1 removes the mission's auto-fetch set", %{
      context: context,
      mission: mission
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(
          conn,
          200,
          ok_response(
            ["https://x.example/y"],
            [
              %{
                "url" => "https://x.example/y",
                "title" => "t",
                "snippet" => "s",
                "published" => nil
              }
            ]
          )
        )
      end)

      context = with_backend(context, bypass)
      assert {:ok, _} = WebSearch.call(%{"query" => "q"}, context)
      assert MapSet.size(WebSearch.auto_fetch_urls(mission.id)) == 1

      WebSearch.clear_auto_fetch_urls(mission.id)
      assert WebSearch.auto_fetch_urls(mission.id) == MapSet.new()
    end

    test "surfaces :rate_limited distinctly, releasing (not settling) the reservation", %{
      context: context,
      mission: mission
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(conn, 429, %{"error" => %{"message" => "slow down"}})
      end)

      context = with_backend(context, bypass)

      assert {:error, %{"kind" => "rate_limited", "message" => message}} =
               WebSearch.call(%{"query" => "q"}, context)

      assert message =~ "not evidence"
      status = Sprat.Budget.status(context.budget, mission.id)
      assert Decimal.equal?(status.reserved, Decimal.new(0))
    end

    test "surfaces :network_error on a transport failure -- an empty result must never look like this",
         %{
           context: context
         } do
      context = Map.put(context, :backend_opts, base_url: "http://localhost:1")

      assert {:error, %{"kind" => "network_error", "message" => message}} =
               WebSearch.call(%{"query" => "q"}, context)

      refute message =~ "no results"
    end

    test "an empty result set from a genuinely successful call is not an error", %{
      context: context
    } do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "POST", "/responses", fn conn ->
        respond_json(conn, 200, ok_response([], []))
      end)

      context = with_backend(context, bypass)
      assert {:ok, %{"results" => []}} = WebSearch.call(%{"query" => "q"}, context)
    end

    test "an unsupported provider is refused without ever making a request", %{context: context} do
      context = %{context | search_provider: "tavily"}

      assert {:error, %{"kind" => "search_unavailable", "message" => message}} =
               WebSearch.call(%{"query" => "q"}, context)

      assert message =~ "tavily"
    end
  end

  defp with_backend(context, bypass) do
    Map.put(context, :backend_opts, base_url: "http://localhost:#{bypass.port}")
  end
end
