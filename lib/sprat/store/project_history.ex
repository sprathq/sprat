defmodule Sprat.Store.ProjectHistory do
  @moduledoc """
  Composer up/down recall history, persisted per project (docs/spec-v1.md
  §13 storage layout: `projects/<project-hash>/history`). A plain
  append-only file, one submitted line each — not part of the SQLite
  schema since it is a per-project convenience file, not session/event
  data, and the spec places it directly under the data dir keyed by a
  project hash rather than inside `sprat.db`.
  """

  alias Sprat.Store.Paths

  @max_entries 500

  @doc "Path to the history file for `project_path`, keyed by a truncated sha256 of the path."
  def path(project_path) do
    hash =
      :crypto.hash(:sha256, project_path) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    Path.join([Paths.data_dir(), "projects", hash, "history"])
  end

  @doc "Appends one submitted line (newlines flattened to spaces) to the project's history file."
  def append(project_path, text) do
    file = path(project_path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, String.replace(text, "\n", " ") <> "\n", [:append])
    File.chmod!(file, 0o600)
    :ok
  end

  @doc "Most-recent-first list of submitted lines, for `Sprat.Terminal.Composer`'s `history:` option."
  def load(project_path) do
    case File.read(path(project_path)) do
      {:ok, content} ->
        content |> String.split("\n", trim: true) |> Enum.reverse() |> Enum.take(@max_entries)

      {:error, _} ->
        []
    end
  end
end
