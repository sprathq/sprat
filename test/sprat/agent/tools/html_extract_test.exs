defmodule Sprat.Agent.Tools.HtmlExtractTest do
  use ExUnit.Case, async: true

  alias Sprat.Agent.Tools.HtmlExtract

  @fixtures Path.join([__DIR__, "..", "..", "..", "fixtures", "web"])

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  test "drops script and style content entirely" do
    text = HtmlExtract.text(fixture("nav_heavy.html"))
    refute text =~ "dataLayer"
    refute text =~ "gtag"
    refute text =~ "font-family"
    refute text =~ "boilerplate analytics line"
    refute text =~ "var config"
  end

  test "drops nav, header and footer regions but keeps main content" do
    text = HtmlExtract.text(fixture("nav_heavy.html"))

    refute text =~ "Careers"
    refute text =~ "Introduction"
    refute text =~ "Privacy"
    refute text =~ "All rights reserved"

    assert text =~ "Getting started"
    assert text =~ "installing the tool"
    assert text =~ "Step one: install the package."
  end

  test "drops HTML comments" do
    refute HtmlExtract.text(fixture("nav_heavy.html")) =~ "never appear in the extracted"
  end

  test "keeps link text with its href when they differ" do
    text = HtmlExtract.text(fixture("nav_heavy.html"))
    assert text =~ "reference documentation (https://example.com/reference)"
  end

  test "a page that is mostly navigation and script still yields real content and shrinks a lot" do
    html = fixture("nav_heavy.html")
    text = HtmlExtract.text(html)

    assert byte_size(text) < byte_size(html) |> div(2)
    assert text =~ "Getting started"
  end

  test "decodes common HTML entities" do
    assert HtmlExtract.text("<p>Fish &amp; chips &mdash; &copy; 2026</p>") =~
             "Fish & chips — © 2026"
  end

  test "decodes numeric and hex entities" do
    assert HtmlExtract.text("<p>&#65;&#x42;</p>") == "AB"
  end

  test "collapses excess whitespace without losing paragraph breaks" do
    text = HtmlExtract.text("<p>First   paragraph.</p>\n\n\n<p>Second paragraph.</p>")
    assert text == "First paragraph.\nSecond paragraph."
  end
end
