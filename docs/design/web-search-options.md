# Web search for Sprat — options and recommendation

Date: 2026-09-20
Status: research finding; decision is the owner's (spec §17 item 2)
Scope: read-only study. No code was changed. Live-test spend: about **$0.07** (breakdown in §3).

## 1. The question

Sprat has `web_fetch` but no search, so the Researcher can only reach URLs the user gives it or that appear on
pages it has fetched. Phase 0 (docs/phase0/02-search-metadata-codex.md) found that Codex exposed search *queries*
but not *results*. So the test for every option here is:

> Does it hand back structured results (URL, title, snippet, date) that Sprat can store and verify itself?

One fact frames everything below. A §6 source record needs a content hash and a stored snapshot. **No search
product supplies those in a form Sprat should trust** — they come from Sprat's own `web_fetch`, which already
stores the raw body in the blob store and returns a `blob_hash`. So search only has to deliver good *candidate*
URLs with enough metadata for the Researcher to choose which to fetch. Every option is therefore "partly" at
best for §6, and that is fine: search result → candidate, fetch → source record.

## 2. Comparison

Cost column is the search fee only. "Mission" = 20 searches + 30 fetches; the 30 fetches go through Sprat's own
`web_fetch` under every option, carry no per-call fee, and cost the same tokens everywhere (up to 8,000 tokens
each = up to 240k input tokens: about $0.05 on gpt-5.6-luna, $0.48 on gpt-5.6-terra, before any re-reading of
context on later turns). So the mission column shows only what differs.

