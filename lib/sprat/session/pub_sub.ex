defmodule Sprat.Session.PubSub do
  @moduledoc """
  Registry-based pub/sub between a `Sprat.Session` and its UI subscriber
  (docs/spec-v1.md §13: "The UI subscribes to the Projection through
  `Registry`-based pub/sub. The domain never calls the renderer.").
  `Sprat.Session` calls `broadcast/2` and never knows or cares whether
  anything is listening; `Sprat.Session.Subscriber` is the only caller of
  `subscribe/1` in this codebase. Topic key is the session id; registered
  under `:duplicate` keys so more than one subscriber could listen (a
  future `--plain`/verbose secondary view, a test process asserting on
  broadcasts) without `Sprat.Session` needing to know about it.
  """

  @registry __MODULE__.Registry

  @doc "The `Registry` name this module wraps — started once under `Sprat.Application`."
  def registry_name, do: @registry

  @doc "Subscribe the calling process to `session_id`'s broadcasts."
  def subscribe(session_id), do: Registry.register(@registry, session_id, [])

  @doc "Send `message` to every subscriber of `session_id`, as `{:sprat_session, session_id, message}`."
  def broadcast(session_id, message) do
    Registry.dispatch(@registry, session_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:sprat_session, session_id, message})
    end)
  end
end
