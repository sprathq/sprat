defmodule Sprat.Agent.Tools.RecordSource do
  @moduledoc """
  `record_source` tool (docs/spec-v1.md §6/§9): the Researcher's only way
  to make a fetched page count as evidence. Before this tool existed,
  nothing wrote to `Sprat.Store.Sources`, so `/sources` and the
  Inspector's Evidence tab stayed empty even after a real fetch — a
  researcher could cite a URL in prose and nothing durable backed it.

  Writes through `Sprat.Store.Sources`, keyed for de-duplication by
  canonical URL within the mission (`context[:store]`/`context[:mission_id]`,
  set by `Sprat.Mission`'s `tool_context`).
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Store.Sources

  @source_types ~w(first_party_marketing independent_reporting documentation
                    customer_testimony forum_or_review user_provided)

  @impl true
  def name, do: "record_source"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "record_source",
        "description" =>
          "Record a source you fetched or were given as evidence (docs/spec-v1.md §6): " <>
            "url, title, publisher, published date, retrieval timestamp, source type and " <>
            "content hash. Call this for every URL a claim in your answer relies on.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "url" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "publisher" => %{"type" => "string"},
            "published_at" => %{
              "type" => "string",
              "description" => "ISO 8601 date, or omit if unknown"
            },
            "source_type" => %{"type" => "string", "enum" => @source_types},
            "content_hash" => %{
              "type" => "string",
              "description" =>
                "the blob_hash a prior web_fetch call returned for this URL, if any"
            }
          },
          "required" => ["url", "source_type"]
        }
      }
    }
  end

  @impl true
  def call(%{"url" => url, "source_type" => source_type} = args, context)
      when is_binary(url) and source_type in @source_types do
    store = Map.get(context, :store)
    mission_id = Map.get(context, :mission_id)

    case {store, mission_id} do
      {nil, _} -> {:error, "no store configured for this task"}
      {_, nil} -> {:error, "no mission_id configured for this task"}
      {store, mission_id} -> record(store, mission_id, url, source_type, args)
    end
  end

  def call(%{"source_type" => bad_type}, _context) when is_binary(bad_type),
    do:
      {:error,
       "invalid source_type: #{bad_type} (expected one of #{Enum.join(@source_types, ", ")})"}

  def call(_args, _context), do: {:error, "expected {\"url\": \"...\", \"source_type\": \"...\"}"}

  defp record(store, mission_id, url, source_type, args) do
    case Sources.record(store, mission_id, %{
           url: url,
           title: Map.get(args, "title"),
           publisher: Map.get(args, "publisher"),
           published_at: Map.get(args, "published_at"),
           source_type: source_type,
           content_hash: Map.get(args, "content_hash")
         }) do
      {:ok, source} -> {:ok, %{"source_id" => source.id, "url" => source.url}}
      {:error, _reason} -> {:error, "could not record this source"}
    end
  end
end
