defmodule Sprat.Agent.Tools.RecordClaim do
  @moduledoc """
  `record_claim` tool (docs/spec-v1.md §6, "falls out naturally" alongside
  `record_source`): a claim's confidence and justification, linked to the
  source IDs `record_source` returned that support or contradict it. A
  claim with no supporting source should be recorded with `is_assumption:
  true` rather than left bare — code, not the model, enforces that at the
  research gate in a later build; this tool just makes the honest label
  possible to record.

  Writes through `Sprat.Store.Claims`.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Store.Claims

  @confidences ~w(high medium low)

  @impl true
  def name, do: "record_claim"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "record_claim",
        "description" =>
          "Record a claim your answer makes: its confidence with a one-line justification, " <>
            "and the source IDs (from record_source) that support or contradict it. If no " <>
            "source supports it, set is_assumption: true instead of citing nothing.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "text" => %{"type" => "string"},
            "confidence" => %{"type" => "string", "enum" => @confidences},
            "justification" => %{"type" => "string", "description" => "one sentence"},
            "supporting_source_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "contradicting_source_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
            "is_assumption" => %{"type" => "boolean"}
          },
          "required" => ["text", "confidence"]
        }
      }
    }
  end

  @impl true
  def call(%{"text" => text, "confidence" => confidence} = args, context)
      when is_binary(text) and confidence in @confidences do
    store = Map.get(context, :store)
    mission_id = Map.get(context, :mission_id)

    case {store, mission_id} do
      {nil, _} -> {:error, "no store configured for this task"}
      {_, nil} -> {:error, "no mission_id configured for this task"}
      {store, mission_id} -> record(store, mission_id, text, confidence, args)
    end
  end

  def call(%{"confidence" => bad}, _context) when is_binary(bad),
    do: {:error, "invalid confidence: #{bad} (expected one of #{Enum.join(@confidences, ", ")})"}

  def call(_args, _context), do: {:error, "expected {\"text\": \"...\", \"confidence\": \"...\"}"}

  defp record(store, mission_id, text, confidence, args) do
    source_ids =
      Enum.map(list(args, "supporting_source_ids"), &{&1, :supports}) ++
        Enum.map(list(args, "contradicting_source_ids"), &{&1, :contradicts})

    case Claims.record(
           store,
           mission_id,
           %{
             text: text,
             confidence: confidence,
             justification: Map.get(args, "justification"),
             is_assumption: Map.get(args, "is_assumption", false)
           },
           source_ids
         ) do
      {:ok, claim} ->
        {:ok, %{"claim_id" => claim.id}}

      {:error, _reason} ->
        # Most likely one of `supporting_source_ids`/`contradicting_source_ids`
        # doesn't match a source id this mission actually recorded (a typo,
        # or an id remembered from an earlier, different mission's context —
        # `record_source` ids are not shared across missions).
        {:error,
         "could not record this claim: one of the source ids doesn't exist for this mission " <>
           "— call record_source first, or double-check the id"}
    end
  end

  defp list(args, key) do
    case Map.get(args, key) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
