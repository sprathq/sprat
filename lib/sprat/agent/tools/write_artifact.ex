defmodule Sprat.Agent.Tools.WriteArtifact do
  @moduledoc """
  `write_artifact` tool (docs/spec-v1.md §5 build brief item 4): the only
  way a stage's agent turn produces a deliverable. Restricted to the
  current stage's declared types via `context[:allowed_artifact_types]`
  (set by `Sprat.Orchestrator` from `Template.Stage.deliverables`, never
  by the model) — "a role may write only its own artifact types" (§9
  tools table), enforced here in code, not by the prompt asking nicely.
  Content is validated against `Sprat.Workflow.ArtifactSchema` before
  anything is stored, so a malformed artifact never reaches the gate as
  something to reject later — it is rejected immediately, with the exact
  missing fields, and the model can retry within the same turn.

  Every rejection returns a structured `{:error, %{"kind" => ..., "message"
  => ...}}` (see `Sprat.Agent.Loop`'s `completion_payload/2`, which reads
  `"kind"`/`"message"` off any tool error and records the rest of the map
  alongside it) instead of a bare string, so the event log — and
  `Sprat.Orchestrator`'s same-type-reject tracking — can tell a schema
  rejection apart from a wrong-stage rejection or a malformed call, and
  name the artifact type without re-parsing the message text.
  """

  @behaviour Sprat.Agent.Tool

  alias Sprat.Store.Artifacts
  alias Sprat.Workflow.{ArtifactSchema, Scorecard}

  @impl true
  def name, do: "write_artifact"

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "write_artifact",
        "description" =>
          "Write (or overwrite with a new version of) one of this stage's deliverable " <>
            "artifacts. Only the types this stage is assigned can be written here.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "type" => %{"type" => "string", "description" => "artifact type, e.g. research_memo"},
            "content" => %{
              "type" => "object",
              "description" => "the artifact's structured content"
            }
          },
          "required" => ["type", "content"]
        }
      }
    }
  end

  @impl true
  def call(%{"type" => type, "content" => content}, context)
      when is_binary(type) and is_map(content) do
    allowed = Map.get(context, :allowed_artifact_types, MapSet.new())

    cond do
      not MapSet.member?(allowed, type) ->
        {:error,
         %{
           "kind" => "not_a_deliverable",
           "artifact_type" => type,
           "message" =>
             "#{type} is not a deliverable of this stage (allowed: " <>
               "#{Enum.join(MapSet.to_list(allowed), ", ")})"
         }}

      true ->
        write(type, content, context)
    end
  end

  # A live run sent `content` as a bare list (the array a single-field
  # artifact's own field would have held) instead of `%{field => [...]}`
  # (mis_NtCpr_KXm0Ki, mis_xR7oKZnpA0Rb both did this for `source_register`).
  # When the target type's schema has exactly one top-level field, that's
  # an unambiguous, safe repair — wrap it under that field's name — rather
  # than a rejection the model then has to guess its way out of.
  def call(%{"type" => type, "content" => content} = args, context)
      when is_binary(type) and is_list(content) do
    case sole_field(type) do
      {:ok, field} -> call(%{args | "content" => %{field => content}}, context)
      :error -> malformed_call_error(type)
    end
  end

  def call(%{"type" => type}, _context) when is_binary(type), do: malformed_call_error(type)
  def call(_args, _context), do: malformed_call_error(nil)

  defp sole_field(type) do
    type_atom = String.to_existing_atom(type)

    case ArtifactSchema.fields(type_atom) do
      [field] -> {:ok, field}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp malformed_call_error(nil) do
    {:error,
     %{
       "kind" => "malformed_call",
       "message" => "expected {\"type\": \"...\", \"content\": {...}}"
     }}
  end

  defp malformed_call_error(type) do
    example =
      case safe_describe(type) do
        {:ok, description} -> " #{description}"
        :error -> ""
      end

    {:error,
     %{
       "kind" => "malformed_call",
       "artifact_type" => type,
       "message" =>
         "expected {\"type\": \"#{type}\", \"content\": {...}} — content must be an " <>
           "object, not a bare list.#{example}"
     }}
  end

  # §6: "Scores are computed by code from the ratings, not by the model", and
  # "Missing evidence is unknown, not zero and not an average guess". A live
  # discovery mission supplied its own total (4.0) over dimensions it had
  # invented, and nothing recomputed it. The model rates; Sprat scores.
  defp compute_derived(:opportunity_scorecard, content) do
    ratings =
      content
      |> Map.get("dimensions", [])
      |> Map.new(fn dim ->
        name = Map.get(dim, "name") || Map.get(dim, "dimension")
        {safe_dimension(name), parse_rating(Map.get(dim, "rating"))}
      end)

    scored = Scorecard.score(ratings)

    Map.merge(content, %{
      "total" => decimal_or_unknown(scored.total),
      "evidence_coverage" => Float.round(scored.coverage, 3),
      "scored_by" => "sprat",
      "weights" => Map.new(Scorecard.default_weights(), fn {k, v} -> {to_string(k), v} end)
    })
  end

  defp compute_derived(_type, content), do: content

  defp safe_dimension(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :"#{name}"
  end

  defp safe_dimension(name), do: :"#{inspect(name)}"

  defp parse_rating(n) when is_integer(n) and n in 1..5, do: n
  defp parse_rating(n) when is_float(n), do: parse_rating(round(n))

  defp parse_rating(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n in 1..5 -> n
      _ -> :unknown
    end
  end

  defp parse_rating(_), do: :unknown

  defp decimal_or_unknown(:unknown), do: "unknown"
  defp decimal_or_unknown(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()

  defp write(type, content, context) do
    type_atom = String.to_existing_atom(type)
    content = ArtifactSchema.normalize(type_atom, content)

    case ArtifactSchema.validate(type_atom, content) do
      {:error, errors} ->
        {:error,
         %{
           "kind" => "validation_failed",
           "artifact_type" => type,
           "message" => "#{type} failed validation: #{Enum.join(errors, "; ")}"
         }}

      :ok ->
        store = Map.fetch!(context, :store)
        mission_id = Map.fetch!(context, :mission_id)
        content = compute_derived(type_atom, content)

        {:ok, %{artifact: _artifact, version: version}} =
          Artifacts.write(store, mission_id, %{
            type: type_atom,
            owning_role: Map.get(context, :role, "researcher"),
            content: content,
            created_by: Map.get(context, :role, "researcher")
          })

        {:ok, %{"type" => type, "version" => version}}
    end
  rescue
    ArgumentError ->
      {:error, %{"kind" => "unknown_type", "message" => "unknown artifact type: #{type}"}}
  end

  defp safe_describe(type) do
    {:ok, ArtifactSchema.describe(String.to_existing_atom(type))}
  rescue
    _ -> :error
  end
end
