defmodule Sprat.Agent.Tools.Grep do
  @moduledoc "`grep` tool wrapper over `Sprat.Agent.Tools.Files` (docs/spec-v1.md §9)."
  @behaviour Sprat.Agent.Tool
  alias Sprat.Agent.Tools.Files

  @impl true
  def name, do: "grep"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "grep",
        "description" =>
          "Search file contents under the attached repository root for a regular expression.",
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
    case Files.grep(root, pattern) do
      {:ok, matches} -> {:ok, %{"matches" => matches}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"pattern\": \"...\"}"}
end
