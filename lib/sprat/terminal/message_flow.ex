defmodule Sprat.Terminal.MessageFlow do
  @moduledoc """
  Pure: a message-record stream -> gutter animation state and edge-lighting
  (`docs/design/tui-zones.md` "Message passing between agents"). No process,
  no IO — `Zones.Agents`/`Zones.Flow` call these functions with the current
  `Terminal.Animate` frame counter and get back what to draw.

  A `message` is `%{from:, to:, type:, frame:}` — `frame` is the
  `Terminal.Animate` frame the message was admitted at (not wall-clock), so
  every function here is testable by calling it with a fixed frame rather
  than sleeping, per the design's animation rule.
  """

  @glyphs %{
    assignment: "✉",
    clarification: "?",
    evidence: "◆",
    handoff: "⇄",
    review: "✓",
    decision: "⚖",
    status: "·",
    cancel: "✕",
    error: "!"
  }

  # ponytail: hardcoded per the design ("no config knobs for values that
  # never change") — 10fps gutter travel/flash timing and the 2s static
  # hold are fixed properties of the design, not settings.
  # ~400ms travel + ~200ms flash at 10fps.
  @travel_frames 4
  @flash_frames 2
  # ~2s static hold when animation is disabled (design: "the gutter still
  # shows the last message as a static arrow for 2 seconds").
  @static_hold_frames 20
  # ~1s edge-lighting hold in the Flow overlay.
  @edge_lit_frames 10

  @type message :: %{from: term(), to: term(), type: atom(), frame: non_neg_integer()}
  @type burst :: %{
          type: atom(),
          from: term(),
          to: term(),
          count: pos_integer(),
          frame: non_neg_integer()
        }

  @doc "The glyph for a message type, per the design's type table."
  def glyph(type), do: Map.get(@glyphs, type, "?")

  @doc """
  Coalesces consecutive messages sharing `{from, to, type}` into bursts
  (design: "several messages at once ... labelled `✉×3`"), in order.
  `Enum.sum(Enum.map(coalesce(messages), & &1.count)) == length(messages)`
  always — no message is ever lost by coalescing.
  """
  @spec coalesce([message()]) :: [burst()]
  def coalesce(messages) do
    messages
    |> Enum.chunk_by(&{&1.from, &1.to, &1.type})
    |> Enum.map(fn [first | _] = group ->
      %{
        type: first.type,
        from: first.from,
        to: first.to,
        count: length(group),
        frame: List.last(group).frame
      }
    end)
  end

  @doc """
  The gutter's current state for `agent_order` (row ids, in on-screen
  order) at `frame`, or `nil` when there's nothing to show. `animated?`
  false switches to the static ~2s hold instead of the travel/flash
  timing (the design's "animation off" rule) — pass
  `Terminal.Animate.enabled?/1`'s result.

  Returned `sender`/`recipient`/`rows` are always valid indices into
  `agent_order` (`0..length(agent_order)-1`) or the whole thing is `nil` —
  callers never need to clamp.
  """
  @spec gutter([message()], [term()], non_neg_integer(), boolean()) ::
          nil
          | %{
              sender: non_neg_integer(),
              recipient: non_neg_integer(),
              rows: Range.t(),
              phase: :travel | :flash | :static,
              glyph: String.t(),
              label: String.t()
            }
  def gutter(messages, agent_order, frame, animated? \\ true)
  def gutter([], _agent_order, _frame, _animated?), do: nil

  def gutter(messages, agent_order, frame, animated?) do
    last = messages |> coalesce() |> List.last()
    age = frame - last.frame
    hold = if animated?, do: @travel_frames + @flash_frames, else: @static_hold_frames

    with true <- age >= 0 and age <= hold,
         sender when not is_nil(sender) <- Enum.find_index(agent_order, &(&1 == last.from)),
         recipient when not is_nil(recipient) <- Enum.find_index(agent_order, &(&1 == last.to)) do
      phase =
        cond do
          not animated? -> :static
          age < @travel_frames -> :travel
          true -> :flash
        end

      g = glyph(last.type)

      %{
        sender: sender,
        recipient: recipient,
        rows: min(sender, recipient)..max(sender, recipient),
        phase: phase,
        glyph: g,
        label: if(last.count > 1, do: "#{g}×#{last.count}", else: g)
      }
    else
      _ -> nil
    end
  end

  @doc "Per-`{from, to}` edge volumes for the Flow overlay, most-recent-first ordering preserved by `frame`."
  def edges(messages) do
    messages
    |> Enum.group_by(&{&1.from, &1.to})
    |> Enum.map(fn {{from, to}, msgs} ->
      %{
        from: from,
        to: to,
        count: length(msgs),
        last_frame: msgs |> List.last() |> Map.fetch!(:frame)
      }
    end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc "Whether an edge should be shown lit (recent traffic) at `frame` — ~1s hold."
  def edge_lit?(%{last_frame: last_frame}, frame), do: frame - last_frame <= @edge_lit_frames
end
