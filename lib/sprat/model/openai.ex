defmodule Sprat.Model.OpenAI do
  @moduledoc """
  `Sprat.Model` adapter for the OpenAI Chat Completions API (docs/spec-v1.md
  §7, adapted to OpenAI per the owner's V1 choice — the section describes
  Anthropic first, but the shape — one native adapter, streaming, tool use,
  `Sprat.Model` behind it — is what's implemented here).

  Messages are passed through close to OpenAI's own wire shape
  (`%{role:, content:}`, assistant messages carrying `tool_calls`, tool
  results carrying `tool_call_id`) rather than translated from a
  provider-neutral shape — there is only one provider in V1, so that
  translation layer doesn't exist yet (see the build report).

  gpt-5.x and o-series models take `max_completion_tokens` instead of
  `max_tokens` and price reasoning tokens as ordinary output tokens
  (confirmed against the live API 2026-09-18, not documented anywhere
  Sprat could find) — `reasoning_family?/1` is the switch.
  """

  @behaviour Sprat.Model

  alias Sprat.Model.OpenAI.SSE
  alias Sprat.Model.Pricing

  @base_url "https://api.openai.com/v1"
  @max_retries 2
  @default_backoff_ms 500
  @max_backoff_ms 8_000
  @normalization_version 1

  # -- Sprat.Model callbacks --------------------------------------------------

  @impl true
  def capabilities(model_id) do
    catalog = Pricing.load()

    case Pricing.find(catalog, model_id) do
      nil -> {:error, :unknown_model}
      entry -> {:ok, entry}
    end
  end

  @impl true
  def complete(request, opts \\ []) do
    with_retries(opts, fn -> do_complete(request, opts) end)
  end

  @impl true
  def stream(request, opts \\ []) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)
    cancel? = Keyword.get(opts, :cancel?, fn -> false end)
    model = Map.get(request, :model) || Map.get(request, "model")
    body = build_body(request, stream: true)

    result =
      req(opts)
      |> Req.post(
        url: "/chat/completions",
        json: body,
        into: fn {:data, data}, {req, resp} ->
          state = resp.private[:sse] || initial_stream_state(model)

          if cancel?.() do
            final = %{state | cancelled?: true}
            {:halt, {req, Req.Response.put_private(resp, :sse, final)}}
          else
            {events, new_buffer} = SSE.feed(state.buffer, data)

            new_state =
              Enum.reduce(events, %{state | buffer: new_buffer}, &apply_event(&2, &1, on_delta))

            {:cont, {req, Req.Response.put_private(resp, :sse, new_state)}}
          end
        end
      )

    case result do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        state = resp.private[:sse] || initial_stream_state(model)
        {:ok, finalize_stream(state)}

      {:ok, resp} ->
        {:error, classify_http_error(resp)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @impl true
  def normalize_usage(raw, context) do
    model = Map.fetch!(context, :model)
    interrupted? = Map.get(context, :interrupted?, false)
    catalog = context[:catalog] || Pricing.load()
    entry = Pricing.find(catalog, model)

    {input, output, cached} = token_counts(raw, context)

    cost =
      entry &&
        Pricing.cost(entry, %{
          input_tokens: input,
          output_tokens: output,
          cache_read_tokens: cached
        })

    coverage =
      cond do
        raw != nil and not interrupted? -> "reported"
        interrupted? -> "estimated"
        true -> "unavailable"
      end

    %{
      provider: "openai",
      model: model,
      raw_payload: raw || %{},
      normalization_version: @normalization_version,
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cached,
      cache_write_tokens: nil,
      cost: cost,
      pricing_version: entry && catalog.effective_date,
      coverage: coverage
    }
  end

  @doc "Lists model ids the API key has access to (`GET /v1/models`), for the owner's manual-selection UI (§7 owner decision #2)."
  def list_models(opts \\ []) do
    case req(opts) |> Req.get(url: "/models") do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data |> Enum.map(& &1["id"]) |> Enum.sort()}

      {:ok, resp} ->
        {:error, classify_http_error(resp)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc "True for models that take `max_completion_tokens` instead of `max_tokens` and bill reasoning tokens as output (gpt-5.x, gpt-6.x, o-series)."
  def reasoning_family?(model) when is_binary(model) do
    String.starts_with?(model, "gpt-5") or String.starts_with?(model, "gpt-6") or
      String.match?(model, ~r/^o\d/)
  end

  # -- non-streaming ----------------------------------------------------------

  defp do_complete(request, opts) do
    body = build_body(request, stream: false)

    case req(opts) |> Req.post(url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: resp_body}} -> {:ok, parse_completion(resp_body)}
      {:ok, resp} -> {:error, classify_http_error(resp)}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  defp parse_completion(body) do
    choice = hd(body["choices"] || [%{}])
    message = choice["message"] || %{}

    %{
      content: message["content"],
      tool_calls: parse_tool_calls(message["tool_calls"]),
      stop_reason: stop_reason(choice["finish_reason"], message),
      usage: body["usage"],
      raw: body
    }
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        name: tc["function"]["name"],
        arguments: decode_arguments(tc["function"]["arguments"])
      }
    end)
  end

  defp decode_arguments(nil), do: %{}

  defp decode_arguments(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"_raw" => json, "_parse_error" => true}
    end
  end

  defp stop_reason(_finish_reason, %{"refusal" => refusal}) when is_binary(refusal), do: :refusal
  defp stop_reason("tool_calls", _), do: :tool_calls
  defp stop_reason("length", _), do: :length
  defp stop_reason("content_filter", _), do: :content_filter
  defp stop_reason("stop", _), do: :stop
  defp stop_reason(_other, _), do: :stop

  # -- streaming assembly -------------------------------------------------------

  defp initial_stream_state(model) do
    %{
      buffer: "",
      content: "",
      tool_calls: %{},
      finish_reason: nil,
      usage: nil,
      cancelled?: false,
      model: model,
      events: []
    }
  end

  defp apply_event(state, :done, _on_delta), do: state
  defp apply_event(state, :malformed, _on_delta), do: state

  defp apply_event(state, chunk, on_delta) do
    choice = List.first(chunk["choices"] || [])
    state = if chunk["usage"], do: %{state | usage: chunk["usage"]}, else: state

    case choice do
      nil ->
        state

      %{"delta" => delta, "finish_reason" => finish_reason} ->
        state = if finish_reason, do: %{state | finish_reason: finish_reason}, else: state
        state = apply_content_delta(state, delta["content"], on_delta)
        apply_tool_call_delta(state, delta["tool_calls"], on_delta)
    end
  end

  defp apply_content_delta(state, nil, _on_delta), do: state
  defp apply_content_delta(state, "", _on_delta), do: state

  defp apply_content_delta(state, text, on_delta) do
    on_delta.(%{type: :content, text: text})
    %{state | content: state.content <> text}
  end

  defp apply_tool_call_delta(state, nil, _on_delta), do: state

  defp apply_tool_call_delta(state, deltas, on_delta) do
    Enum.reduce(deltas, state, fn tc, acc ->
      index = tc["index"]
      current = Map.get(acc.tool_calls, index, %{id: nil, name: nil, arguments: ""})

      updated = %{
        id: tc["id"] || current.id,
        name: get_in(tc, ["function", "name"]) || current.name,
        arguments: current.arguments <> (get_in(tc, ["function", "arguments"]) || "")
      }

      on_delta.(%{
        type: :tool_call,
        index: index,
        id: updated.id,
        name: updated.name,
        arguments_fragment: get_in(tc, ["function", "arguments"]) || ""
      })

      %{acc | tool_calls: Map.put(acc.tool_calls, index, updated)}
    end)
  end

  defp finalize_stream(state) do
    tool_calls =
      state.tool_calls
      |> Enum.sort_by(fn {index, _} -> index end)
      |> Enum.map(fn {_index, tc} ->
        %{id: tc.id, name: tc.name, arguments: decode_arguments(tc.arguments)}
      end)

    stop_reason =
      cond do
        state.cancelled? -> :cancelled
        state.finish_reason == "tool_calls" -> :tool_calls
        state.finish_reason == "length" -> :length
        state.finish_reason == "content_filter" -> :content_filter
        true -> :stop
      end

    %{
      content: if(state.content == "", do: nil, else: state.content),
      tool_calls: tool_calls,
      stop_reason: stop_reason,
      usage: state.usage,
      raw: %{"streamed" => true, "usage" => state.usage, "finish_reason" => state.finish_reason}
    }
  end

  # -- usage normalisation helpers ---------------------------------------------

  defp token_counts(nil, context),
    do: {context[:local_input_tokens], context[:streamed_output_estimate], nil}

  defp token_counts(raw, context) do
    cached = get_in(raw, ["prompt_tokens_details", "cached_tokens"])
    prompt = raw["prompt_tokens"]
    # Cache reads are billed separately and must not double-count as input
    # (§12): subtract them from the reported prompt total.
    input = prompt && cached && prompt - cached
    input = input || prompt || context[:local_input_tokens]
    output = raw["completion_tokens"] || context[:streamed_output_estimate]
    {input, output, cached}
  end

  # -- HTTP plumbing ------------------------------------------------------------

  defp req(opts) do
    key = Keyword.get_lazy(opts, :api_key, fn -> resolve_key() end)
    base_url = Keyword.get(opts, :base_url, @base_url)

    Req.new(
      base_url: base_url,
      auth: {:bearer, key},
      receive_timeout: Keyword.get(opts, :receive_timeout, 60_000),
      retry: false
    )
    |> maybe_plug(opts)
  end

  defp maybe_plug(req, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req
      plug -> Req.merge(req, plug: plug)
    end
  end

  defp resolve_key do
    case Sprat.Secrets.resolve() do
      {:ok, key, _source} -> key
      :error -> raise "no OpenAI API key configured (see `sprat auth login` / OPENAI_API_KEY)"
    end
  end

  defp build_body(request, stream: stream?) do
    model = Map.get(request, :model) || Map.get(request, "model")
    max_tokens = Map.get(request, :max_tokens) || Map.get(request, "max_tokens")
    tokens_key = if reasoning_family?(model), do: "max_completion_tokens", else: "max_tokens"

    %{
      "model" => model,
      "messages" => Map.get(request, :messages) || Map.get(request, "messages"),
      "stream" => stream?
    }
    |> maybe_put("tools", Map.get(request, :tools) || Map.get(request, "tools"))
    |> maybe_put(tokens_key, max_tokens)
    |> then(fn body ->
      if stream?, do: Map.put(body, "stream_options", %{"include_usage" => true}), else: body
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp classify_http_error(%{status: 429, body: body, headers: headers}),
    do: {:rate_limited, body, retry_after_ms(headers)}

  defp classify_http_error(%{status: status, body: body}) when status >= 500,
    do: {:server_error, status, body}

  defp classify_http_error(%{status: status, body: body}), do: {:http_error, status, body}

  # Req 0.5+ response headers are `%{"name" => [values]}`, lower-cased.
  defp retry_after_ms(headers) do
    case Map.get(headers, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, _} -> seconds * 1000
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp retryable?({:rate_limited, _, _}), do: true
  defp retryable?({:server_error, _, _}), do: true
  defp retryable?({:transport, _}), do: true
  defp retryable?(_), do: false

  defp with_retries(opts, fun, attempt \\ 0) do
    case fun.() do
      {:error, reason} = error ->
        if attempt < @max_retries and retryable?(reason) do
          Process.sleep(backoff_ms(reason, attempt, opts))
          with_retries(opts, fun, attempt + 1)
        else
          error
        end

      ok ->
        ok
    end
  end

  defp backoff_ms(reason, attempt, opts) do
    base = Keyword.get(opts, :backoff_base_ms, @default_backoff_ms)

    case reason do
      {:rate_limited, _body, retry_after_ms} when is_integer(retry_after_ms) -> retry_after_ms
      _ -> min(base * Integer.pow(2, attempt), @max_backoff_ms)
    end
  end
end
