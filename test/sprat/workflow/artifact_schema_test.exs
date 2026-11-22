defmodule Sprat.Workflow.ArtifactSchemaTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.ArtifactSchema

  test "research_memo requires summary, claims and limitations" do
    assert {:error, errors} = ArtifactSchema.validate(:research_memo, %{})
    assert Enum.any?(errors, &(&1 =~ ~s("summary")))
    assert Enum.any?(errors, &(&1 =~ ~s("claims")))
    assert Enum.any?(errors, &(&1 =~ ~s("limitations")))

    assert :ok =
             ArtifactSchema.validate(:research_memo, %{
               "summary" => "x",
               "claims" => [%{"text" => "y", "source_ids" => ["src_1"], "confidence" => "high"}],
               "limitations" => "no live search"
             })
  end

  # The synonym-drift bug named in the replay-harness brief: a live run
  # wrote `findings`/`practical_findings`/`key_claims` instead of `claims`,
  # and `gaps` instead of `limitations`, and was rejected every time.
  test "research_memo accepts observed field-name synonyms for claims and limitations" do
    assert :ok =
             ArtifactSchema.validate(:research_memo, %{
               "summary" => "x",
               "findings" => [%{"fact" => "y", "evidence" => "src_1"}],
               "gaps" => ["no live search"]
             })
  end

  test "an actionable error names the field, gives an example, and lists what was received" do
    assert {:error, errors} = ArtifactSchema.validate(:research_memo, %{"summary" => "x"})
    claims_error = Enum.find(errors, &(&1 =~ ~s("claims")))
    assert claims_error =~ "Example:"
    assert claims_error =~ "Also accepted: findings"
    assert claims_error =~ "Got fields: summary"
  end

  test "product_directions requires 1-3 directions, each with the required fields" do
    assert {:error, errors} = ArtifactSchema.validate(:product_directions, %{"directions" => []})
    assert Enum.any?(errors, &(&1 =~ "at least one direction"))

    too_many = for n <- 1..4, do: direction("d#{n}")

    assert {:error, errors} =
             ArtifactSchema.validate(:product_directions, %{"directions" => too_many})

    assert Enum.any?(errors, &(&1 =~ "at most three"))

    assert :ok =
             ArtifactSchema.validate(:product_directions, %{"directions" => [direction("d1")]})
  end

  test "product_directions accepts observed field-name synonyms per direction" do
    synonym_direction = %{
      "target_customer" => "d1",
      "pain_point" => "p",
      "value_prop" => "v",
      "mvp_scope" => "s",
      "validation" => "a"
    }

    assert :ok =
             ArtifactSchema.validate(:product_directions, %{"directions" => [synonym_direction]})
  end

  defp direction(name) do
    %{
      "customer" => name,
      "problem" => "p",
      "value" => "v",
      "scope" => "s",
      "validation_approach" => "a"
    }
  end

  test "recommendation_memo requires a recommendation in the fixed set, cited evidence" do
    assert {:error, errors} =
             ArtifactSchema.validate(:recommendation_memo, %{"recommendation" => "maybe"})

    assert Enum.any?(errors, &(&1 =~ "recommendation"))

    assert :ok =
             ArtifactSchema.validate(:recommendation_memo, %{
               "recommendation" => "validate_first",
               "evidence" => ["src_1"],
               "tradeoffs" => "t"
             })
  end

  test "research_memo rejects an empty claims list" do
    assert {:error, _} =
             ArtifactSchema.validate(:research_memo, %{
               "summary" => "s",
               "claims" => [],
               "limitations" => "l"
             })
  end

  test "source_register rejects an empty sources list" do
    assert {:error, _} = ArtifactSchema.validate(:source_register, %{"sources" => []})
  end

  # A live run sent `entries` instead of `sources` (mis_EUlIEBaOwFUh).
  test "source_register accepts the observed `entries` synonym" do
    assert :ok =
             ArtifactSchema.validate(:source_register, %{
               "entries" => [%{"title" => "t", "url" => "https://example.com"}]
             })
  end

  test "competitor_matrix rejects an empty competitors list" do
    assert {:error, _} = ArtifactSchema.validate(:competitor_matrix, %{"competitors" => []})
  end

  test "opportunity_scorecard rejects an empty dimensions list" do
    assert {:error, _} =
             ArtifactSchema.validate(:opportunity_scorecard, %{
               "dimensions" => [],
               "total" => 0
             })
  end

  test "recommendation_memo rejects an empty evidence list" do
    assert {:error, _} =
             ArtifactSchema.validate(:recommendation_memo, %{
               "recommendation" => "go",
               "evidence" => [],
               "tradeoffs" => "t"
             })
  end

  test "assumption_register still accepts the risk-key synonyms" do
    assert :ok =
             ArtifactSchema.validate(:assumption_register, %{
               "assumptions" => [%{"text" => "x", "risk_rating" => "high"}]
             })

    assert {:error, [error]} =
             ArtifactSchema.validate(:assumption_register, %{
               "assumptions" => [%{"text" => "x", "priority" => "high"}]
             })

    assert error =~ "no assumption is ranked by risk"
    assert error =~ "risk_rating"
  end

  test "unknown artifact type is an error, not a crash" do
    assert {:error, ["unknown artifact type: bogus"]} = ArtifactSchema.validate(:bogus, %{})
  end

  test "describe/1 renders every field with its synonyms and a worked example" do
    text = ArtifactSchema.describe(:research_memo)
    assert text =~ "claims"
    assert text =~ "findings"
    assert text =~ "Worked example:"
    assert text =~ "users want fewer taps"
  end

  test "example/1 produces content that validates" do
    Enum.each(ArtifactSchema.types(), fn type ->
      assert :ok = ArtifactSchema.validate(type, ArtifactSchema.example(type)),
             "#{type}'s own generated example failed its own validation"
    end)
  end

  describe "technical_design (docs/spec-v2.md §8)" do
    defp valid_design(overrides \\ %{}) do
      Map.merge(
        %{
          "profile" => "elixir-phoenix",
          "data_model" => %{
            "entities" => [%{"name" => "Gym", "fields" => ["name"]}],
            "relations" => []
          },
          "components" => ["web layer"],
          "external_services" => [],
          "excluded_scope" => [%{"item" => "payments", "reason" => "not in MVP boundary"}],
          "estimated_cost" => "~$5 (estimate)"
        },
        overrides
      )
    end

    test "a valid design validates, including [] for external_services" do
      assert :ok = ArtifactSchema.validate(:technical_design, valid_design())
    end

    test "refuses an unsupported profile, naming it and the supported list" do
      assert {:error, errors} =
               ArtifactSchema.validate(
                 :technical_design,
                 valid_design(%{"profile" => "python-django"})
               )

      assert Enum.any?(errors, &(&1 =~ "python-django"))
      assert Enum.any?(errors, &(&1 =~ "elixir-phoenix"))
      assert Enum.any?(errors, &(&1 =~ "node-next"))
    end

    test "requires the data model to have at least one entity" do
      design = valid_design(%{"data_model" => %{"entities" => [], "relations" => []}})
      assert {:error, errors} = ArtifactSchema.validate(:technical_design, design)
      assert Enum.any?(errors, &(&1 =~ "at least one entity"))
    end

    test "requires excluded_scope to be a non-empty list" do
      design = valid_design(%{"excluded_scope" => []})
      assert {:error, errors} = ArtifactSchema.validate(:technical_design, design)
      assert Enum.any?(errors, &(&1 =~ "excluded_scope"))
    end
  end
end
