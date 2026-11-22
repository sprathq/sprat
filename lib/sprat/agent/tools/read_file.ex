defmodule Sprat.Agent.Tools.ReadFile do
  @moduledoc "`read_file` tool wrapper over `Sprat.Agent.Tools.Files` (docs/spec-v1.md §9)."
  @behaviour Sprat.Agent.Tool
  alias Sprat.Agent.Tools.Files

  @impl true
  def name, do: "read_file"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "read_file",
        "description" =>
          "Read a file's contents. Path is relative to the attached repository root.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      }
    }
  end

  @impl true
  def call(%{"path" => path}, %{root: root}) do
    case Files.read_file(root, path) do
      {:ok, content} -> {:ok, %{"content" => content}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def call(_args, _context), do: {:error, "expected {\"path\": \"...\"}"}
end
