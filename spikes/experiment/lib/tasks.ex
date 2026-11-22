defmodule Experiment.Tasks do
  @moduledoc "Loads task briefs from tasks/*.md (YAML-ish front matter + a Markdown brief)."

  defstruct [:id, :workflow, :brief_markdown]

  @doc "Load all tasks/*.md from `dir`, sorted by id."
  def load_all(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&load!/1)
    |> Enum.sort_by(& &1.id)
  end

  def load!(path) do
    id = path |> Path.basename(".md") |> String.slice(0, 2)
    content = File.read!(path)

    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, content) do
      [_, front_matter, body] ->
        workflow =
          case Regex.run(~r/workflow:\s*(\w+)/, front_matter) do
            [_, wf] -> String.to_atom(wf)
            nil -> raise "task #{path}: front matter missing `workflow:`"
          end

        %__MODULE__{id: id, workflow: workflow, brief_markdown: String.trim(body)}

      nil ->
        raise "task #{path}: missing --- front matter"
    end
  end
end
