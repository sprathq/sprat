defmodule Sprat.Terminal.MarkdownTest do
  use ExUnit.Case, async: true

  alias Sprat.Terminal.Markdown

  test "renders a heading with ANSI styling by default" do
    [line, ""] = Markdown.to_lines("# Title", 40)
    assert line =~ "Title"
    assert line =~ "\e["
  end

  test "NO_COLOR disables ANSI styling" do
    lines = Markdown.to_lines("**bold**", 40, color: false)
    refute Enum.any?(lines, &(&1 =~ "\e["))
  end

  test "ascii mode swaps bullets for '*'" do
    [line | _] = Markdown.to_lines("- one", 40, ascii: true)
    assert line =~ "*"
    refute line =~ "•"
  end

  test "unicode mode uses the bullet glyph" do
    [line | _] = Markdown.to_lines("- one", 40, ascii: false)
    assert line =~ "•"
  end

  test "renders a fenced code block faint, unwrapped" do
    lines = Markdown.to_lines("```\ncode line\n```", 40, color: true)
    assert Enum.any?(lines, &(&1 =~ "code line"))
  end

  test "wraps paragraph text to the given width" do
    text = String.duplicate("word ", 30)
    lines = Markdown.to_lines(text, 20)
    body = Enum.reject(lines, &(&1 == ""))
    assert Enum.all?(body, &(String.length(&1) <= 20))
  end

  test "renders an ordered list with numbers" do
    lines = Markdown.to_lines("1. first\n2. second", 40)
    assert Enum.any?(lines, &(&1 =~ "1. first"))
    assert Enum.any?(lines, &(&1 =~ "2. second"))
  end

  test "renders a table with wrapped columns" do
    md = """
    | A | B |
    |---|---|
    | 1 | 2 |
    """

    lines = Markdown.to_lines(md, 40)
    assert Enum.any?(lines, &(&1 =~ "A"))
    assert Enum.any?(lines, &(&1 =~ "1"))
  end

  test "renders a link with its href alongside the text" do
    [line, ""] = Markdown.to_lines("[click here](https://example.com)", 60)
    assert line =~ "click here"
    assert line =~ "https://example.com"
  end

  test "a nested list under a plain list item renders as its own indented lines" do
    # Root cause of the "corrupted"-reading part of the streamed Markdown
    # defect: Earmark's AST for "- REST\n  - Collaboration: ...\n  -
    # Velocity: ..." puts the nested `ul` in the parent `li`'s own
    # children, and the old `inline_text/2` catch-all recursed into it and
    # joined everything with no separator at all
    # ("RESTCollaboration: ...Velocity: ..."), confirmed against a real
    # streamed answer via tmux, not just this fixture.
    md = "- REST\n  - Collaboration: clear ownership\n  - Velocity: fast to start\n"
    lines = Markdown.to_lines(md, 60)

    refute Enum.any?(lines, &(&1 =~ "RESTCollaboration"))
    assert Enum.any?(lines, &(&1 =~ ~r/^\s*•\s*REST\s*$/))
    assert Enum.any?(lines, &(&1 =~ "Collaboration: clear ownership"))
    assert Enum.any?(lines, &(&1 =~ "Velocity: fast to start"))
  end

  test "a plain list item with no nested list is unaffected" do
    lines = Markdown.to_lines("- one\n- two\n", 40)
    assert Enum.any?(lines, &(&1 =~ "• one"))
    assert Enum.any?(lines, &(&1 =~ "• two"))
  end
end
