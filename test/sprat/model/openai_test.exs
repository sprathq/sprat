defmodule Sprat.Model.OpenAITest do
  use ExUnit.Case, async: true

  alias Sprat.Model.OpenAI

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  defp opts(base_url), do: [base_url: base_url, api_key: "sk-test-key", backoff_base_ms: 1]

  # -- complete/2 (non-streaming) ------------------------------------------

  test "complete/2 parses content, stop reason and usage", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body_raw, conn} = Plug.Conn.read_body(conn)
      body = JSON.decode!(body_raw)
      assert body["model"] == "gpt-4.1-mini"
      assert body["stream"] == false

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{
          "choices" => [
            %{
              "message" => %{"role" => "assistant", "content" => "hi there"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
        })
      )
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hello"}],
      max_tokens: 100
    }

    assert {:ok, response} = OpenAI.complete(request, opts(base_url))
    assert response.content == "hi there"
    assert response.stop_reason == :stop
    assert response.tool_calls == []
    assert response.usage["prompt_tokens"] == 10
  end

  test "complete/2 parses tool calls", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_1",
                    "type" => "function",
                    "function" => %{
                      "name" => "calculate",
                      "arguments" => ~s({"expression":"2+2"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 20, "completion_tokens" => 8}
        })
      )
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "what is 2+2?"}],
      max_tokens: 100
    }

    assert {:ok, response} = OpenAI.complete(request, opts(base_url))
    assert response.stop_reason == :tool_calls

    assert [%{id: "call_1", name: "calculate", arguments: %{"expression" => "2+2"}}] =
             response.tool_calls
  end

  test "gpt-5.x uses max_completion_tokens, not max_tokens", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, body_raw, conn} = Plug.Conn.read_body(conn)
      body = JSON.decode!(body_raw)
      assert Map.has_key?(body, "max_completion_tokens")
      refute Map.has_key?(body, "max_tokens")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        JSON.encode!(%{
          "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
          "usage" => %{}
        })
      )
    end)

    request = %{
      model: "gpt-5-nano",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 50
    }

    assert {:ok, _} = OpenAI.complete(request, opts(base_url))
  end

  # -- retries ----------------------------------------------------------------

  test "retries on 429 honouring Retry-After, then succeeds", %{
    bypass: bypass,
    base_url: base_url
  } do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
      n = Agent.get_and_update(counter, &{&1, &1 + 1})

      if n == 0 do
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, JSON.encode!(%{"error" => "rate limited"}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          JSON.encode!(%{
            "choices" => [%{"message" => %{"content" => "ok"}, "finish_reason" => "stop"}],
            "usage" => %{}
          })
        )
      end
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 10
    }

    assert {:ok, response} = OpenAI.complete(request, opts(base_url))
    assert response.content == "ok"
    assert Agent.get(counter, & &1) == 2
  end

  test "gives up after the retry budget on repeated 5xx", %{bypass: bypass, base_url: base_url} do
    Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, JSON.encode!(%{"error" => "boom"}))
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 10
    }

    assert {:error, {:server_error, 500, _}} = OpenAI.complete(request, opts(base_url))
  end

  test "does not retry a plain 400", %{bypass: bypass, base_url: base_url} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", "/chat/completions", fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, JSON.encode!(%{"error" => "bad request"}))
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 10
    }

    assert {:error, {:http_error, 400, _}} = OpenAI.complete(request, opts(base_url))
    assert Agent.get(counter, & &1) == 1
  end

  # -- streaming ----------------------------------------------------------------

  test "stream/2 assembles content deltas and reports usage", %{
    bypass: bypass,
    base_url: base_url
  } do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      chunks = [
        sse(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"role" => "assistant", "content" => "Hel"},
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "choices" => [%{"index" => 0, "delta" => %{"content" => "lo"}, "finish_reason" => nil}]
        }),
        sse(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]}),
        sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}}),
        "data: [DONE]\n\n"
      ]

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    on_delta = fn delta -> Agent.update(agent, &[delta | &1]) end

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 50
    }

    assert {:ok, response} = OpenAI.stream(request, opts(base_url) ++ [on_delta: on_delta])

    assert response.content == "Hello"
    assert response.stop_reason == :stop
    assert response.usage["prompt_tokens"] == 5

    deltas = Agent.get(agent, & &1) |> Enum.reverse()
    assert Enum.map(deltas, & &1.text) == ["Hel", "lo"]
  end

  test "stream/2 assembles tool call argument fragments split across chunks", %{
    bypass: bypass,
    base_url: base_url
  } do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      chunks = [
        sse(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [
                  %{
                    "index" => 0,
                    "id" => "call_1",
                    "function" => %{"name" => "calculate", "arguments" => ""}
                  }
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "{\"expr"}}]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{
                "tool_calls" => [%{"index" => 0, "function" => %{"arguments" => "\":1}"}}]
              },
              "finish_reason" => nil
            }
          ]
        }),
        sse(%{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]}),
        sse(%{"choices" => [], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}}),
        "data: [DONE]\n\n"
      ]

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "calc"}],
      max_tokens: 50
    }

    assert {:ok, response} = OpenAI.stream(request, opts(base_url))
    assert response.stop_reason == :tool_calls
    assert [%{id: "call_1", name: "calculate", arguments: %{"expr" => 1}}] = response.tool_calls
  end

  test "stream/2 skips a malformed JSON frame instead of raising", %{
    bypass: bypass,
    base_url: base_url
  } do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      chunks = [
        "data: {not valid json}\n\n",
        sse(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "ok"}, "finish_reason" => "stop"}
          ]
        }),
        "data: [DONE]\n\n"
      ]

      conn = Plug.Conn.send_chunked(conn, 200)

      Enum.reduce(chunks, conn, fn chunk, conn ->
        {:ok, conn} = Plug.Conn.chunk(conn, chunk)
        conn
      end)
    end)

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 10
    }

    assert {:ok, response} = OpenAI.stream(request, opts(base_url))
    assert response.content == "ok"
  end

  test "stream/2 cancellation closes early and marks stop_reason :cancelled", %{
    bypass: bypass,
    base_url: base_url
  } do
    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      conn = Plug.Conn.send_chunked(conn, 200)

      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          sse(%{
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "partial"}, "finish_reason" => nil}
            ]
          })
        )

      # The client's on_delta flips `cancel?` to true right after this
      # first chunk is processed, so its `into` callback halts (and closes
      # the connection) the moment this second chunk arrives — without the
      # server ever needing to notice the connection is going away.
      {:ok, _conn} =
        Plug.Conn.chunk(
          conn,
          sse(%{
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "more"}, "finish_reason" => nil}
            ]
          })
        )
    end)

    {:ok, cancel_flag} = Agent.start_link(fn -> false end)

    on_delta = fn _delta ->
      if Agent.get(cancel_flag, & &1) == false, do: Agent.update(cancel_flag, fn _ -> true end)
    end

    cancel? = fn -> Agent.get(cancel_flag, & &1) end

    request = %{
      model: "gpt-4.1-mini",
      messages: [%{"role" => "user", "content" => "hi"}],
      max_tokens: 50
    }

    assert {:ok, response} =
             OpenAI.stream(request, opts(base_url) ++ [on_delta: on_delta, cancel?: cancel?])

    assert response.stop_reason == :cancelled
    assert response.content == "partial"
  end

  # -- usage normalisation ------------------------------------------------------

  test "normalize_usage/2 nets cache reads out of input tokens and computes cost" do
    raw = %{
      "prompt_tokens" => 1000,
      "completion_tokens" => 200,
      "prompt_tokens_details" => %{"cached_tokens" => 400}
    }

    attrs = OpenAI.normalize_usage(raw, %{model: "gpt-4.1-mini"})

    assert attrs.input_tokens == 600
    assert attrs.cache_read_tokens == 400
    assert attrs.output_tokens == 200
    assert attrs.coverage == "reported"
    assert %Decimal{} = attrs.cost
  end

  test "normalize_usage/2 marks an interrupted call estimated" do
    attrs =
      OpenAI.normalize_usage(nil, %{
        model: "gpt-4.1-mini",
        interrupted?: true,
        local_input_tokens: 50,
        streamed_output_estimate: 10
      })

    assert attrs.coverage == "estimated"
    assert attrs.input_tokens == 50
    assert attrs.output_tokens == 10
  end

  test "normalize_usage/2 leaves cost nil (price unknown) for an unlisted model" do
    raw = %{"prompt_tokens" => 100, "completion_tokens" => 10}
    attrs = OpenAI.normalize_usage(raw, %{model: "totally-made-up-model"})
    assert attrs.cost == nil
    assert attrs.pricing_version == nil
  end

  defp sse(map), do: "data: #{JSON.encode!(map)}\n\n"
end
