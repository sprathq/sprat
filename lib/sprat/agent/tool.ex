defmodule Sprat.Agent.Tool do
  @moduledoc """
  Behaviour every tool the agent loop can call implements (docs/spec-v1.md
  §9). `call/2` returns:

    * `{:ok, result}` — result is JSON-encodable, becomes the tool message
      content sent back to the model
    * `{:error, reason}` — also sent back to the model (as an error string),
      so it can recover, not raised
    * `{:needs_approval, request}` — the tool refuses to act until the
      session layer (owned by another part of Sprat) resolves `request`;
      `Sprat.Agent.Loop` surfaces this as data/an event rather than
      blocking or prompting itself (§9 fetch rule)
  """

  @callback name() :: String.t()
  @callback spec() :: map()
  @callback call(args :: map(), context :: map()) ::
              {:ok, term()} | {:error, term()} | {:needs_approval, map()}
end
