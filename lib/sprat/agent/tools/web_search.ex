defmodule Sprat.Agent.Tools.WebSearch do
  @moduledoc """
  `web_search` tool (docs/design/web-search-options.md §7/§8): without
  this, the Researcher can only reach URLs the user gave it or that
  appear on a page it already fetched — it has to *guess* URLs, and a
  staged mission stalled twice on exactly that before this tool existed.

  Backend is a separate `POST /v1/responses` sub-request using OpenAI's
  hosted `web_search` tool (`Sprat.Agent.Tools.WebSearch.OpenAI`) — never
  the chat-completions call Sprat's main loop uses, which rejects the
  hosted tool outright (design doc §3.3). `[search] provider` (currently
  only `"openai"`) is the seam for a future backend (Tavily, per the doc's
  §9 open question #1) — not built here.

  `context` (all optional except where a step needs it; a missing key for
  a given step degrades that step rather than crashing):

      %{
        search_provider: "openai",       # only "openai" is implemented
        search_model: "gpt-5.6-luna",    # pinned in config, not the researcher's own model
        api_key: "sk-...",               # the same OpenAI key used everywhere else (§7: no second key)
        budget: Sprat.Budget,             # reserved against before the call; skipped if absent (tests)
        catalog: %Sprat.Model.Pricing{},  # for cost/fee lookup; loaded fresh if absent
        store: Sprat.Store,
        session_id: "...",                # for the search.completed/url_dropped events
        mission_id: "...",                # for usage records, budget, and the auto-fetch set
        task_id: "...",                   # for usage records
        secrets: [...],                   # redaction set for event payloads
        backend_opts: []                  # test-only: extra backend opts (base_url/plug), never set by Sprat.Mission
      }

  ## Results are candidates, not sources (spec-v1.md §6)

  Every result carries `snippet_origin: "model_summary"`: OpenAI's search
  doesn't return engine-written snippets, only what the model paraphrased
  from the page (design doc §3.1 "No page text is returned to the
  caller"). `published` is always `nil` — dates the model volunteered
  were unreliable in every live test for the design doc. A result becomes
  a real §6 source only through the existing path: `web_fetch` →
  `blob_hash` → `record_source`. This tool's own JSON result repeats that
  rule as a `"note"` field, and the role prompt repeats it again, because
  a fluent paraphrase reads exactly like a fact.

  ## The provenance check (§9 fetch rule depends on it)

  `Sprat.Agent.Tools.WebSearch.OpenAI.search/2` drops any URL the model's
  JSON claimed that isn't in the response's own
  `web_search_call.action.sources` list — see that module's doc. Only
  URLs that survive the check are added to the mission's auto-fetch set
  here; a URL the model invented is never let through, however
  confidently it's phrased.

  ## Usage, cost and budget (§12)

  The search sub-call is a real billable OpenAI call: it gets its own
  `Sprat.Store.Usage` record (tokens from the Responses `usage` block,
  `server_tool_counts: %{"searches" => n}`, cost = token cost + n ×
  the shipped per-call fee), and its worst-case cost is reserved against
  the mission's `Sprat.Budget` cap *before* the request is made, exactly
  like any model call the main loop makes.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Agent.Tools.WebSearch.OpenAI, as: OpenAIBackend
  alias Sprat.Budget
  alias Sprat.Model.Pricing
  alias Sprat.Store.{Events, Usage}

  @impl true
  def name, do: "web_search"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "web_search",
        "description" =>
          "Search the web for pages that might answer the question. Results are " <>
            "candidates, not evidence: title and snippet are the search model's own " <>
            "paraphrase of what it read (snippet_origin: \"model_summary\"), never " <>
            "engine output, and must never be quoted or cited as a fact. Their URLs can " <>
            "be web_fetch'd without an approval prompt; call record_source on what you " <>
            "fetch before citing anything from it.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "max_results" => %{"type" => "integer", "description" => "1-10, default 5"}
          },
          "required" => ["query"]
        }
      }
    }
  end

  @default_max_results 5
  @max_results_cap 10
  # Search content tokens aren't known before the call returns (measured
  # 8k-17k live, documented ceiling 128k -- design doc §3.1/§8): a fixed
  # pre-call allowance for the budget reservation, not a real request
  # parameter. ponytail: one constant for every model; revisit if a
  # pricier search model ever needs its own allowance.
  @input_token_allowance 20_000
  @output_token_allowance 1_500

  @impl true
  def call(%{"query" => query}, _context) when not is_binary(query) or query == "" do
    {:error, "expected {\"query\": \"...\"} with a non-empty query"}
  end

  # Same structural zero-network guard as `Sprat.Agent.Tools.WebFetch` —
  # see its comment. Search is normally already excluded from a replayed
  # stage's tool list (`Sprat.Orchestrator.search_enabled?/2` is false
  # without a real `api_key`/`search_model`), so this is a defense-in-depth
  # backstop, not the primary guard.
  def call(%{"query" => query}, %{network_disabled: true} = context) do
    not_run_message =
      "network access is disabled for this run (offline replay) — search was not run"

    case Map.get(context, :replay_search_lookup) do
      lookup when is_function(lookup, 1) ->
        case lookup.(query) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
          :not_found -> {:error, %{"kind" => "network_disabled", "message" => not_run_message}}
        end

      _ ->
        {:error, %{"kind" => "network_disabled", "message" => not_run_message}}
    end
  end

  def call(%{"query" => query} = args, context) do
    max_results = clamp_max_results(args["max_results"])

    with {:ok, provider} <- resolve_provider(context),
         {:ok, model} <- resolve_model(context),
         {:ok, api_key} <- resolve_api_key(context),
         {:ok, reservation} <- reserve_budget(context, model) do
      run(provider, query, model, api_key, max_results, context, reservation)
    else
      {:error, kind, message} -> {:error, tool_error(kind, message)}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"query\": \"...\"}"}

  defp clamp_max_results(n) when is_integer(n), do: n |> max(1) |> min(@max_results_cap)
  defp clamp_max_results(_), do: @default_max_results

  defp resolve_provider(context) do
    case Map.get(context, :search_provider, "openai") do
      "openai" -> {:ok, "openai"}
      other -> {:error, :search_unavailable, "unsupported search provider: #{inspect(other)}"}
    end
  end

  defp resolve_model(context) do
    case Map.get(context, :search_model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      _ -> {:error, :search_unavailable, "no search model configured (see [search] in config)"}
    end
  end

  defp resolve_api_key(context) do
    case Map.get(context, :api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :search_unavailable, "no API key available for search"}
    end
  end

  # Reservation is skipped only when the caller supplied no budget/mission
  # at all (unit tests exercising the backend in isolation) -- every real
  # mission wires both (see Sprat.Mission), so production search always
  # counts against the cap before the call is made.
  defp reserve_budget(context, model) do
    budget = Map.get(context, :budget)
    mission_id = Map.get(context, :mission_id)

    if is_nil(budget) or is_nil(mission_id) do
      {:ok, nil}
    else
      catalog = Map.get(context, :catalog) || Pricing.load()
      entry = Pricing.find(catalog, model)
      fee = Pricing.tool_fee(catalog, "web_search")

      case worst_case_cost(entry, fee) do
        nil ->
          {:error, :search_unavailable,
           "search cost unknown (model or web_search fee not priced) -- cannot reserve budget"}

        worst_case ->
          case Budget.reserve(budget, mission_id, worst_case) do
            {:ok, ref} -> {:ok, ref}
            {:error, reason} -> {:error, :search_unavailable, "budget: #{inspect(reason)}"}
          end
      end
    end
  end

  defp worst_case_cost(nil, _fee), do: nil
  defp worst_case_cost(_entry, nil), do: nil

  defp worst_case_cost(entry, fee) do
    case Pricing.worst_case(entry, @input_token_allowance, @output_token_allowance) do
      nil -> nil
      token_cost -> Decimal.add(token_cost, fee)
    end
  end

  defp run(provider, query, model, api_key, max_results, context, reservation) do
    case backend_search(provider, query, model, api_key, max_results, context) do
      {:ok, result} ->
        settle_success(context, reservation, model, result)
        record_events(context, query, result)
        remember_auto_fetch(context, result.results)
        {:ok, tool_result(query, result)}

      {:error, kind, message} ->
        release_reservation(context, reservation)

        {:error, tool_error(kind, message <> " This is not evidence the query has no answer.")}
    end
  end

  # `:backend_opts` is test-only injection (base_url/plug for Bypass) --
  # never set by `Sprat.Mission`.
  defp backend_search("openai", query, model, api_key, max_results, context) do
    extra = Map.get(context, :backend_opts, [])

    OpenAIBackend.search(
      query,
      [model: model, api_key: api_key, max_results: max_results] ++ extra
    )
  end

  defp release_reservation(_context, nil), do: :ok

  defp release_reservation(context, reservation),
    do: Budget.release(Map.get(context, :budget), reservation)

  defp settle_success(context, reservation, model, result) do
    record_usage(context, model, result)
    if reservation, do: Budget.settle(Map.get(context, :budget), reservation)
  end

  defp record_usage(context, model, result) do
    store = Map.get(context, :store)
    mission_id = Map.get(context, :mission_id)
    task_id = Map.get(context, :task_id)

    if store && mission_id && task_id do
      catalog = Map.get(context, :catalog) || Pricing.load()
      entry = Pricing.find(catalog, model)
      fee = Pricing.tool_fee(catalog, "web_search")
      {input, output, cached} = token_counts(result.usage)

      token_cost =
        entry && input && output &&
          Pricing.cost(entry, %{
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: cached
          })

      search_fee = fee && Decimal.mult(fee, result.search_calls)

      Usage.record(store, %{
        task_id: task_id,
        mission_id: mission_id,
        provider: "openai",
        model: model,
        raw_payload: %{"usage" => result.usage, "search_calls" => result.search_calls},
        input_tokens: input,
        output_tokens: output,
        cache_read_tokens: cached,
        server_tool_counts: %{"searches" => result.search_calls},
        cost: combine_cost(token_cost, search_fee),
        pricing_version: catalog.effective_date,
        coverage: if(result.usage, do: "reported", else: "estimated"),
        ended_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end
  end

  defp combine_cost(nil, nil), do: nil
  defp combine_cost(nil, fee), do: fee
  defp combine_cost(cost, nil), do: cost
  defp combine_cost(cost, fee), do: Decimal.add(cost, fee)

  # Cache reads are billed separately at the cached rate and must not also
  # be counted as ordinary input (§12), matching `Sprat.Model.OpenAI`'s own
  # `token_counts/2` -- the Responses API reports the *gross* input
  # (cache hit or not) under `input_tokens`, with the cache-hit share
  # broken out in `input_tokens_details.cached_tokens`.
  defp token_counts(nil), do: {nil, nil, nil}

  defp token_counts(usage) do
    cached = get_in(usage, ["input_tokens_details", "cached_tokens"])
    total_input = usage["input_tokens"]
    input = total_input && cached && total_input - cached
    {input || total_input, usage["output_tokens"], cached}
  end

  # `search.completed` is this tool's candidate audit trail (design doc §8
  # "Candidates could live purely in the event log instead of a new
  # table" -- chosen here: candidates are exactly what the event log
  # already exists for, §11, and `/sources`/the Evidence tab only ever
  # show *promoted* records via `record_source`, so a dedicated table
  # would just be a second place candidates live). `search.url_dropped`
  # is separate and unconditional whenever the provenance check drops
  # anything, so a hallucinated URL never disappears silently.
  defp record_events(context, query, result) do
    store = Map.get(context, :store)
    session_id = Map.get(context, :session_id)

    if store && session_id do
      attrs = %{mission_id: Map.get(context, :mission_id), task_id: Map.get(context, :task_id)}
      secrets = Map.get(context, :secrets, [])

      Events.append(
        store,
        session_id,
        "search.completed",
        Map.put(attrs, :payload, %{
          "provider" => "openai",
          "query" => query,
          "queries" => result.queries,
          "candidates" => Enum.map(result.results, &stringify/1),
          "dropped_urls" => result.dropped,
          "source_url_count" => length(result.source_urls)
        }),
        secrets
      )

      if result.dropped != [] do
        Events.append(
          store,
          session_id,
          "search.url_dropped",
          Map.put(attrs, :payload, %{
            "urls" => result.dropped,
            "reason" => "not_in_web_search_call_sources"
          }),
          secrets
        )
      end
    end
  end

  defp stringify(%{
         url: url,
         title: title,
         snippet: snippet,
         snippet_origin: origin,
         published: published
       }) do
    %{
      "url" => url,
      "title" => title,
      "snippet" => snippet,
      "snippet_origin" => origin,
      "published" => published
    }
  end

  defp remember_auto_fetch(context, results) do
    case Map.get(context, :mission_id) do
      nil -> :ok
      mission_id -> add_auto_fetch_urls(mission_id, Enum.map(results, & &1.url))
    end
  end

  defp tool_result(query, result) do
    %{
      "provider" => "openai",
      "query" => query,
      "queries" => result.queries,
      "results" => Enum.map(result.results, &stringify/1),
      "source_url_count" => length(result.source_urls),
      "note" =>
        "Titles and snippets are the search model's own paraphrase " <>
          "(snippet_origin: \"model_summary\"), not engine output -- never cite them " <>
          "directly. Fetch the URL with web_fetch (allowed without approval for these " <>
          "results) and record_source before treating anything from it as evidence."
    }
  end

  defp tool_error(kind, message), do: %{"kind" => to_string(kind), "message" => message}

  # -- mission-scoped auto-fetch set (§9 fetch rule) -----------------------
  # A search result's URL must be fetchable without an approval prompt for
  # the rest of THIS mission, but `Sprat.Agent.Loop`'s `tool_context` is
  # fixed for the whole run the moment `Sprat.Mission` builds it (only the
  # approval-resume path ever patches it). `:persistent_term` keyed by
  # mission_id is the same pattern `Sprat.Mission` already uses for its
  # own per-session mutable flags (cancel/active): growth here is bounded
  # by `max_results` per search call, and `clear_auto_fetch_urls/1` (called
  # by `Sprat.Mission` when the mission finishes) keeps it from
  # accumulating across missions.
  @doc "URLs `web_search` has surfaced for `mission_id` so far — checked by `Sprat.Agent.Tools.WebFetch.auto_approved?/2`."
  def auto_fetch_urls(nil), do: MapSet.new()

  def auto_fetch_urls(mission_id),
    do: :persistent_term.get(auto_fetch_key(mission_id), MapSet.new())

  @doc "Clears the auto-fetch set recorded for `mission_id`. Call once the mission finishes."
  def clear_auto_fetch_urls(mission_id), do: :persistent_term.erase(auto_fetch_key(mission_id))

  defp add_auto_fetch_urls(mission_id, urls) do
    :persistent_term.put(
      auto_fetch_key(mission_id),
      MapSet.union(auto_fetch_urls(mission_id), MapSet.new(urls))
    )
  end

  defp auto_fetch_key(mission_id), do: {__MODULE__, :auto_fetch_urls, mission_id}
end
