defmodule Sprat.Store.Blob do
  @moduledoc """
  Content-addressed blob store: `blobs/sha256/ab/<hash>` under the data
  dir (docs/spec-v1.md §15), for large event payloads, fetched pages and
  artifact snapshots that don't belong inline in a SQLite row.

  Every write goes through `Sprat.Store.Redact.scrub/2` first (callers
  pass the secret set in), is written to a temp file and fsynced, then
  atomically renamed into place — so a row can only ever reference a blob
  that is fully and durably on disk (write-before-reference, per §15).
  Permissions are 0600, matching the rest of the data dir.
  """

  alias Sprat.Store.{Paths, Redact}

  @doc """
  Writes `data` (redacted against `secrets` first) content-addressed under
  `root`. Returns `{:ok, hash}`. Idempotent: writing the same bytes twice
  is a no-op the second time.
  """
  def put(data, secrets \\ [], root \\ Paths.blobs_dir()) do
    {scrubbed, _redacted?} = Redact.scrub(data, secrets)
    bytes = to_bytes(scrubbed)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    dest = blob_path(root, hash)

    unless File.exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      tmp = dest <> ".tmp-#{:erlang.unique_integer([:positive])}"
      File.write!(tmp, bytes)
      fsync!(tmp)
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, dest)
    end

    {:ok, hash}
  end

  @doc "Reads a blob by hash. Returns `{:ok, binary}` or `{:error, :not_found}`."
  def get(hash, root \\ Paths.blobs_dir()) do
    case File.read(blob_path(root, hash)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Whether a blob with this hash exists."
  def exists?(hash, root \\ Paths.blobs_dir()), do: File.exists?(blob_path(root, hash))

  @doc """
  Deletes every blob under `root` whose hash is not in `referenced_hashes`
  (the set of `payload_ref`/`blob_hash`/`snapshot_blob_hash` values still
  read from the database by the caller). Returns the count deleted.
  """
  def gc_orphans(referenced_hashes, root \\ Paths.blobs_dir()) do
    referenced = MapSet.new(referenced_hashes)
    orphans = root |> list_hashes() |> Enum.reject(&MapSet.member?(referenced, &1))
    Enum.each(orphans, &File.rm(blob_path(root, &1)))
    length(orphans)
  end

  defp blob_path(root, hash) do
    <<prefix::binary-size(2), _::binary>> = hash
    Path.join([root, prefix, hash])
  end

  defp list_hashes(root) do
    case File.ls(root) do
      {:ok, prefixes} ->
        Enum.flat_map(prefixes, fn prefix ->
          case File.ls(Path.join(root, prefix)) do
            {:ok, files} -> files
            {:error, _} -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp to_bytes(data) when is_binary(data), do: data
  defp to_bytes(data), do: JSON.encode!(data)

  defp fsync!(path) do
    {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary])
    :ok = :file.sync(fd)
    :ok = :file.close(fd)
  end
end
