defmodule Sprat.Terminal.ThemeTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Theme

  test "every state is distinguishable by glyph+word alone, with colour stripped" do
    pairs =
      Enum.map(Theme.states(), fn s ->
        {Theme.state(s, color: false).glyph, Theme.state(s, color: false).word}
      end)

    assert Enum.uniq(pairs) == pairs
  end

  test "every role is distinguishable by glyph+word alone, with colour stripped" do
    pairs =
      Enum.map(Theme.roles(), fn r ->
        {Theme.role(r, color: false).glyph, Theme.role(r, color: false).word}
      end)

    assert Enum.uniq(pairs) == pairs
  end

  test "color: false yields a nil color but keeps glyph and word" do
    stripped = Theme.state(:blocked, color: false)
    assert stripped.color == nil
    assert stripped.glyph == "!"
    assert stripped.word == "blocked"
  end

  test "ascii: true swaps to ASCII glyphs" do
    assert Theme.state(:done, ascii: true).glyph == "[x]"
    assert Theme.role(:pm, ascii: true).glyph == "o"
  end

  test "a spinner-glyph state reports the :spinner sentinel, resolved by the caller via Animate" do
    assert Theme.state(:running).glyph == :spinner
  end
end
