defmodule Sprat.Agent.Tools.Glob do
  @moduledoc "`glob` tool wrapper over `Sprat.Agent.Tools.Files` (docs/spec-v1.md §9)."
  @behaviour Sprat.Agent.Tool
  alias Sprat.Agent.Tools.Files

  @impl true
  def name, do: "glob"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "glob",
        "description" =>
          "List files under the attached repository root matching a glob pattern (e.g. \"**/*.ex\").",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"pattern" => %{"type" => "string"}},
          "required" => ["pattern"]
        }
      }
    }
  end

  @impl true
  def call(%{"pattern" => pattern}, %{root: root}) do
    case Files.glob(root, pattern) do
      {:ok, paths} -> {:ok, %{"paths" => paths}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"pattern\": \"...\"}"}
end
