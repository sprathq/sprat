defmodule Sprat.Session.Render do
  @moduledoc """
  The one place a `Sprat.Session.Block` becomes `Sprat.Terminal.Transcript`
  lines. This is the whole adaptation boundary docs/spec-v1.md §13 asks
  for ("The UI subscribes to the Projection... The domain never calls the
  renderer"): `Sprat.Session` never imports this module or
  `Sprat.Terminal.*`; only `Sprat.Session.Subscriber` does, at the point it
  is about to hand lines to `Sprat.Terminal.Renderer.commit/2`. Every
  clause here reuses an existing `Sprat.Terminal.Transcript` formatter —
  nothing is rendered twice.
  """

  alias Sprat.Terminal.{Transcript, Width}

  @doc "A block map (see `Sprat.Session.Block`) -> already-wrapped lines ready for `Renderer.commit/2`."
  def to_lines(block, width, opts \\ [])

  # `queued?: true` (docs/spec-v1.md §10 "The queued message is shown
  # dimmed until delivered") comes from the block itself, not the
  # renderer's own `opts` — `Sprat.Session.Commands.handle_plain/3` sets
  # it the moment a plain message is accepted as mid-mission steering
  # instead of refused. Committed blocks are written once and never
  # redrawn (§10 "Committed region"), so this dims the message bubble at
  # commit time rather than un-dimming it later; the queued/delivered
  # distinction stays visible for the rest of the run via the system note
  # `handle_plain/3` adds right after it and the Events tab (§11).
  def to_lines(%{kind: :user_message, text: text} = block, _width, opts) do
    dim? = Map.get(block, :queued?, false) or Keyword.get(opts, :dim?, false)
    Transcript.user_message(text, Keyword.put(opts, :dim?, dim?))
  end

  def to_lines(%{kind: :agent_message, role: role, markdown: markdown}, width, opts) do
    Transcript.agent_message(role, markdown, width, opts)
  end

  def to_lines(%{kind: :tool_call, role: role, summary: summary}, _width, opts) do
    Transcript.tool_call(role, summary, opts)
  end

  def to_lines(%{kind: :tool_result, text: text}, width, opts) do
    Transcript.tool_result(text, width, opts)
  end

  def to_lines(%{kind: :stage_change, name: name, reason: reason}, _width, opts) do
    Transcript.stage_change(name, reason, opts)
  end

  def to_lines(
        %{kind: :artifact_written, role: role, artifact: artifact, version: version, path: path},
        _width,
        opts
      ) do
    Transcript.artifact_written(role, artifact, version, path, opts)
  end

  def to_lines(%{kind: :error, message: message, suggestion: suggestion}, _width, opts) do
    Transcript.error_block(message, suggestion, opts)
  end

  def to_lines(%{kind: :gate_result} = block, _width, opts) do
    Transcript.gate_result(Map.fetch!(block, :ok?), Map.get(block, :detail), opts)
  end

  # Informational blocks with no dedicated §10 row (slash-command output,
  # recovery outcomes, honest empty-state notices) — plain wrapped text,
  # no header, matching how the mockup renders indented follow-up lines.
  def to_lines(%{kind: :system, text: text}, width, _opts) do
    text |> String.split("\n") |> Enum.flat_map(&Width.wrap(&1, width))
  end

  @doc "Renders many blocks and joins them, for the batched replay commit (§16: no per-block flush)."
  def batch_to_lines(blocks, width, opts \\ []) do
    Enum.flat_map(blocks, &to_lines(&1, width, opts))
  end
end
