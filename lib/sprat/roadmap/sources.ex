defmodule Sprat.Roadmap.Sources do
  @moduledoc """
  Finds a project's roadmap sources (spec-v4 §5.1), in order of authority.

  The globs are a list of `{kind, glob}` relative to the project root and can
  be replaced with `globs:` (the per-project list `/settings` edits). Within
  one glob, files come newest first. Paths are returned relative to the root.
  """

  @type kind :: :sprat | :pause | :plan | :spec
  @type source :: %{kind: kind(), path: String.t(), mtime: DateTime.t()}

  @default_globs [
    sprat: ".sprat/roadmap.md",
    pause: "docs/PAUSE.md",
    plan: "docs/superpowers/plans/*.md",
    plan: "docs/plans/*.md",
    plan: "PLAN.md",
    plan: "TODO.md",
    plan: "ROADMAP.md",
    spec: "docs/spec*.md"
  ]

  @doc "The default `{kind, glob}` list."
  @spec default_globs() :: [{kind(), String.t()}]
  def default_globs, do: @default_globs

  @spec discover(Path.t(), keyword()) :: [source()]
  def discover(root, opts \\ []) do
    globs = Keyword.get(opts, :globs, @default_globs)

    globs
    |> Enum.flat_map(fn {kind, glob} ->
      root
      |> Path.join(glob)
      |> Path.wildcard()
      |> Enum.flat_map(fn abs ->
        case File.stat(abs, time: :posix) do
          {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
            [%{kind: kind, path: Path.relative_to(abs, root), mtime: DateTime.from_unix!(mtime)}]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.mtime), &1.path}, :desc)
    end)
    |> Enum.uniq_by(& &1.path)
  end
end