| Option | How invoked | What comes back | Enough for §6 record | Cost / 1,000 searches | Free tier | Second key | Mission (20 searches) | Main risk |
|---|---|---|---|---|---|---|---|---|
| **OpenAI `web_search`, Responses API, called as a sub-request by Sprat's own tool** | `POST /v1/responses`, `tools:[{type:"web_search"}]`, `include:["web_search_call.action.sources"]`, strict JSON-schema output | Queries; full list of consulted URLs (bare URLs only); `url_citation` annotations (url + title + character span); plus whatever JSON the model is told to write (title/snippet/date are **model-written**) | Partly — URL and title; no engine snippet, no reliable date | $10 fee + tokens. Measured 8.4k–12.8k input tokens per search: **≈ $12–13** on gpt-5.6-luna, ≈ $40+ on gpt-5.6-terra | None | **No** | **≈ $0.26** (luna) | Snippets are an LLM paraphrase, not engine output; non-deterministic; 3–10 s per search |
| OpenAI `gpt-5-search-api` via Chat Completions | `model:"gpt-5-search-api"`, `web_search_options:{}` on the endpoint Sprat already uses | Answer text + `annotations[].url_citation` (url, title, span). **No source list, no queries** | Partly, and weaker — only the URLs the model chose to cite (1 in the live test) | Measured 16.7k prompt tokens at $1.25/M ≈ $21, plus the $10 call fee if it applies to this model (**unconfirmed**) ≈ **$21–31** | None | No | ≈ $0.42–0.63 | Returns an answer, not results; Sprat can't see what was searched |
| OpenAI `gpt-4o-search-preview` / `gpt-4o-mini-search-preview` | — | — | — | — | — | — | — | **Dead.** Listed by `GET /v1/models` on the owner's account but every call returns `model_not_found … has been deprecated` (shutdown 2026-07-23) |
| Hosted `web_search` inside Sprat's main chat-completions call | `tools:[{type:"web_search"}]` on `/chat/completions` | — | — | — | — | — | — | **Not possible.** API rejects it: `Supported values are: 'function' and 'custom'` |
| **Tavily** | `POST https://api.tavily.com/search`, bearer key | `title`, `url`, `content` (snippet), `score`, `published_date` (best estimate, nullable; needs `include_published_date` or `topic:"news"`), `favicon`; optional `raw_content` (page text/markdown) | Partly — best metadata of the group, incl. date; page text optional | **$8** basic (1 credit), $16 advanced (2 credits), pay-as-you-go $0.008/credit | 1,000 credits/month, no card | Yes | $0.16 (free within 1,000/mo) | Second key; terms say "internal business purposes", output ownership not granted explicitly |
| **Brave Search API** | `GET https://api.search.brave.com/res/v1/web/search`, `X-Subscription-Token` | `title`, `url`, `description`, `age`, `page_age` (ISO date), `profile` (publisher), `meta_url`, optional `extra_snippets`. Links and snippets, no page text | Partly — URL, title, publisher, date | **$5** | $5 credit/month (= 1,000 searches) | Yes | $0.10 (free within credit) | **Terms forbid storing results** and forbid using results to "evaluate … benchmark or otherwise improve" AI services (quotes in §5) |
| Exa | `POST https://api.exa.ai/search`, `x-api-key` | `title`, `url`, `publishedDate`, `author`, `id`, optional `text`, `highlights`, `summary`; `costDollars` per response | Partly — incl. date and author; page text in same call | **$7** (≤10 results) + $1 per 1k pages of contents | $20 on signup, then $10 credit/month | Yes | $0.14 (+$0.03 if contents for 30 pages) | Neural index: strong for "find companies like X", less predictable for exact-keyword and fresh news queries (my judgement, not tested) |
| Perplexity Search API | `POST https://api.perplexity.ai/search` | `title`, `url`, `snippet`, `date`, `last_updated` | Partly — incl. two dates | **$5**, no token charges | None found | Yes | $0.10 | Rate limits and storage terms **unconfirmed** |
| SerpAPI (Google results) | `GET https://serpapi.com/search` | Google organic results: title, link, snippet, date when Google shows one | Partly | **$25** on Starter ($25/mo for 1,000); $15 on Developer; $10 on Production | 250 searches/month, 50/hour | Yes | $0.50 | Monthly subscription, not pay-per-use; it is scraping Google — the "U.S. Legal Shield" exists because that is legally contested, and the free and low plans don't include it |
| Serper.dev (Google results) | `POST https://google.serper.dev/search` | title, link, snippet, date, sitelinks, knowledge graph | Partly | **unconfirmed** (price table not readable without an account) | 2,500 queries one-off | Yes | unconfirmed | Same scraping exposure as SerpAPI, no stated legal cover |
| DuckDuckGo HTML (`html.duckduckgo.com`) | scrape HTML | title, url, snippet when it works | Partly | $0 | — | No | $0 | **Blocked on the first request in testing** (§6). No API contract. Not shippable |
| SearXNG (public instance) | `GET /search?format=json` | title, url, content, engine, sometimes `publishedDate` | Partly | $0 | — | No | $0 | Public instances bot-wall API clients (tested, §6); JSON is off by default; it scrapes upstream engines against their terms. Self-hosting means asking users to run Docker |

Not considered further: Bing Web Search API (retired by Microsoft in August 2025 — from memory, **unconfirmed
today**); Google Programmable Search JSON API (site-restricted engine, 100 free queries/day — from memory,
**unconfirmed today**). Neither was re-checked, so neither is in the table.

## 3. Evidence: live calls against the owner's key (2026-09-20)

Six requests, three billable. Nothing is redacted; the key never appears because it was only ever in a header.
Long lists are cut with `…` and the count given.

### 3.1 Responses API + `web_search` — works, and returns results Sprat can use

Request: `model: gpt-5.6-luna`, `tools:[{"type":"web_search"}]`, `include:["web_search_call.action.sources"]`,
`reasoning.effort: low`. Output (trimmed to the two items that matter):

