defmodule Sprat.Model.Replay do
  @moduledoc """
  A `Sprat.Model` implementation that serves a real mission's recorded
  model exchanges, in order, instead of calling out to a live provider —
  the offline replay harness's model seam. Everything else in a replayed
  run is real: `Sprat.Orchestrator`, `Sprat.Agent.Loop`, every gate,
  `Sprat.Workflow.ArtifactSchema`, and `Sprat.Store` all run exactly as
  they would against `Sprat.Model.OpenAI` — only the HTTP call this
  module's `stream/2` would otherwise make is replaced.

  Wired in exactly where `Sprat.StubModel` is (see its moduledoc and
  `test/support/stub_model.ex`'s `model_mod:`/`model_id:` opts on
  `Sprat.Orchestrator.start/5`): `load/2` populates a named script, keyed
  by `model_id`, and this module is passed as `model_mod:`.

  Fixtures come from `mix sprat.fixtures.export` (`Mix.Tasks.Sprat.Fixtures.Export`):
  `test/fixtures/missions/<mission_id>/exchanges.json`, an ordered array
  of `%{"request" => ..., "response" => ...}` pairs pulled straight from a
  real mission's `model.request`/`model.response` events.

  ## What "diverges from the recording" means here

  This module does NOT compare message text — the whole point of fixing
  the defect class is that stage prompts change (schema-generated shape
  descriptions get added to them), so a replayed run's request messages
  are expected to differ from the live run's recorded ones. What it does
  check, on every `stream/2` call:

    * **exhaustion** — more model turns requested than were recorded for
      this fixture. Returns `{:error, {:replay_exhausted, detail}}`
      instead of crashing (`Sprat.StubModel`'s bare `raise` on the same
      situation is fine for hand-written test scripts sized to exactly
      match a scenario; a fixture pulled from a real run has no such
      guarantee once the code under test starts behaving differently).
    * **structural drift** — the number of messages in the request this
      call is being asked to answer no longer matches the number recorded
      at the same turn index. Message *count* is a proxy for tool-call
      *sequence*: each turn appends exactly one assistant message plus one
      tool-result message per tool call answered, so a count mismatch
      means the live and replayed runs took a different number of tool
      calls somewhere before this point — the loop, not just the prompt
      wording, diverged. Returns `{:error, {:replay_diverged, detail}}`.

  Neither check proves the FIX changes real model behaviour — only that
  it changes validator/prompt/stall behaviour against a fixed recording of
  past model behaviour (see the build brief's "what remains unproven
  offline").
  """

  @behaviour Sprat.Model

  @doc """
  Loads `test/fixtures/missions/<mission_id>/exchanges.json` and starts a
  named script for `model_id` (distinct from `mission_id` on purpose — a
  test picks its own `model_id`, matching every other script-loader in
  `Sprat.StubModel`). Returns `{:ok, meta}` where `meta` is the fixture's
  `meta.json` (mission id/objective/status), or `{:error, :enoent}`.
  """
  def load(mission_id, model_id, fixtures_root \\ "test/fixtures/missions") do
    dir = Path.join(fixtures_root, mission_id)
    exchanges_path = Path.join(dir, "exchanges.json")
    meta_path = Path.join(dir, "meta.json")

    with {:ok, exchanges_json} <- File.read(exchanges_path),
         {:ok, exchanges} <- JSON.decode(exchanges_json),
         {:ok, meta} <- read_meta(meta_path) do
      load_turns(model_id, exchanges)
      {:ok, meta}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a script for `model_id` directly from already-built `turns`
  (each `%{"request" => ..., "response" => ...}`, in `exchanges.json`'s
  own shape) instead of a fixture file — for a hand-written,
  `Sprat.StubModel`-style continuation (see `Sprat.ReplayOrchestratorTest`'s
  synthesized-mission test) rather than a real recording. Same script
  registry as `load/3`, so `stream/2` and `extend/2` work identically
  either way.
  """
  def load_turns(model_id, turns) do
    state = %{
      remaining: turns,
      total: length(turns),
      turn: 0,
      network_results: index_network_results(turns)
    }

    {:ok, _} = Agent.start_link(fn -> state end, name: script_name(model_id))
    :ok
  end

  # Builds a lookup of what the model actually saw, offline, for the two
  # network-calling tools (`web_fetch`/`web_search`) — from the SAME
  # recorded exchanges, no separate export needed: a tool call's own
  # `arguments` (the URL/query, off `response.tool_calls`) is matched to
  # the eventual `role: "tool"` message carrying its `tool_call_id` in
  # some LATER turn's recorded `request.messages` — the exact content
  # `Sprat.Agent.Loop.tool_result_message/2` built from that tool's real
  # `{:ok, result} | {:error, reason}` return the day this mission ran.
  # `lookup/3` serves this back so a replayed run sees the SAME mix of
  # successful/failed fetches the live run did (needed for `Sprat.Orchestrator`'s
  # stall detector to behave the same way), with zero live network egress
  # — see `Sprat.Agent.Tools.WebFetch`/`WebSearch`'s `network_disabled` guard.
  defp index_network_results(exchanges) do
    calls =
      exchanges
      |> Enum.flat_map(fn %{"response" => response} -> response["tool_calls"] || [] end)
      |> Enum.filter(&(&1["name"] in ["web_fetch", "web_search"]))
      |> Map.new(fn tc -> {tc["id"], {tc["name"], call_key(tc)}} end)

    exchanges
    |> Enum.flat_map(fn %{"request" => request} -> (request && request["messages"]) || [] end)
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Enum.reduce(%{}, fn message, acc ->
      case Map.get(calls, message["tool_call_id"]) do
        {tool, key} when not is_nil(key) ->
          Map.put(acc, {tool, key}, decode_tool_content(message["content"]))

        _ ->
          acc
      end
    end)
  end

  defp call_key(%{"name" => "web_fetch", "arguments" => %{"url" => url}}), do: url
  defp call_key(%{"name" => "web_search", "arguments" => %{"query" => query}}), do: query
  defp call_key(_), do: nil

  defp decode_tool_content(content) when is_binary(content) do
    case JSON.decode(content) do
      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, result} ->
        {:ok, result}

      {:error, _} ->
        {:error,
         %{"kind" => "replay_decode_error", "message" => "unparseable recorded tool content"}}
    end
  end

  defp decode_tool_content(_), do: :not_found

  @doc """
  The recorded result for a `web_fetch` call to `url` during this
  mission's original run, or `:not_found` if this exact URL was never
  fetched in the recording. Pass as `context[:replay_fetch_lookup]`
  (a 1-arity function) alongside `context[:network_disabled]`.
  """
  def fetch_result(model_id, url), do: lookup(model_id, "web_fetch", url)

  @doc "Same as `fetch_result/2`, for a `web_search` call's query."
  def search_result(model_id, query), do: lookup(model_id, "web_search", query)

  defp lookup(model_id, tool, key) do
    Agent.get(script_name(model_id), fn state ->
      Map.get(state.network_results, {tool, key}, :not_found)
    end)
  end

  defp read_meta(path) do
    case File.read(path) do
      {:ok, json} -> JSON.decode(json)
      {:error, _} -> {:ok, %{}}
    end
  end

  @doc "Extends an already-`load/3`-ed `model_id`'s script with more turns (for a synthesized continuation past what a fixture recorded — see `Sprat.ReplayMissionsTest`)."
  def extend(model_id, extra_turns) do
    Agent.update(script_name(model_id), fn state ->
      %{
        state
        | remaining: state.remaining ++ extra_turns,
          total: state.total + length(extra_turns)
      }
    end)
  end

  @impl true
  def capabilities(_model_id), do: {:ok, %{}}

  @impl true
  def complete(_request, _opts), do: {:error, :not_implemented}

  @impl true
  def stream(request, opts) do
    on_delta = Keyword.get(opts, :on_delta, fn _ -> :ok end)

    case pop(request.model) do
      {:ok, turn, turn_index} ->
        case check_divergence(request, turn, turn_index) do
          :ok ->
            response = decode_response(turn["response"])

            if is_binary(response.content),
              do: on_delta.(%{type: :content, text: response.content})

            {:ok, response}

          {:error, _} = error ->
            error
        end

      {:exhausted, recorded_turns} ->
        {:error,
         {:replay_exhausted,
          %{
            model_id: request.model,
            turn_requested: recorded_turns + 1,
            recorded_turns: recorded_turns
          }}}
    end
  end

  defp pop(model_id) do
    Agent.get_and_update(script_name(model_id), fn
      %{remaining: [next | rest], turn: turn} = state ->
        {{:ok, next, turn}, %{state | remaining: rest, turn: turn + 1}}

      %{remaining: [], total: total} = state ->
        {{:exhausted, total}, state}
    end)
  end

  # See moduledoc: message COUNT, not content, is the divergence signal —
  # the recorded request at this same turn index is `turn["request"]`.
  defp check_divergence(_request, %{"request" => nil}, _turn_index), do: :ok

  defp check_divergence(request, %{"request" => recorded_request}, turn_index) do
    expected = length(recorded_request["messages"])
    actual = length(request.messages)

    if expected == actual do
      :ok
    else
      {:error,
       {:replay_diverged,
        %{
          model_id: request.model,
          turn: turn_index,
          expected_message_count: expected,
          actual_message_count: actual
        }}}
    end
  end

  defp decode_response(response) do
    %{
      content: response["content"],
      tool_calls: Enum.map(response["tool_calls"] || [], &decode_tool_call/1),
      stop_reason: String.to_existing_atom(response["stop_reason"]),
      usage: response["usage"] || %{},
      raw: %{}
    }
  end

  defp decode_tool_call(tc),
    do: %{id: tc["id"], name: tc["name"], arguments: tc["arguments"] || %{}}

  # No real usage figures are recorded on the `model.response` event
  # itself (only derived, already-normalized cost lands in
  # `usage_records` — see `Sprat.Agent.Loop.record_usage/3`), so this is
  # a fixed small approximation, exactly like `Sprat.StubModel`'s — not a
  # real financial replay of what the live run actually cost.
  @impl true
  def normalize_usage(_raw, context) do
    %{
      provider: "replay",
      model: context.model,
      raw_payload: %{},
      normalization_version: 1,
      input_tokens: 10,
      output_tokens: 5,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      cost: Decimal.new("0.0010"),
      pricing_version: "replay-fixture",
      coverage: if(Map.get(context, :interrupted?, false), do: "estimated", else: "reported")
    }
  end

  defp script_name(model_id), do: :"replay_model_#{model_id}"
end
