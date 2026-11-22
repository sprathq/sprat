defmodule Sprat.Terminal.Zones.ConversationTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Zones.Conversation
  import Sprat.Test.CellText, only: [rows_to_text: 1]

  @widths [{120, 40}, {100, 30}, {80, 24}, {60, 20}]

  test "render/4 always returns exactly rect.h rows of exactly rect.w cells" do
    state = Conversation.init([]) |> Conversation.append(["> hello", "⏺ PM  some reply"])

    for {w, h} <- @widths do
      rows = Conversation.render(state, %{x: 0, y: 0, w: w, h: h}, false, 0)
      assert length(rows) == h
      assert Enum.all?(rows, &(length(&1) == w))
    end
  end

  test "appended lines (already-rendered Markdown/Transcript output) are shown verbatim" do
    state = Conversation.init([]) |> Conversation.append(["a-distinctive-token"])
    text = Conversation.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()
    assert text =~ "a-distinctive-token"
  end

  # Bug: a brand-new real session showed an entirely empty Conversation
  # zone with no hint what to do. The hint must show only while nothing
  # has ever landed, disappear the moment it does, and never be written
  # into the actual scrollback (so it can't leak into the stored
  # transcript, an export, or `mix test` replay).
  test "a first-run hint is shown while the transcript is empty" do
    state = Conversation.init([])
    text = Conversation.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()
    assert text =~ "press Enter to start"
    assert state.scrollback.lines == []
  end

  test "the first-run hint disappears once real content lands, and is never stored" do
    state = Conversation.init([]) |> Conversation.append(["> hello"])
    text = Conversation.render(state, %{x: 0, y: 0, w: 60, h: 10}, false, 0) |> rows_to_text()
    refute text =~ "press Enter to start"
    assert state.scrollback.lines == ["> hello"]
  end

  test "an unhandled key is a no-op, not an error" do
    state = Conversation.init([])
    assert Conversation.handle_key(state, {:char, "z"}) == {state, []}
  end

  # A real run showed an agent answer as
  # "…involves packaging your application and its depende…" — cut mid-word
  # with an ellipsis, not wrapped. Lines committed to this zone must
  # already be wrapped to the zone's own content width (its caller's job —
  # see `Sprat.Session.Subscriber`/`ZonedRenderer.content_width/1`); this
  # proves that once they are, every word survives across multiple full
  # lines instead of being cut.
  test "a long paragraph, wrapped to the zone's content width before commit, renders as multiple full lines with nothing lost" do
    paragraph =
      "Deploying an Elixir application to production typically involves packaging your " <>
        "application and its dependencies into a release, then running that release on the " <>
        "target machine without needing Elixir or Erlang installed there separately."

    rect = %{x: 0, y: 0, w: 40, h: 12}
    # the same width Sprat.Session.Render/Transcript.agent_message would be
    # given for this rect's interior (rect.w - 2 for the zone's border)
    markdown_width = rect.w - 2
    lines = Sprat.Terminal.Transcript.agent_message("Researcher", paragraph, markdown_width)

    state = Conversation.init([]) |> Conversation.append(lines)
    text = Conversation.render(state, rect, false, 0) |> rows_to_text()

    refute text =~ "…"
    refute text =~ "depende…"

    for word <- String.split(paragraph, " ") do
      assert text =~ word, "expected the full word #{inspect(word)} to survive, got:\n#{text}"
    end

    # Word presence alone doesn't catch two words glued together at a wrap
    # boundary ("itsdependencies" still contains "its") — a real tmux
    # capture of this exact paragraph showed "and\nitsdependencies" and
    # "Elixiror Erlang" (a wrapped line's leading word losing the space
    # that should separate it from the next). Check every adjacent pair
    # in the source never appears fused together in the rendered output.
    words = String.split(paragraph, " ")

    for [w1, w2] <- Enum.chunk_every(words, 2, 1, :discard) do
      refute text =~ w1 <> w2,
             "#{inspect(w1)} and #{inspect(w2)} were glued together in:\n#{text}"
    end
  end
end