```json
"output": [
  {
    "id": "ws_0a9348f333d7b2dd006ab05d56dcd087d2b40b18436295e18d",
    "type": "web_search_call",
    "status": "completed",
    "action": {
      "type": "search",
      "queries": [
        "site:elixir-lang.org latest stable Elixir release 2026",
        "site:github.com/elixir-lang/elixir releases latest"
      ],
      "query": "site:elixir-lang.org latest stable Elixir release 2026",
      "sources": [
        { "type": "url", "url": "https://github.com/elixir-lang/elixir/releases" },
        { "type": "url", "url": "https://github.com/elixir-lang/elixir/blob/main/CHANGELOG.md" },
        { "type": "url", "url": "https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/" },
        … 19 in total, including 6 unrelated GitHub PDF cheat-sheets
      ]
    }
  },
  {
    "type": "message",
    "content": [{
      "type": "output_text",
      "annotations": [{
        "type": "url_citation",
        "start_index": 82, "end_index": 162,
        "title": "Releases · elixir-lang/elixir · GitHub",
        "url": "https://github.com/elixir-lang/elixir/releases?utm_source=openai"
      }],
      "text": "The latest stable release of Elixir is **v1.20.0**, released on **June 3, 2026**. ([github.com](https://github.com/elixir-lang/elixir/releases?utm_source=openai))"
    }]
  }
],
"usage": { "input_tokens": 8413, "input_tokens_details": { "cache_write_tokens": 4402, "cached_tokens": 0 },
           "output_tokens": 104, "output_tokens_details": { "reasoning_tokens": 51 } }
```

What this settles:

- Unlike Codex, the **queries and the consulted URLs are both visible**. That was the Phase 0 blocker and it
  does not apply here.
- `sources` entries are **bare URLs** — no title, snippet, or date. Titles exist only on `url_citation`
  annotations, i.e. only for URLs the model chose to cite (1 of 19 here).
- The source list is unranked and noisy (the PDF cheat-sheets). It is not a results page.
- Cited URLs carry `?utm_source=openai`; Sprat's canonical-key normalisation must strip it.
- A search injects roughly 8k input tokens of page content, billed at the model's input rate.

### 3.2 The "search proxy" shape — strict JSON results, checkable in code

Same endpoint, plus `tool_choice:"required"`, `max_tool_calls:1`, `search_context_size:"low"`, `store:false`
and `text.format` = a strict `json_schema` of `{results:[{url,title,snippet,published}]}`. Prompt: *"You are a
search proxy. Run one web search for: Tavily API pricing change 2026. Return up to 5 results using only what
the search returned; published is null unless the result stated a date."*

Result: valid JSON, 5 results; `web_search_call.action.sources` held 19 URLs and **all 5 returned URLs were in
it**. One result had a date (`"Mar 6, 2026"`, a blog post), four were `null`. Usage: 8,661 input / 395 output.

An earlier unstructured run of the same idea (query "independent gym management software UK pricing") returned
41 source URLs and rows like:

```json
{ "url": "https://fullrack.co.uk/gyms/",
  "title": "Gym management software for independent UK gyms — Fullrack",
  "snippet": "Fullrack is white-label gym management software for independent UK gyms, studios and CrossFit boxes. Pricing starts at £79 per month for up to 50 members, £139 for up to 100, and £249 for up to 200, plus a one-off £199 setup fee.",
  "published": null }
```

That snippet is fluent because **the model wrote it**. It is a paraphrase of what the model read, not text
returned by a search engine, and it can be wrong. It is good enough to choose what to fetch; it is not evidence.
Usage for that run: 12,824 input (4,251 cached) / 764 output.

The membership check (`result.url ∈ sources`) is the useful part: it is a code-level guard that a returned URL
really came from the search and was not composed by the model — which is exactly the distinction the §9 fetch
rule depends on.

### 3.3 Chat Completions paths

- `gpt-5-search-api` with `web_search_options` **works** on `/chat/completions` and returns
  `choices[0].message.annotations[] = {type:"url_citation", url_citation:{url,title,start_index,end_index}}`.
  It returned one citation (`formulae.brew.sh`), no query, no source list. Usage: 16,665 prompt / 63 completion
  tokens with `search_context_size:"low"`.
- It answered **v1.20.4, 23 June 2026**; the Responses call in 3.1 answered **v1.20.0, 3 June 2026**, for the
  same question a minute apart. Both are plausibly "true" from their one cited page. This is the argument for
  Sprat verifying by fetching rather than trusting a search model's answer.
- `gpt-4o-mini-search-preview` and `gpt-4o-search-preview`: `model_not_found`, "has been deprecated". They are
  still in the owner's model list, which is misleading; don't offer them in the model picker.
