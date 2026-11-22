defmodule Sprat.Attachments do
  @moduledoc """
  `@`-attach (docs/spec-v1.md §6/§10): the user's own files as evidence.
  Turns a `@<path>` mention in a composer submission into a
  `source_type: "user_provided"` source record — content hashed and
  blob-stored exactly like a fetched page (`Sprat.Store.Blob`,
  `Sprat.Store.Sources`) — plus a readable, format-appropriate rendering
  of its content for the model. PDFs, images and other binaries are
  detected and refused outright rather than fed to the model as bytes.

  Resolution reuses `Sprat.Agent.Tools.Files`' sandbox
  (`safe_path_for/2`): an in-root path needs no approval (attaching is
  the user's own explicit act, §10); a path that resolves outside the
  project root is reported as `{:confirm, real}` instead of silently
  read — the caller (`Sprat.Session.Commands`) confirms it once via
  `Sprat.Session.await_permission/2`, the same mechanism the §9 fetch
  rule uses.

  This module does no session/mission I/O beyond `Blob`/`Sources` writes
  — the transcript block, the confirm prompt, and threading the result
  into a mission's context package all stay in the caller.
  """

  alias Sprat.Agent.Tools.{Files, TextCap}
  alias Sprat.Store.{Blob, Paths, Sources}

  @max_tokens 8_000
  @max_csv_rows 500
  @unsupported_extensions ~w(.pdf .png .jpg .jpeg .gif .webp .bmp .tiff .ico .heic .heif
                              .mp3 .wav .mp4 .mov .avi .zip .tar .gz .doc .docx .ppt .pptx
                              .xls .xlsx)

  @doc """
  `@`-mention tokens in `text`: the raw string after each `@`, up to the
  next whitespace. Not checked against the filesystem here — a `@`
  followed by something that isn't a real path (an email address typed
  in prose, say) simply fails to resolve later (`resolve/2`) and is left
  as plain text, never an error.
  """
  def mentions(text) do
    ~r/@([^\s@][^\s]*)/u
    |> Regex.scan(text)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  @doc """
  Resolves `raw_path` against `root` (the session's project path).

    * `{:ok, real, :in_root}` — read without asking.
    * `{:confirm, real}` — outside `root`; confirm once before reading.
    * `{:error, :not_found}` — no such file (not a real mention; ignore quietly).
    * `{:error, :denied}` — matched a deny pattern (`.env*`, keys, ...).
    * `{:error, reason}` — anything else.
  """
  def resolve(root, raw_path) do
    candidate =
      if Path.type(raw_path) == :absolute, do: raw_path, else: Path.join(root, raw_path)

    case Files.safe_path_for(root, candidate) do
      # `safe_path_for/2` (like `read_file`'s own `safe_path/2`) resolves a
      # path that doesn't exist yet to its literal joined form rather than
      # erroring — by design, so a real sandbox violation isn't confused
      # with a plain typo. A `@`-mention needs that distinction itself: a
      # non-existent path is exactly the "not a real attachment, quietly
      # ignore it" case `mentions/1`'s moduledoc promises for stray `@`s
      # in prose (an email address, ...).
      {:ok, real, :in_root} ->
        if File.regular?(real), do: {:ok, real, :in_root}, else: not_found()

      {:ok, real, :outside_root} ->
        if File.regular?(real), do: {:confirm, real}, else: not_found()

      {:error, :denied_pattern} ->
        {:error, :denied}

      {:error, :enoent} ->
        not_found()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp not_found, do: {:error, :not_found}

  @doc """
  Reads, formats, hashes and blob-stores `real_path` (already resolved by
  `resolve/2`). Returns `{:ok, attachment}` (a map with `:path`, `:url`,
  `:title`, `:blob_hash`, `:text`, `:kind`, `:row_count`, `:truncated?`)
  or `{:error, reason}` — `{:unsupported, extension}` for a PDF/image/
  other binary, or a `File.posix` reason.
  """
  def attach(root, real_path, secrets, blob_root) do
    with {:ok, raw} <- File.read(real_path),
         {:ok, formatted} <- format_bytes(real_path, raw) do
      {:ok, blob_hash} = Blob.put(raw, secrets, blob_root)
      rel = display_path(root, real_path)

      {:ok,
       %{
         path: rel,
         url: "file://" <> rel,
         title: Path.basename(real_path),
         blob_hash: blob_hash,
         text: formatted.text,
         kind: formatted.kind,
         row_count: formatted.row_count,
         truncated?: formatted.truncated?
       }}
    end
  end

  @doc "Records an already-`attach/4`ed attachment as a `user_provided` source for `mission_id`."
  def record_source(store, mission_id, attachment) do
    Sources.record(store, mission_id, %{
      url: attachment.url,
      title: attachment.title,
      source_type: "user_provided",
      content_hash: attachment.blob_hash,
      snapshot_blob_hash: attachment.blob_hash
    })
  end

  @doc """
  The content block `Sprat.Mission`/`Sprat.Orchestrator`'s own
  `sources_section/1` appends after a `user_provided` source's title/url
  line — re-derived from the stored blob every time a context package is
  built, so a follow-up turn always sees the same file's content without
  a second stored copy of it.
  """
  def content_block(source, blob_root \\ Paths.blobs_dir())

  def content_block(
        %{source_type: "user_provided", snapshot_blob_hash: hash, url: url},
        blob_root
      )
      when is_binary(hash) do
    with {:ok, raw} <- Blob.get(hash, blob_root),
         path = String.trim_leading(url, "file://"),
         {:ok, formatted} <- format_bytes(path, raw) do
      "\n  [Attached file content]\n  " <> String.replace(formatted.text, "\n", "\n  ")
    else
      _ -> ""
    end
  end

  def content_block(_source, _blob_root), do: ""

  # -- reading/formatting -----------------------------------------------------

  defp format_bytes(path, raw) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      File.dir?(path) -> {:error, :is_a_directory}
      ext in @unsupported_extensions -> {:error, {:unsupported, ext}}
      binary?(raw) -> {:error, {:unsupported, ext}}
      true -> {:ok, format(ext, raw)}
    end
  end

  defp binary?(bytes),
    do: String.contains?(binary_part(bytes, 0, min(byte_size(bytes), 1024)), <<0>>)

  defp format(".csv", raw) do
    {table, row_count, dropped_rows} = csv_table(raw)
    {text, truncated?, dropped_chars} = TextCap.cap(table, @max_tokens)
    text = csv_notes(text, truncated?, dropped_chars, dropped_rows, row_count)
    %{text: text, kind: :csv, row_count: row_count, truncated?: truncated? or dropped_rows > 0}
  end

  defp format(".json", raw) do
    note =
      case JSON.decode(raw) do
        {:ok, _} -> ""
        {:error, _} -> "\n\n[warning: this file's contents did not parse as valid JSON.]"
      end

    {text, truncated?, dropped_chars} = TextCap.cap(raw, @max_tokens)

    text =
      if truncated?,
        do: text <> TextCap.truncation_notice(dropped_chars, @max_tokens, subject: "JSON file"),
        else: text

    %{text: text <> note, kind: :json, row_count: nil, truncated?: truncated?}
  end

  defp format(_ext, raw) do
    {text, truncated?, dropped_chars} = TextCap.cap(raw, @max_tokens)

    text =
      if truncated?,
        do: text <> TextCap.truncation_notice(dropped_chars, @max_tokens, subject: "file"),
        else: text

    %{text: text, kind: :text, row_count: nil, truncated?: truncated?}
  end

  defp csv_table(raw) do
    rows =
      raw
      |> String.trim_trailing("\n")
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&split_csv_line/1)

    {header, data} =
      case rows do
        [h | rest] -> {h, rest}
        [] -> {[], []}
      end

    row_count = length(data)
    kept_data = Enum.take(data, @max_csv_rows)
    dropped_rows = row_count - length(kept_data)

    {render_table(header, kept_data), row_count, dropped_rows}
  end

  # ponytail: naive comma-split, no quoted-field/embedded-comma support —
  # covers the common "readable table" case the spec asks for. A real CSV
  # parser (RFC 4180 quoting) would need a new dependency this build has
  # no strong justification for yet; add one if a real deny/quoting case
  # shows up.
  defp split_csv_line(line), do: line |> String.split(",") |> Enum.map(&String.trim/1)

  defp render_table([], []), do: "(empty CSV)"

  defp render_table(header, data) do
    header_line = "| " <> Enum.join(header, " | ") <> " |"
    sep_line = "| " <> Enum.map_join(header, " | ", fn _ -> "---" end) <> " |"
    data_lines = Enum.map(data, fn row -> "| " <> Enum.join(row, " | ") <> " |" end)
    Enum.join([header_line, sep_line | data_lines], "\n")
  end

  defp csv_notes(text, true, dropped_chars, _dropped_rows, _row_count),
    do: text <> TextCap.truncation_notice(dropped_chars, @max_tokens, subject: "CSV table")

  defp csv_notes(text, false, _dropped_chars, dropped_rows, row_count) when dropped_rows > 0,
    do:
      text <>
        "\n\n[…truncated: #{dropped_rows} of #{row_count} rows dropped (row cap #{@max_csv_rows}).]"

  defp csv_notes(text, false, _dropped_chars, 0, _row_count), do: text

  defp display_path(root, real_path) do
    case Files.safe_path_for(root, real_path) do
      {:ok, _, :in_root} -> Path.relative_to(real_path, root)
      _ -> real_path
    end
  end
end
