defmodule Sprat.Agent.Tools.WebFetch do
  @moduledoc """
  `web_fetch` tool (docs/spec-v1.md §9 fetch rule): "URLs that came from
  search results, from the user, or from an already-fetched page's links
  on the same site are fetched without asking. Any other URL ... requires
  user approval in the TUI."

  `context` carries the trust state built up so far in the task:

      %{
        auto_fetch_urls: MapSet.t(String.t()),   # exact URLs: user-supplied, grants
        auto_fetch_hosts: MapSet.t(String.t()),  # hosts already fetched (same-site links from them are automatic)
        mission_id: String.t()                   # also checked against Sprat.Agent.Tools.WebSearch's
                                                   # mission-scoped auto-fetch set (search results)
      }

  This module never decides the approval prompt itself — that's the
  session layer's job (§9, "Do not build UI"). When a URL isn't
  auto-approved, `call/2` returns `{:needs_approval, %{url:, reason:}}`
  without making any network request; the agent loop turns that into an
  event/prompt request and, only once approved, calls again (the session
  layer is expected to add the approved URL to `auto_fetch_urls` before
  retrying — approval is a decision made once per URL, not re-asked).

  ## Cost fix (a real run: $0.152 for one fetch)

  A single fetch of https://elixir-lang.org used to push the *entire* raw
  HTML page — 75,972 input tokens — into the model. `call/2` now:

    1. stores the full, untouched response body in the content-addressed
       blob store (`context[:store]`/`context[:secrets]`, so evidence
       keeps a complete snapshot even though the model never sees it all)
    2. runs it through `Sprat.Agent.Tools.HtmlExtract` to drop
       script/style/nav/header/footer/svg/comment noise
    3. caps what reaches the model at `@default_max_tokens` (≈4 chars per
       token, the same estimate `Sprat.Agent.Loop` uses elsewhere),
       truncated at a line boundary with an explicit notice of how much
       was dropped — never a silent cut

  Non-text content types (PDF, images, binaries) are refused outright
  rather than fed to the model as garbled bytes.

  ## Distinguishable failures (a real run: "the domain does not appear to
  exist" for a domain that exists)

  A model composed `https://www.rierty.co.uk/` (a typo of the real
  `rielty.co.uk`), the DNS lookup failed, and the model told the user the
  *domain* didn't exist — a network error, an approval refusal, a 404 and
  an unsupported content type all used to come back as the same flat
  `"fetch failed: ..."` string, so the model had nothing to distinguish
  "I couldn't reach this" from "this doesn't exist". Every error below now
  carries a `"kind"` the model can act on
  (`network_error`/`not_found`/`http_error`/`unsupported_content_type`/
  `too_large`), each paired with an explicit note that the failure is not
  proof the site or domain doesn't exist.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Agent.Tools.{HtmlExtract, TextCap, WebSearch}
  alias Sprat.Store.Blob

  @impl true
  def name, do: "web_fetch"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "web_fetch",
        "description" => "Fetch a URL and return its readable text (extracted, token-capped).",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"url" => %{"type" => "string"}},
          "required" => ["url"]
        }
      }
    }
  end

  @default_max_tokens 8_000
  # Defends memory/disk against a pathological non-HTML-looking response
  # that still claims an allowed content-type; ordinary pages are nowhere
  # near this.
  @max_raw_bytes 10_000_000
  @allowed_content_types ~w(text/html text/plain application/xhtml+xml)

  @impl true
  def call(%{"url" => url}, context) do
    cond do
      # Offline replay's structural zero-network guard (see
      # `Sprat.Model.Replay`'s moduledoc): `Sprat.Orchestrator` sets this
      # from `opts[:network_disabled]` when a caller wants a hard
      # guarantee no fetch ever leaves the machine — checked before the
      # approval decision, so a replayed run never even shows a fetch
      # prompt for a URL that could never actually be reached.
      Map.get(context, :network_disabled, false) ->
        network_disabled_result(context, :replay_fetch_lookup, url, "#{url} was not fetched")

      auto_approved?(url, context) ->
        fetch(url, context)

      true ->
        {:needs_approval, %{url: url, reason: approval_reason(url, context)}}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"url\": \"...\"}"}

  @doc "Whether `url` may be fetched without a prompt, per the §9 fetch rule."
  def auto_approved?(url, context) do
    auto_urls = Map.get(context, :auto_fetch_urls, MapSet.new())
    auto_hosts = Map.get(context, :auto_fetch_hosts, MapSet.new())
    # URLs `web_search` surfaced for this mission (provenance-checked
    # against `web_search_call.action.sources` — see
    # Sprat.Agent.Tools.WebSearch) are fetched without asking too, same as
    # a URL the user typed: §9's fetch rule lists both in the same
    # sentence.
    search_urls = WebSearch.auto_fetch_urls(Map.get(context, :mission_id))

    MapSet.member?(auto_urls, url) or MapSet.member?(search_urls, url) or
      (host(url) != nil and MapSet.member?(auto_hosts, host(url)))
  end

  defp approval_reason(url, context) do
    case host(url) do
      nil ->
        :unparseable_url

      h ->
        if Map.get(context, :any_fetch_yet?, false),
          do: {:composed_url, h},
          else: {:first_fetch_not_pre_approved, h}
    end
  end

  # `context[:replay_fetch_lookup]`, when present, is a 1-arity function
  # (`url -> {:ok, term} | {:error, term} | :not_found`) — the offline
  # replay harness's way of serving back exactly what a real fetch
  # returned the day a mission actually ran, with zero network egress
  # (see `Sprat.Model.Replay.fetch_result/2`). No lookup, or a miss,
  # falls back to a plain "disabled" error.
  defp network_disabled_result(context, lookup_key, key, not_fetched_message) do
    case Map.get(context, lookup_key) do
      lookup when is_function(lookup, 1) ->
        case lookup.(key) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            {:error, reason}

          :not_found ->
            {:error, %{"kind" => "network_disabled", "message" => not_fetched_message}}
        end

      _ ->
        {:error, %{"kind" => "network_disabled", "message" => not_fetched_message}}
    end
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  # A live staged mission sat on one URL for four minutes: `receive_timeout`
  # bounds the wait for the next chunk, not the whole request, so a slow drip
  # or a stuck connect outlives it. Every fetch gets a hard overall deadline.
  @fetch_deadline_ms 30_000

  defp fetch(url, context) do
    req_opts = Map.get(context, :req_opts, [])
    normalized_url = ensure_scheme(url)

    task =
      Task.async(fn ->
        Req.run(
          Req.new(
            [
              url: normalized_url,
              receive_timeout: 15_000,
              connect_options: [timeout: 10_000]
            ] ++ req_opts
          )
        )
      end)

    case Task.yield(task, @fetch_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {req, result}} ->
        handle_fetch_result(req, result, normalized_url, context)

      nil ->
        tool_error(
          :network_error,
          "timed out after #{div(@fetch_deadline_ms, 1000)}s fetching #{normalized_url} — the server never finished responding. This is not proof the page is missing."
        )

      {:exit, reason} ->
        tool_error(:network_error, "fetch of #{normalized_url} failed: #{inspect(reason)}")
    end
  end

  defp handle_fetch_result(req, result, normalized_url, context) do
    case result do
      %Req.Response{status: status} = resp when status in 200..299 ->
        handle_response(req.url |> URI.to_string(), status, resp, context)

      %Req.Response{status: 404} ->
        tool_error(
          :not_found,
          "HTTP 404 — this page was not found at #{normalized_url}. " <>
            "The site itself may still exist; check the path, or try the domain root."
        )

      %Req.Response{status: status} ->
        tool_error(
          :http_error,
          "the server responded with HTTP #{status} for #{normalized_url}. " <>
            "The domain resolved and answered — this is not evidence it doesn't exist."
        )

      exception when is_exception(exception) ->
        tool_error(
          :network_error,
          "could not connect to #{normalized_url} (#{Exception.message(exception)}). " <>
            "This is a connection/DNS failure, not proof the domain doesn't exist — it may be " <>
            "down, blocking automated requests, behind a redirect this tool didn't follow, or " <>
            "the URL may be misspelled. Double-check the exact spelling before telling the user " <>
            "the site doesn't exist."
        )

      other ->
        tool_error(:network_error, "fetch failed: #{inspect(other)}")
    end
  end

  # A model-composed URL missing a scheme (e.g. "rielty.co.uk") would
  # otherwise fail as a network error that reads exactly like a dead
  # domain; adding `https://` is what a browser's address bar does too.
  defp ensure_scheme(url) do
    if String.match?(url, ~r{^https?://}i), do: url, else: "https://" <> url
  end

  defp tool_error(kind, message), do: {:error, %{"kind" => to_string(kind), "message" => message}}

  defp handle_response(final_url, status, resp, context) do
    content_type = content_type(resp)
    body = to_bytes(resp.body)

    cond do
      not allowed_content_type?(content_type) ->
        tool_error(
          :unsupported_content_type,
          "the page exists and responded, but its content type is " <>
            "#{content_type || "unknown"}: web_fetch only reads text/HTML content, not PDFs, " <>
            "images or other binaries. This is not evidence the site doesn't exist."
        )

      byte_size(body) > @max_raw_bytes ->
        tool_error(
          :too_large,
          "refusing to fetch: response is #{byte_size(body)} bytes, over the safety cap. " <>
            "The site exists and responded."
        )

      true ->
        {:ok, build_result(final_url, status, content_type, body, context)}
    end
  end

  defp build_result(final_url, status, content_type, body, context) do
    {:ok, blob_hash} = Blob.put(body, secrets(context), blob_root(context))

    extracted = HtmlExtract.text(body)
    max_tokens = Map.get(context, :max_extract_tokens, @default_max_tokens)
    {text, truncated?, dropped_chars} = cap(extracted, max_tokens)

    %{
      "url" => final_url,
      "status" => status,
      "content_type" => content_type,
      "original_size_bytes" => byte_size(body),
      "extracted_size_bytes" => byte_size(extracted),
      "truncated" => truncated?,
      "text" =>
        if(truncated?, do: text <> truncation_notice(dropped_chars, max_tokens), else: text),
      "blob_hash" => blob_hash
    }
  end

  defp cap(text, max_tokens), do: TextCap.cap(text, max_tokens)

  defp truncation_notice(dropped_chars, max_tokens) do
    TextCap.truncation_notice(dropped_chars, max_tokens,
      kept_note: "The full page is stored as evidence (record_source), not lost."
    )
  end

  defp allowed_content_type?(nil), do: true

  defp allowed_content_type?(content_type) do
    base = content_type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    base in @allowed_content_types or String.starts_with?(base, "text/")
  end

  defp content_type(resp) do
    case Req.Response.get_header(resp, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp secrets(context), do: Map.get(context, :secrets) || Sprat.Secrets.redaction_set()
  defp blob_root(context), do: Map.get(context, :blob_root) || Sprat.Store.Paths.blobs_dir()

  defp to_bytes(body) when is_binary(body), do: body
  defp to_bytes(body), do: JSON.encode!(body)
end