- `tools:[{"type":"web_search"}]` on `/chat/completions` with `gpt-5.6-luna`: `invalid_value`, only `function`
  and `custom` are accepted. So the hosted tool can't be bolted onto `Sprat.Model.OpenAI` as it stands.

### 3.4 Spend

| Call | Tokens (in / out) | Token cost at list price | Search fee | Total |
|---|---|---|---|---|
| 3.1 Responses, luna | 8,413 / 104 | $0.0018 | $0.01 | $0.012 |
| 3.2 proxy, unstructured, luna | 12,824 (4,251 cached) / 764 | $0.0027 | $0.01 | $0.013 |
| 3.2 proxy, strict JSON, luna | 8,661 / 395 | $0.0022 | $0.01 | $0.012 |
| 3.3 gpt-5-search-api | 16,665 / 63 | $0.0215 | $0.01 (if charged) | $0.031 |
| 3 rejected calls | — | $0 | $0 | $0 |
| **Total** | | | | **≈ $0.07** |

This is computed from list prices, not read from the billing dashboard. Cache-write tokens are assumed to bill
at the normal input rate (**unconfirmed**); if they carry a premium the total is still under $0.08.

## 4. OpenAI web search — what the docs say

- Responses API: `{"type":"web_search"}` in `tools`. Chat Completions: only the dedicated search models
  (`gpt-5-search-api`; the two `gpt-4o-*-search-preview` models are marked deprecated).
- Output: a `web_search_call` item whose `action` is `search` (with queries), `open_page`, or `find_in_page`
  (the last two on reasoning models), then a `message` with `url_citation` annotations (`url`, `title`,
  location). `include:["web_search_call.action.sources"]` adds the full list of consulted URLs.
- Controls: `filters.allowed_domains` / `blocked_domains` (up to 100), `user_location` (country, city, region,
  timezone), `search_context_size`. The live response also showed `return_token_budget` and
  `search_content_types` on the tool. The older `web_search_preview` tool lacks `filters`.
- Limits: search context capped at 128k tokens; rate limits are those of the underlying model; `gpt-5` at
  `minimal` reasoning is not supported.
- Pricing: web search **$10.00 / 1k calls + search content tokens billed at model rates**. The older preview
  tool on non-reasoning models is $25.00 / 1k with content tokens free. `gpt-5-search-api`: $1.25 in / $0.125
  cached / $10.00 out per 1M tokens. gpt-5.6-luna: $0.20 / $0.02 / $1.20 (matches `priv/models/openai.json`).
- No page text is returned to the caller. The model reads pages; Sprat doesn't get them.
- Storage terms for the returned URLs/titles: not checked against OpenAI's usage policies — **unconfirmed**.

## 5. Dedicated search APIs — terms that matter

Sprat stores search results as candidate sources, so storage terms are the point.

