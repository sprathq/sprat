defmodule Sprat.Steering do
  @moduledoc """
  Mid-mission steering (docs/spec-v1.md §10: "User steering is persisted
  immediately, marks relevant artifacts stale when scope changes, and
  reaches agents at supported safe boundaries" — never built before this
  module).

  `Sprat.Session.Commands.handle_plain/3` calls `queue/4` the moment a
  plain message arrives while its mission is busy (`Sprat.Orchestrator`
  or `Sprat.Mission` running a turn) instead of refusing it. Three things
  happen in the one transaction that persists it:

    1. the message itself is durably recorded (`Sprat.Store.SteeringMessages`)
    2. every artifact this mission has already written is flagged stale
       (`Sprat.Store.Artifacts.mark_stale_in_conn/3` — see its own
       moduledoc for how far that's allowed to reach)
    3. a `steering.queued` event is appended (§11)

  `Sprat.Agent.Loop`'s `steering_fetch` hook calls `take_pending/3` once
  at the top of every turn (its own moduledoc, and its "safe boundary" —
  between model turns, exactly where §10 asks for it): whatever is still
  queued is delivered together, in the order it arrived, folded into that
  turn's request as a clearly-marked instruction that outranks the
  stage's own plan, and flipped to delivered.

  `context_section/3` is the other delivery path: a *new* stage's context
  package (`Sprat.Orchestrator.build_stage_context/5`) is itself a safe
  boundary, so it delivers anything still queued right there too, then
  renders the mission's *entire* steering history (queued-just-now and
  everything delivered earlier in this mission) — carrying a scope change
  forward into every later stage instead of it evaporating when the stage
  that received it ends. `Sprat.Mission`'s single-stage quick path has no
  "next stage" and relies on `take_pending/3` alone.
  """

  alias Sprat.Store.{Artifacts, Events, SteeringMessages}

  @doc """
  Persists a steering message for `mission_id` and marks this mission's
  existing artifacts stale. Never refuses — a busy mission is exactly
  when this is called instead of `Sprat.Mission.start/3`/
  `Sprat.Orchestrator.start/5`'s own "still running" refusal.
  """
  def queue(store \\ Sprat.Store, session_id, mission_id, text) do
    Sprat.Store.transact(store, fn conn ->
      message = SteeringMessages.enqueue_in_conn(conn, session_id, mission_id, text)

      stale_types =
        Artifacts.mark_stale_in_conn(conn, mission_id, "user steering: #{truncate(text)}")

      Events.append_in_conn(conn, session_id, "steering.queued", %{
        mission_id: mission_id,
        payload: %{"text" => text, "stale_artifact_types" => stale_types}
      })

      message
    end)
  end

  @doc """
  Delivers every currently-queued steering message for `mission_id`:
  flips each to delivered, appends a `steering.delivered` event per
  message, and returns their texts oldest-first (delivery order). `[]`
  (a plain, cheap no-op) when nothing is queued — safe to call on every
  turn.
  """
  def take_pending(store \\ Sprat.Store, session_id, mission_id) do
    case SteeringMessages.pending(store, mission_id) do
      [] ->
        []

      rows ->
        Sprat.Store.transact(store, fn conn ->
          Enum.each(rows, fn row ->
            SteeringMessages.mark_delivered_in_conn(conn, row.id)

            Events.append_in_conn(conn, session_id, "steering.delivered", %{
              mission_id: mission_id,
              payload: %{"text" => row.text, "steering_id" => row.id}
            })
          end)
        end)

        Enum.map(rows, & &1.text)
    end
  end

  @doc """
  A context-package section carrying this mission's whole steering
  history forward into a new stage (docs/spec-v1.md §10 — see moduledoc).
  Delivers anything still queued as a side effect (a new stage's context
  build is itself a safe boundary), then renders every message this
  mission has ever received, oldest first. `""` when the mission has
  never received one, so it drops out of `build_stage_context/5`'s
  `Enum.reject(&(&1 == ""))` the same as an empty inputs/sources section.
  """
  def context_section(store \\ Sprat.Store, session_id, mission_id) do
    _delivered_now = take_pending(store, session_id, mission_id)

    case SteeringMessages.by_mission(store, mission_id) do
      [] ->
        ""

      messages ->
        lines = Enum.map(messages, &"- #{&1.text}")

        "User steering received during this mission (outranks any earlier stage's own " <>
          "plan — still applies; artifacts written before it may be marked stale in " <>
          "/artifacts):\n" <> Enum.join(lines, "\n")
    end
  end

  @doc "The clearly-marked instruction folded into a turn's request when `take_pending/3` delivers one or more messages — shared by `Sprat.Agent.Loop`'s `steering_fetch` injection so the wording is defined once."
  def turn_note(texts) do
    lines = Enum.map(texts, &"- #{&1}")

    "USER STEERING — just arrived, outranks this stage's own plan; read and follow it " <>
      "immediately:\n" <> Enum.join(lines, "\n")
  end

  @max_reason_chars 120
  defp truncate(text) when byte_size(text) > @max_reason_chars,
    do: String.slice(text, 0, @max_reason_chars) <> "…"

  defp truncate(text), do: text
end
