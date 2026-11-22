defmodule Sprat.Model do
  @moduledoc """
  Behaviour a model adapter implements (docs/spec-v1.md §7 shape, §13
  "written behind a `Sprat.Model` behaviour so [other providers] can be
  added ... without touching orchestration"). `Sprat.Agent.Loop` talks
  only to this contract, never to a provider's HTTP shape directly.

  A `request` is a plain map: `%{model:, messages:, tools:, max_tokens:}`.
  `messages` are `%{role:, content:}` (content a string, or a list for
  tool results — see the adapter for the exact shape it accepts).

  `complete/2` and `stream/2` both return `{:ok, response}` or
  `{:error, reason}`. A `response` is:

      %{
        content: String.t() | nil,
        tool_calls: [%{id:, name:, arguments: map()}],
        stop_reason: :stop | :tool_calls | :length | :content_filter | :refusal | :cancelled,
        usage: raw usage map, provider shape, for normalize_usage/2,
        raw: the full raw response/aggregated stream, for the event log
      }

  `stream/2` additionally takes `opts[:on_delta]`, a 1-arity fun called
  with `%{type: :content, text:}` or `%{type: :tool_call, index:, id:, name:, arguments_fragment:}`
  for every chunk, and `opts[:cancel?]`, a 0-arity fun polled between
  chunks — returning `true` closes the connection and `stream/2` returns
  `{:ok, %{response | stop_reason: :cancelled}}` with whatever usage the
  server had already sent (coverage `estimated`, decided by the caller via
  `normalize_usage/2`'s `interrupted:` flag, not by the adapter).
  """

  @type request :: map()
  @type response :: map()

  @callback capabilities(model_id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback complete(request(), opts :: keyword()) :: {:ok, response()} | {:error, term()}
  @callback stream(request(), opts :: keyword()) :: {:ok, response()} | {:error, term()}

  @doc """
  Normalises a provider's raw usage payload into the attrs
  `Sprat.Store.Usage.record/2` expects (input/output/cache tokens, cost,
  coverage, pricing_version). `context` carries whatever the normaliser
  needs beyond the raw payload: at minimum `%{model:, interrupted?:}`.
  """
  @callback normalize_usage(raw :: map(), context :: map()) :: map()
end