**Brave.** Cheapest and the cleanest result schema (`page_age` and `profile` map straight onto §6 "publication
date" and "publisher"). 50 queries/second. But the API terms list as prohibited:

> "store, cache, or create a database of Search Results, in whole or in part, other than transient storage
> required for operation of Customer Applications"

> "use the Search Results to create, evaluate, train, re-train, fine-tune, benchmark or otherwise improve
> artificial intelligence models or services"

A persisted candidate-source table is hard to call transient, and Sprat's eval set (spec §16) would run on
search results. Storage rights are an Enterprise negotiation. A BYOK user is the customer of record, so the
exposure is theirs rather than Sprat's — but shipping a default that puts users in breach is not a good look.
A workable mitigation exists (persist only the URL, take title/date from Sprat's own fetch), and it should be
the owner's call whether that is enough.

**Tavily.** Built for agents; `published_date` is the most useful field for a research product. Terms don't
prohibit storing output; they do restrict use to "internal business purposes", prohibit resale and using the
service "to build a competitive product", and don't grant output ownership explicitly. 100 requests/minute on
development keys, 1,000 on production. `include_raw_content` can return page text in the same call, which
could replace a fetch — but Sprat should still fetch the page itself, because §6 wants a snapshot Sprat
retrieved and hashed, and the Phase 0 finding was that self-fetching doubles as a hallucinated-citation check.

**Exa.** 10 QPS. Returns `publishedDate`, `author`, and page `text` in the search call; `costDollars` in every
response makes ledger accounting exact. Zero-data-retention is enterprise-only. Storage terms not read —
**unconfirmed**.

**SerpAPI / Serper.** Real Google results, which are the best for long-tail commercial queries ("X software
pricing UK"). Both work by scraping Google. SerpAPI is subscription-priced, which fits badly with BYOK
pay-as-you-go, and its legal cover starts at plans well above what a solo founder would buy.

## 6. No-key options — tested, and not viable

- **DuckDuckGo HTML.** First request from a clean IP with a browser user-agent: HTTP 200, but the body was the
  bot challenge (`anomaly.js … cc=botnet`, `challenge-form`) with **zero** result links. Without a user-agent:
  HTTP 202. DuckDuckGo's Terms and Acceptable Use Policy contain no clause on automated access that I could
  find, so this is not clearly *disallowed* — it is simply blocked, and there is no API or contract to rely on.
  The "Instant Answer" API is not web search. A research product whose search silently returns nothing is
  worse than one that says search is off.
- **SearXNG.** `searx.be/search?format=json` returned HTTP 200 with a "Verifying your browser…" page, not JSON.
  The SearXNG docs show `html` as the only default format, so most public instances refuse JSON anyway. A
  self-hosted instance works, but it is a meta-scraper of Google/Bing/DDG against those engines' terms, it gets
  rate-limited upstream, and it turns "install Sprat" into "install Sprat and run a container". Reasonable as
  an undocumented power-user setting (`[search] provider = "searxng"`, `url = …`); not a V1 default.

## 7. Recommendation for V1

**Build one `web_search` tool whose backend is the OpenAI Responses API `web_search` tool, called as a
separate sub-request in the strict-JSON "search proxy" shape of §3.2. Keep `[search] provider` in config as the
switch the spec already has, and add Tavily as the second backend only if result quality disappoints in the
Phase 0/2 eval.**

Reasoning:

1. **It passes the Phase 0 test.** Queries and consulted URLs are both visible in the response, and results
   arrive as structured JSON that code can check against the `sources` list. Evidence in §3.
2. **No second key.** Spec §7's stated reason for preferring provider-side search was "V1 needs no second API
   key". That survives the move from Anthropic to OpenAI: the user's one key does search too, and `sprat
   doctor` has one credential to check.
3. **It doesn't disturb the model adapter.** The hosted tool is rejected on `/chat/completions` (§3.3), but
   nothing requires Sprat's main loop to move. `web_search` stays an ordinary function tool in the loop; its
   `call/2` makes one `POST /v1/responses` with `Req`. One new module, no migration of `Sprat.Model.OpenAI`.
4. **The weakness doesn't touch the evidence chain.** Model-written snippets and missing dates would be
   disqualifying if search results *were* the evidence. They aren't: a candidate becomes a source only after
   `web_fetch` retrieves, snapshots and hashes it. Publisher and publication date should come from the fetched
   page, which is more trustworthy than any search API's estimate.
5. **Cost is immaterial at mission scale.** ≈ $0.26 per 20-search mission on luna against a $5 default budget.
   Brave ($0.10) and Tavily ($0.16) are cheaper, and free under 1,000 searches/month, but the saving is cents
   and costs a signup, a key, and for Brave a terms problem.

Why not the others as default: `gpt-5-search-api` is on the right endpoint but hides queries and sources and
costs more; Brave's terms conflict with storing candidates; Tavily is the best *results* API here and the
right fallback, but it is a second key; SerpAPI is a subscription; no-key scraping is blocked.

Mission cost under the realistic options (20 searches; add the common fetch-token cost from §2):

| Backend | Search cost / mission | At 50 missions / month |
|---|---|---|
| OpenAI Responses sub-call, gpt-5.6-luna | ≈ $0.26 | ≈ $13 |
| OpenAI Responses sub-call, gpt-5.6-terra | ≈ $0.85 | ≈ $43 |
| OpenAI `gpt-5-search-api` | ≈ $0.42–0.63 | ≈ $21–31 |
| Tavily basic | $0.16 | $0 (inside 1,000 free credits) |
| Brave | $0.10 | $0 (inside $5 monthly credit) |
| Exa | $0.14 | ≈ $0 (inside $10 monthly credit) |

Pin the search sub-call to the cheapest capable model regardless of the Researcher's own model — the terra row
is there to show what happens if it isn't.

## 8. How it fits Sprat's design

**Tool.** `Sprat.Agent.Tools.WebSearch`, same `Sprat.Agent.Tool` behaviour as `web_fetch`. Arguments: `query`
(required), optional `allowed_domains`, `recency`. Returns `%{"provider", "query", "results" => [%{"url",
"title", "snippet", "published", "snippet_origin"}]}`. `snippet_origin` is `"model_summary"` for the OpenAI
backend and `"search_engine"` for an API backend, and the tool description tells the Researcher that a
model-summary snippet is a lead, never a quotable fact. A backend is one function, `search(query, opts) ->
{:ok, results, usage} | {:error, kind}`; no behaviour module until there is a second backend.

**Guards in the OpenAI backend.** `tool_choice:"required"`, `max_tool_calls:1` (bounds the fee),
`store:false`, strict JSON schema, low `search_context_size`. Drop any result whose URL is not in
`web_search_call.action.sources`. Strip `utm_source=openai` before anything is stored or compared. Surface
`web_search_call.action.queries` in the event log, since the model may rewrite the query it was given.

**Candidate sources.** Each result is written as a candidate (URL, title, query, provider, retrieved-at), not
as a §6 source. It is promoted by the existing path: `web_fetch` → `blob_hash` → `record_source`. `/sources`
should show only promoted records; candidates are an audit trail of "what search offered". If the backend is
ever Brave, persist the URL only.

**§9 fetch rule.** `web_fetch` already takes `context.auto_fetch_urls` and `Sprat.Mission` already builds that
set from grants and user-supplied URLs. Search result URLs join the same set, so they are fetched without
asking; a URL the model composed still prompts. Only URLs that passed the `sources` membership check go in —
otherwise a model-invented URL inside the JSON would launder itself past the approval prompt. With the OpenAI
backend that check is the whole guarantee, so it needs a test.

**Usage ledger (§12).** `Sprat.Store.Usage` already has `server_tool_counts`. The OpenAI sub-call is a real
model call, so it gets its own usage record: tokens from the Responses `usage` block (note the field names are
`input_tokens`/`output_tokens`, not chat-completions' `prompt_tokens`/`completion_tokens`),
`server_tool_counts: {"searches": n}` where n is the number of `web_search_call` items, and cost = tokens +
n × per-search fee. The fee belongs in the versioned pricing file (`priv/models/openai.json`, e.g. a top-level
`"tools": {"web_search": {"per_call": "0.01"}}`) so it is dated and user-overridable like token prices. For an
API backend, write a record with null tokens, the search count, and the per-query price; Exa's `costDollars`
could be recorded as `reported`, the rest are `estimated`.

**Budget (§12).** Worst case for the pre-call check: fee + `max_output_tokens` at output price + an input
allowance. Input is the awkward part, because search content tokens aren't known in advance; measured range
was 8k–17k, and the documented ceiling is 128k. Reserve a fixed allowance (say 20k tokens) rather than the
ceiling, and say in `/usage` that search cost is estimated until the call returns.

**Honest labelling (§7, §16).** Three states, decided at mission start and shown in the header
(`search: on | off`): backend configured and a `sprat doctor` probe succeeded → on; no backend, or probe
failed → off, the `web_search` tool is not offered to the model at all, outputs carry "no live research", and
no candidates are created; backend fails mid-mission → the tool returns a typed error (`search_unavailable`,
`rate_limited`, `budget_exhausted`) with the same "this is not proof nothing exists" note `web_fetch` uses, and
the limitations section of the memo records that search failed part-way. An empty result list must be
distinguishable from a failure; this is what rules out DDG scraping, where a bot wall looks like zero results.

## 9. Open questions for the owner

1. **Second key or not?** The recommendation assumes "no second key" still outranks result quality. If you
   would rather have engine-written snippets and real dates from day one, Tavily is the pick and the OpenAI
   backend becomes the no-setup fallback.
2. **Is a model-written snippet acceptable as a lead?** It never enters the evidence store, but it does steer
   which pages get fetched. The eval set can measure this: compare sources found per mission, OpenAI vs Tavily.
3. **Which model runs the search sub-call?** I tested gpt-5.6-luna only. It should be pinned in config
   (`[search] model = …`) and excluded from the per-role model choice.
4. **Brave's storage clause.** Worth offering Brave as a user-selected backend with URL-only persistence, or
   leave it out of V1 entirely?
5. **Candidates table or events only?** Candidates could live purely in the event log instead of a new table.
   Needs a look at what `/sources` and the Inspector's Evidence tab are meant to show.
6. **Migrating the main adapter to the Responses API.** Not needed for search. It would let the model search
   and open pages natively inside its own turn, at the price of rewriting streaming, tool-call assembly and
   usage normalisation, and of losing the per-search control point. I'd leave it alone; flagging it because
   OpenAI's docs now steer everything new towards Responses.
7. **Spec wording.** §7 still says "Anthropic's server-side web search", §13's config lists
   `anthropic | brave | tavily`, and the `/usage` sample shows `anthropic-2026-09-01`. Whatever is chosen, those
   lines need updating.
8. **OpenAI's terms on storing returned URLs and titles** were not checked. Low risk, but unconfirmed.

## 10. Sources

All fetched 2026-09-20. Pages were read through a summarising fetch tool, so quoted numbers are as that tool
reported them; the OpenAI behaviour in §3 is from direct API calls and does not depend on it.

- OpenAI web search guide — https://developers.openai.com/api/docs/guides/tools-web-search (redirected from platform.openai.com/docs/guides/tools-web-search)
- OpenAI pricing — https://developers.openai.com/api/docs/pricing
- OpenAI deprecations — https://developers.openai.com/api/docs/deprecations
- OpenAI live API: `GET /v1/models`, `POST /v1/responses`, `POST /v1/chat/completions` (owner's key)
- Brave Search API plans — https://brave.com/search/api/
- Brave Search API terms — https://api-dashboard.search.brave.com/terms-of-service
- Brave web search docs — https://api-dashboard.search.brave.com/app/documentation/web-search/get-started and …/web-search/responses
- Tavily credits and pricing — https://docs.tavily.com/documentation/api-credits
- Tavily search endpoint — https://docs.tavily.com/documentation/api-reference/endpoint/search
- Tavily rate limits — https://docs.tavily.com/documentation/rate-limits
- Tavily terms — https://www.tavily.com/terms
- Exa pricing — https://exa.ai/pricing
- Exa search reference — https://exa.ai/docs/reference/search
- Exa rate limits — https://exa.ai/docs/reference/rate-limits
- SerpAPI pricing — https://serpapi.com/pricing
- Serper — https://serper.dev/
- Perplexity pricing — https://docs.perplexity.ai/getting-started/pricing
- Perplexity Search API reference — https://docs.perplexity.ai/api-reference/search-post
- DuckDuckGo terms — https://duckduckgo.com/terms and https://duckduckgo.com/acceptable-use
- DuckDuckGo HTML endpoint, live probe — https://html.duckduckgo.com/html/?q=elixir+latest+release
- SearXNG search settings — https://docs.searxng.org/admin/settings/settings_search.html
- SearXNG public instance, live probe — https://searx.be/search?q=elixir&format=json

Sprat files read: `lib/sprat/model/openai.ex`, `lib/sprat/agent/tool.ex`, `lib/sprat/agent/tools/web_fetch.ex`,
`lib/sprat/agent/tools/record_source.ex`, `lib/sprat/mission.ex`, `lib/sprat/store/usage.ex`,
`priv/models/openai.json`, `docs/spec-v1.md` §6, §7, §9, §12, §13, `docs/phase0/02-search-metadata-codex.md`.
