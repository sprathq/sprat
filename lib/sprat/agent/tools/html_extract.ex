defmodule Sprat.Agent.Tools.HtmlExtract do
  @moduledoc """
  Readable-text extraction for `web_fetch` (docs/spec-v1.md §9 fetch rule
  fix): a real run fetched https://elixir-lang.org and pushed 75,972
  input tokens (the raw HTML — `<script>`, `<nav>`, boilerplate and all)
  into the model for $0.152, against ~150 tokens for a plain question.

  A hand-rolled regex extractor, not a new HTML-parser dependency (mix.exs
  has no `floki`/`meeseeks` and this codebase's ponytail rule is: reuse an
  already-installed dep or stdlib before reaching for a new one). Pages
  are well-formed enough in practice that tag-region regexes are
  sufficient for "drop script/style/nav/header/footer/svg/comments, keep
  headings/paragraphs/lists/link text" — a real parser would handle
  malformed nesting better, but nothing here needs that precision, only a
  token-budget cut.
  """

  @block_open ~r/<(h[1-6]|p|div|li|tr|br|blockquote)\b[^>]*>/i
  @block_close ~r/<\/(h[1-6]|p|div|li|tr|blockquote)>/i

  @doc "Strips script/style/nav/header/footer/svg/comment regions and tags, returns readable plain text."
  def text(html) when is_binary(html) do
    html
    |> drop_regions(~w(script style noscript template svg))
    |> drop_comments()
    |> drop_regions(~w(nav header footer))
    |> linkify()
    |> block_breaks()
    |> strip_tags()
    |> decode_entities()
    |> collapse_whitespace()
  end

  defp drop_regions(html, tags) do
    Enum.reduce(tags, html, fn tag, acc ->
      Regex.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}>/is, acc, "")
    end)
  end

  defp drop_comments(html), do: Regex.replace(~r/<!--.*?-->/s, html, "")

  # `<a href="URL">text</a>` -> `text (URL)`, same convention as
  # `Terminal.Markdown`'s link rendering, before the href's own tag is
  # stripped — only when the href carries information the visible text
  # doesn't already (a bare "#" anchor or href == text adds nothing).
  defp linkify(html) do
    Regex.replace(~r/<a\b[^>]*\bhref="([^"]*)"[^>]*>(.*?)<\/a>/is, html, fn _, href, inner ->
      text = inner |> strip_tags() |> String.trim()

      cond do
        href in ["", "#"] -> text
        href == text -> text
        text == "" -> href
        true -> "#{text} (#{href})"
      end
    end)
  end

  defp block_breaks(html) do
    html
    |> then(&Regex.replace(@block_open, &1, "\n"))
    |> then(&Regex.replace(@block_close, &1, "\n"))
  end

  defp strip_tags(html), do: Regex.replace(~r/<[^>]*>/s, html, "")

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "#39" => "'",
    "nbsp" => " ",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "copy" => "©"
  }

  defp decode_entities(text) do
    text
    |> then(
      &Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, hex ->
        codepoint(String.to_integer(hex, 16))
      end)
    )
    |> then(&Regex.replace(~r/&#(\d+);/, &1, fn _, dec -> codepoint(String.to_integer(dec)) end))
    |> then(fn t ->
      Enum.reduce(@entities, t, fn {name, char}, acc ->
        String.replace(acc, "&#{name};", char)
      end)
    end)
  end

  defp codepoint(n) when n in 0..0x10FFFF, do: <<n::utf8>>
  defp codepoint(_), do: ""

  defp collapse_whitespace(text) do
    text
    |> String.split("\n")
    |> Enum.map(&(&1 |> String.replace(~r/[ \t]+/, " ") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
