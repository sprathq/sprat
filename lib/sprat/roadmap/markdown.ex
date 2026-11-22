defmodule Sprat.Roadmap.Markdown do
  @moduledoc """
  Line-level Markdown helpers shared by the roadmap parsers. Pure.

  Nothing here builds a tree: the roadmap parsers only need headings, list
  items and checkboxes, each with its 1-based line number, and to know which
  lines sit inside a code fence.
  """

  @type line :: %{n: pos_integer(), text: String.t(), fence?: boolean()}

  @doc "Splits text into numbered lines, marking those inside (or opening/closing) a code fence."
  @spec lines(String.t()) :: [line()]
  def lines(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.map_reduce(nil, fn {line, n}, fence ->
      case fence_marker(line) do
        nil ->
          {%{n: n, text: line, fence?: fence != nil}, fence}

        marker when fence == nil ->
          {%{n: n, text: line, fence?: true}, marker}

        marker ->
          if String.starts_with?(marker, fence),
            do: {%{n: n, text: line, fence?: true}, nil},
            else: {%{n: n, text: line, fence?: true}, fence}
      end
    end)
    |> elem(0)
  end

  defp fence_marker(line) do
    case Regex.run(~r/^\s{0,3}(`{3,}|~{3,})/, line) do
      [_, marker] -> marker
      _ -> nil
    end
  end

  @doc "`{level, text}` for an ATX heading, else nil."
  @spec heading(String.t()) :: {pos_integer(), String.t()} | nil
  def heading(line) do
    case Regex.run(~r/^(\#{1,6})\s+(.*?)\s*#*\s*$/, line) do
      [_, hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  @doc "`{indent, checked?, text}` for a checkbox list item (`- [ ]`, `* [x]`, `1. [ ]`), else nil."
  @spec checkbox(String.t()) :: {non_neg_integer(), boolean(), String.t()} | nil
  def checkbox(line) do
    case Regex.run(~r/^(\s*)(?:[-*+]|\d+[.)])\s+\[([ xX])\]\s*(.*)$/, line) do
      [_, indent, mark, text] -> {indent_width(indent), mark in ["x", "X"], text}
      _ -> nil
    end
  end

  @doc "`{indent, number, text}` for a numbered list item, else nil."
  @spec numbered(String.t()) :: {non_neg_integer(), pos_integer(), String.t()} | nil
  def numbered(line) do
    case Regex.run(~r/^(\s*)(\d+)[.)]\s+(.*)$/, line) do
      [_, indent, n, text] -> {indent_width(indent), String.to_integer(n), text}
      _ -> nil
    end
  end

  @doc "`{indent, text}` for a bullet list item (`-`, `*`, `+`), else nil."
  @spec bullet(String.t()) :: {non_neg_integer(), String.t()} | nil
  def bullet(line) do
    case Regex.run(~r/^(\s*)[-*+]\s+(.*)$/, line) do
      [_, indent, text] -> {indent_width(indent), text}
      _ -> nil
    end
  end

  defp indent_width(indent), do: indent |> String.replace("\t", "    ") |> String.length()

  @doc "Strips inline Markdown (bold, italics, links, code ticks) and collapses whitespace."
  @spec clean(String.t()) :: String.t()
  def clean(text) do
    text
    |> String.replace(~r/<!--.*?-->/, "")
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\*\*|__/, "")
    |> String.replace(~r/(?<![\w*])\*(?!\s)([^*]+?)\*(?!\w)/, "\\1")
    |> String.replace("`", "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  A short label for an item: the cleaned text's first sentence, at most
  `max` characters (cut at a word, with an ellipsis).
  """
  @spec short(String.t(), pos_integer()) :: String.t()
  def short(text, max \\ 120) do
    cleaned = clean(text)

    first =
      case Regex.split(~r/(?<=[.!?:])\s+(?=[A-Z(*`"])/, cleaned, parts: 2) do
        [one | _] -> one
        [] -> cleaned
      end

    first = String.trim_trailing(first, ":")
    truncate(first, max)
  end

  @doc "Truncates at a word boundary, adding an ellipsis when cut."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max) do
    if String.length(text) <= max do
      text
    else
      cut = String.slice(text, 0, max)

      cut =
        case Regex.run(~r/^(.*)\s\S*$/, cut) do
          [_, head] when byte_size(head) > 0 -> head
          _ -> cut
        end

      String.trim_trailing(cut, " ,;:-—") <> "…"
    end
  end

  @months ~w(jan feb mar apr may jun jul aug sep oct nov dec)

  @doc "The first date in the text: ISO `2026-09-13`, `9 Nov 2026` or `Nov 9, 2026`."
  @spec find_date(String.t()) :: Date.t() | nil
  def find_date(text) do
    [
      &iso_date/1,
      &dmy_date/1,
      &mdy_date/1
    ]
    |> Enum.flat_map(fn f -> List.wrap(f.(text)) end)
    |> Enum.min_by(fn {idx, _} -> idx end, fn -> nil end)
    |> case do
      nil -> nil
      {_, date} -> date
    end
  end

  @doc "Every date in the text (same forms as `find_date/1`)."
  @spec all_dates(String.t()) :: [Date.t()]
  def all_dates(text) do
    iso =
      Regex.scan(~r/\b(\d{4})-(\d{2})-(\d{2})\b/, text)
      |> Enum.map(fn [_, y, m, d] -> mk_date(y, m, d) end)

    dmy =
      Regex.scan(~r/\b(\d{1,2})\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{4})\b/, text)
      |> Enum.map(fn [_, d, mon, y] -> mk_date(y, month(mon), d) end)

    Enum.reject(iso ++ dmy, &is_nil/1)
  end

  defp iso_date(text) do
    case Regex.run(~r/\b(\d{4})-(\d{2})-(\d{2})\b/, text, return: :index) do
      [{idx, _}, y, m, d] -> wrap(idx, mk_date(part(text, y), part(text, m), part(text, d)))
      _ -> nil
    end
  end

  defp dmy_date(text) do
    case Regex.run(~r/\b(\d{1,2})\s+([A-Za-z]{3})[a-z]*\.?,?\s+(\d{4})\b/, text, return: :index) do
      [{idx, _}, d, mon, y] ->
        wrap(idx, mk_date(part(text, y), month(part(text, mon)), part(text, d)))

      _ ->
        nil
    end
  end

  defp mdy_date(text) do
    case Regex.run(~r/\b([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b/, text, return: :index) do
      [{idx, _}, mon, d, y] ->
        wrap(idx, mk_date(part(text, y), month(part(text, mon)), part(text, d)))

      _ ->
        nil
    end
  end

  defp part(text, {start, len}), do: binary_part(text, start, len)
  defp wrap(_idx, nil), do: nil
  defp wrap(idx, date), do: {idx, date}

  defp month(name) do
    case Enum.find_index(@months, &(&1 == String.downcase(name))) do
      nil -> nil
      i -> i + 1
    end
  end

  defp mk_date(_y, nil, _d), do: nil

  defp mk_date(y, m, d) do
    with {y, ""} <- to_int(y),
         {m, ""} <- to_int(m),
         {d, ""} <- to_int(d),
         {:ok, date} <- Date.new(y, m, d) do
      date
    else
      _ -> nil
    end
  end

  defp to_int(v) when is_integer(v), do: {v, ""}
  defp to_int(v), do: Integer.parse(v)

  @doc "Quoted commit messages in a block of text (`git commit -m \"…\"`, `Commit with \"…\"`)."
  @spec commit_messages(String.t()) :: [String.t()]
  def commit_messages(text) do
    a = Regex.scan(~r/git commit[^\n"]*?-[a-z]*m\s+"([^"\n]{4,})"/, text)
    b = Regex.scan(~r/\b[Cc]ommit\b[*\s:—–`\-]*(?:with\s+|message\s+)?`?"([^"\n]{4,})"/u, text)
    c = Regex.scan(~r/git commit[^\n']*?-[a-z]*m\s+'([^'\n]{4,})'/, text)

    d = Regex.scan(~r/\b[Cc]ommit\b[*\s:—–\-]*(?:with\s+)?`(?!git )([^`\n"]{4,})`/u, text)

    (a ++ b ++ c ++ d)
    |> Enum.map(fn [_, msg] -> String.trim(msg) end)
    |> Enum.uniq()
  end
end
