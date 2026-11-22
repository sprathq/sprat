defmodule Sprat.Agent.Tools.WebSearch.OpenAI do
  @moduledoc """
  OpenAI backend for `web_search` (docs/design/web-search-options.md §3.2,
  §7 recommendation): a **separate** `POST /v1/responses` call using
  OpenAI's hosted `web_search` tool — `tool_choice: "required"` and
  `max_tool_calls: 1` bound the call to exactly one search (and its fee),
  `include: ["web_search_call.action.sources"]` returns the full list of
  URLs the search actually consulted so every result can be checked
  against it, and a strict JSON schema makes the reply code-checkable
  instead of prose to be re-parsed.

  This never touches `Sprat.Model.OpenAI` (the chat-completions adapter
  Sprat's main loop uses): the hosted `web_search` tool is rejected on
  `/chat/completions` (`invalid_value`, only `function`/`custom` tool
  types are accepted there — confirmed live, design doc §3.3), so this
  makes its own request to the Responses API and is only ever called by
  `Sprat.Agent.Tools.WebSearch`.

  ## The provenance check (why this module exists, not just a prompt)

  `web_search_call.action.sources` is the ground truth of what the search
  actually surfaced (design doc §3.2: "The membership check (`result.url
  ∈ sources`) is ... a code-level guard that a returned URL really came
  from the search and was not composed by the model"). `parse/2` drops
  any result URL not present there — silently trusting the model's JSON
  would let a hallucinated URL launder itself into the mission's
  auto-fetch set and skip the §9 approval prompt.

  ## Snippets are not evidence

  `snippet` and `title` are the model's own paraphrase of what it read —
  OpenAI's search does not return engine-written snippets to the caller
  (design doc §3.1: "No page text is returned to the caller"). Every
  result here is tagged `snippet_origin: "model_summary"`. `published` is
  always `nil`: dates volunteered by the model were unreliable in every
  live test run for this doc (§3.2), so this module never surfaces one —
  a real publication date can only come from `web_fetch`ing the page.
  """

  @base_url "https://api.openai.com/v1"

  @schema %{
    "type" => "object",
    "properties" => %{
      "results" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "snippet" => %{"type" => "string"},
            "published" => %{"type" => ["string", "null"]}
          },
          "required" => ["url", "title", "snippet", "published"],
          "additionalProperties" => false
        }
      }
    },
    "required" => ["results"],
    "additionalProperties" => false
  }

  @tracking_params ~w(utm_source utm_medium utm_campaign utm_term utm_content)

  @doc """
  Runs one hosted search for `query`. `opts`: `:model` and `:api_key`
  (required), `:max_results` (default 5), `:base_url`/`:plug`/
  `:receive_timeout` (test injection).

  Returns `{:ok, result}` where `result` is:

      %{
        results: [%{url:, title:, snippet:, snippet_origin: "model_summary", published: nil}],
        dropped: [url, ...],     # results the model returned that were NOT in `sources` — discarded
        queries: [string, ...],  # what the model actually searched for (it may rewrite the query given)
        source_urls: [url, ...], # the full, unranked `web_search_call.action.sources` list
        search_calls: integer(), # count of web_search_call items (bounds the fee: max_tool_calls:1 caps this at 1)
        usage: map() | nil       # the Responses API's own usage block (input_tokens/output_tokens)
      }

  or `{:error, kind, message}` with `kind` one of `:search_unavailable`
  (non-2xx other than 429, or a malformed response), `:rate_limited`
  (429), `:network_error` (transport failure) — the same discipline
  `Sprat.Agent.Tools.WebFetch` uses: an error is never proof the query has
  no answer, and an empty `results` list from a genuinely successful call
  must never be confused with one of these.
  """
  def search(query, opts) do
    model = Keyword.fetch!(opts, :model)
    max_results = Keyword.get(opts, :max_results, 5)
    body = request_body(query, model, max_results)

    case req(opts) |> Req.post(url: "/responses", json: body) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse(resp_body, max_results)}

      {:ok, %{status: 429, body: body}} ->
        {:error, :rate_limited, "OpenAI rate-limited the search call: #{error_message(body)}"}

      {:ok, %{status: status, body: body}} ->
        {:error, :search_unavailable,
         "search call failed (HTTP #{status}): #{error_message(body)}"}

      {:error, reason} ->
        {:error, :network_error, "could not reach OpenAI for search: #{inspect(reason)}"}
    end
  end

  defp request_body(query, model, max_results) do
    %{
      "model" => model,
      "tools" => [%{"type" => "web_search"}],
      "tool_choice" => "required",
      "max_tool_calls" => 1,
      "include" => ["web_search_call.action.sources"],
      "store" => false,
      "input" => prompt(query, max_results),
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "search_results",
          "strict" => true,
          "schema" => @schema
        }
      }
    }
  end

  defp prompt(query, max_results) do
    "You are a search proxy. Run one web search for: #{query}. Return up to " <>
      "#{max_results} results using only what the search returned; \"published\" is " <>
      "null unless the result itself stated a date. Do not invent URLs, titles or facts " <>
      "the search did not surface."
  end

  defp req(opts) do
    Req.new(
      base_url: Keyword.get(opts, :base_url, @base_url),
      auth: {:bearer, Keyword.fetch!(opts, :api_key)},
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000),
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

  defp parse(resp_body, max_results) do
    output = resp_body["output"] || []
    search_call = Enum.find(output, &(&1["type"] == "web_search_call"))
    message = Enum.find(output, &(&1["type"] == "message"))

    queries =
      get_in(search_call, ["action", "queries"]) ||
        List.wrap(get_in(search_call, ["action", "query"]))

    source_urls =
      (get_in(search_call, ["action", "sources"]) || [])
      |> Enum.map(& &1["url"])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&strip_tracking/1)

    search_calls = Enum.count(output, &(&1["type"] == "web_search_call"))
    {results, dropped} = extract_results(message, source_urls, max_results)

    %{
      results: results,
      dropped: dropped,
      queries: queries,
      source_urls: source_urls,
      search_calls: search_calls,
      usage: resp_body["usage"]
    }
  end

  defp extract_results(nil, _source_urls, _max_results), do: {[], []}

  defp extract_results(message, source_urls, max_results) do
    text =
      message
      |> Map.get("content", [])
      |> Enum.find_value(fn part -> part["type"] == "output_text" && part["text"] end)

    case text && JSON.decode(text) do
      {:ok, %{"results" => raw_results}} when is_list(raw_results) ->
        raw_results
        |> Enum.take(max_results)
        |> Enum.reduce({[], []}, &sort_by_provenance(&1, &2, source_urls))
        |> then(fn {kept, dropped} -> {Enum.reverse(kept), Enum.reverse(dropped)} end)

      _ ->
        {[], []}
    end
  end

  # The membership check the module doc calls out: a result survives only
  # if its (tracking-stripped) URL is in `web_search_call.action.sources`
  # — the one thing in this response the model didn't write itself.
  defp sort_by_provenance(raw_result, {kept, dropped}, source_urls) do
    url = strip_tracking(raw_result["url"] || "")

    if url != "" and url in source_urls do
      {[to_result(raw_result, url) | kept], dropped}
    else
      {kept, [raw_result["url"] | dropped]}
    end
  end

  defp to_result(raw_result, url) do
    %{
      url: url,
      title: raw_result["title"],
      snippet: raw_result["snippet"],
      snippet_origin: "model_summary",
      # Never the model's `published` value — see moduledoc.
      published: nil
    }
  end

  defp strip_tracking(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.query do
      nil ->
        url

      query ->
        kept = query |> URI.decode_query() |> Map.drop(@tracking_params)
        new_query = if map_size(kept) == 0, do: nil, else: URI.encode_query(kept)
        URI.to_string(%{uri | query: new_query})
    end
  end

  defp strip_tracking(url), do: url

  defp error_message(%{"error" => %{"message" => msg}}) when is_binary(msg), do: msg
  defp error_message(body), do: inspect(body)
end
