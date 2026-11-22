defmodule Sprat.Agent.Tools.WriteArtifactScorecardTest do
  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.WriteArtifact
  alias Sprat.Store.{Artifacts, Missions, Sessions}

  # §6: the model rates, the code scores. A live discovery mission invented
  # its own dimensions and supplied its own total (4.0), and nothing checked
  # or recomputed either.
  setup %{store: store} do
    {:ok, session} = Sessions.create(store, %{project_path: "/tmp/scorecard"})
    {:ok, mission} = Missions.create(store, session.id, %{objective: "score something"})

    %{
      context: %{
        store: store,
        mission_id: mission.id,
        role: "analyst",
        allowed_artifact_types: MapSet.new(["opportunity_scorecard"])
      },
      mission: mission
    }
  end

  defp card(dimensions, extra \\ %{}) do
    Map.merge(%{"dimensions" => dimensions}, extra)
  end

  defp all_dimensions(rating) do
    Sprat.Workflow.Scorecard.default_weights()
    |> Map.keys()
    |> Enum.map(&%{"name" => to_string(&1), "rating" => rating, "evidence" => "src_1"})
  end

  test "a card missing a §6 dimension is rejected, and the error names it", %{context: ctx} do
    partial = [%{"name" => "pain_severity", "rating" => 4, "evidence" => "src_1"}]

    assert {:error, %{"message" => message}} =
             WriteArtifact.call(
               %{"type" => "opportunity_scorecard", "content" => card(partial)},
               ctx
             )

    assert message =~ "willingness_to_pay"
    assert message =~ "founder_advantage"
  end

  test "the model's own total is replaced by the computed one", %{context: ctx, mission: mission} do
    content = card(all_dimensions(4), %{"total" => 4.9})

    assert {:ok, _} =
             WriteArtifact.call(%{"type" => "opportunity_scorecard", "content" => content}, ctx)

    stored = Artifacts.latest_all(ctx.store, mission.id)[:opportunity_scorecard]

    assert stored["total"] == "4.00"
    assert stored["scored_by"] == "sprat"
    assert stored["evidence_coverage"] == 1.0
  end

  test "unknown ratings lower coverage and never count as zero", %{
    context: ctx,
    mission: mission
  } do
    dimensions =
      all_dimensions(4)
      |> Enum.map(fn dim ->
        if dim["name"] in ["willingness_to_pay", "unit_economics"],
          do: %{dim | "rating" => "unknown", "evidence" => ""},
          else: dim
      end)

    assert {:ok, _} =
             WriteArtifact.call(
               %{"type" => "opportunity_scorecard", "content" => card(dimensions)},
               ctx
             )

    stored = Artifacts.latest_all(ctx.store, mission.id)[:opportunity_scorecard]

    # Every known dimension is rated 4, so the total stays 4 — unknowns are
    # excluded from the average rather than dragging it towards zero.
    assert stored["total"] == "4.00"
    assert stored["evidence_coverage"] == 0.7
  end
end
