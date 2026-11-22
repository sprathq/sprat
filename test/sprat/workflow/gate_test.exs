defmodule Sprat.Workflow.GateTest do
  use ExUnit.Case, async: true

  alias Sprat.Workflow.Gate

  test "intake_to_research: objective, depth, open_questions must be present" do
    assert {:error, errors} = Gate.check(:intake_to_research, %{}, MapSet.new())
    assert Enum.any?(errors, &(&1 =~ "intake_summary"))

    artifacts = %{
      intake_summary: %{"objective" => "o", "depth" => "quick", "open_questions" => ["q1"]}
    }

    assert :ok = Gate.check(:intake_to_research, artifacts, MapSet.new())
  end

  test "research_to_analysis: research_memo must exist and every claim must cite a real source" do
    assert {:error, errors} = Gate.check(:research_to_analysis, %{}, MapSet.new())
    assert Enum.any?(errors, &(&1 =~ "research_memo"))

    memo = %{
      "summary" => "s",
      "limitations" => "no live search",
      "claims" => [%{"text" => "c", "source_ids" => ["src_missing"], "confidence" => "high"}]
    }

    assert {:error, errors} =
             Gate.check(:research_to_analysis, %{research_memo: memo}, MapSet.new(["src_1"]))

    assert Enum.any?(errors, &(&1 =~ "src_missing"))

    ok_memo =
      put_in(memo, ["claims"], [
        %{"text" => "c", "source_ids" => ["src_1"], "confidence" => "high"}
      ])

    assert :ok =
             Gate.check(:research_to_analysis, %{research_memo: ok_memo}, MapSet.new(["src_1"]))
  end

  test "research_to_analysis: a claim marked is_assumption needs no source" do
    memo = %{
      "summary" => "s",
      "limitations" => "l",
      "claims" => [%{"text" => "c", "is_assumption" => true, "confidence" => "low"}]
    }

    assert :ok = Gate.check(:research_to_analysis, %{research_memo: memo}, MapSet.new())
  end

  test "analysis_gate: assumption_register must have at least one assumption ranked by risk" do
    assert {:error, _} = Gate.check(:analysis_gate, %{}, MapSet.new())

    ok = %{assumption_register: %{"assumptions" => [%{"text" => "a", "risk" => "high"}]}}
    assert :ok = Gate.check(:analysis_gate, ok, MapSet.new())
  end

  test "recommendation_to_delivery: names one of the four recommendations and cites evidence" do
    bad = %{
      recommendation_memo: %{"recommendation" => "maybe", "evidence" => [], "tradeoffs" => "t"}
    }

    assert {:error, _} = Gate.check(:recommendation_to_delivery, bad, MapSet.new())

    ok = %{
      recommendation_memo: %{
        "recommendation" => "go",
        "evidence" => ["src_1"],
        "tradeoffs" => "t"
      }
    }

    assert :ok = Gate.check(:recommendation_to_delivery, ok, MapSet.new(["src_1"]))
  end

  test "validation_plan_gate: discovery delivers a plan, and is never asked for a brief" do
    # A real discovery mission passed all six earlier stages and then failed
    # at delivery because the shared gate demanded a product_brief, which
    # that workflow never produces.
    experiment = %{
      "assumption" => "venues will pay for automated settlement",
      "participant_criteria" => "independent venues, 200-600 capacity",
      "method" => "interview plus a paid pilot",
      "budget" => "£400",
      "duration" => "2 weeks",
      "success_threshold" => "4 of 6 complete a settlement with the tool",
      "failure_threshold" => "2 or fewer",
      "decision" => "build the settlement flow, or stop"
    }

    plan_only = %{validation_plan: %{"experiments" => [experiment]}}

    assert :ok = Gate.check(:validation_plan_gate, plan_only, MapSet.new())
    assert {:error, errors} = Gate.check(:validation_plan_gate, %{}, MapSet.new())
    assert Enum.any?(errors, &(&1 =~ "validation_plan"))
    refute Enum.any?(errors, &(&1 =~ "product_brief"))
  end

  test "delivery_gate: all required artifacts present or explicitly marked incomplete" do
    assert {:error, _} = Gate.check(:delivery_gate, %{}, MapSet.new())

    ok = %{
      product_brief: %{"problem" => "p", "customer" => "c", "mvp_scope" => "m"},
      validation_plan: %{
        "experiments" => [
          %{
            "assumption" => "a",
            "participant_criteria" => "p",
            "method" => "m",
            "budget" => "b",
            "duration" => "d",
            "success_threshold" => "s",
            "failure_threshold" => "f",
            "decision" => "dec"
          }
        ]
      }
    }

    assert :ok = Gate.check(:delivery_gate, ok, MapSet.new())
  end

  test "delivery_gate accepts an artifact explicitly marked incomplete with a reason" do
    ok = %{
      product_brief: %{"incomplete" => true, "reason" => "user stopped after directions"},
      validation_plan: %{"incomplete" => true, "reason" => "user stopped after directions"}
    }

    assert :ok = Gate.check(:delivery_gate, ok, MapSet.new())
  end

  test "unknown gate is an error, not a crash" do
    assert {:error, ["unknown gate: bogus_gate"]} = Gate.check(:bogus_gate, %{}, MapSet.new())
  end

  # -- steering staleness (docs/spec-v1.md §10) ------------------------------

  describe "check/5 stale_types" do
    test "a stale required artifact fails the gate even though its content is otherwise valid" do
      artifacts = %{
        intake_summary: %{"objective" => "o", "depth" => "quick", "open_questions" => ["q1"]}
      }

      assert {:error, errors} =
               Gate.check(
                 :intake_to_research,
                 artifacts,
                 MapSet.new(),
                 %{},
                 MapSet.new([:intake_summary])
               )

      assert Enum.any?(errors, &(&1 =~ "stale"))
    end

    test "a stale artifact of a DIFFERENT type does not affect this gate" do
      artifacts = %{
        intake_summary: %{"objective" => "o", "depth" => "quick", "open_questions" => ["q1"]}
      }

      assert :ok =
               Gate.check(
                 :intake_to_research,
                 artifacts,
                 MapSet.new(),
                 %{},
                 MapSet.new([:research_memo])
               )
    end

    test "check/3 and check/4 default to an empty stale set — unaffected by steering" do
      artifacts = %{
        intake_summary: %{"objective" => "o", "depth" => "quick", "open_questions" => ["q1"]}
      }

      assert :ok = Gate.check(:intake_to_research, artifacts, MapSet.new())
      assert :ok = Gate.check(:intake_to_research, artifacts, MapSet.new(), %{})
    end
  end

  describe "design_to_scaffold (docs/spec-v2.md §5)" do
    defp valid_design do
      %{
        "profile" => "elixir-phoenix",
        "data_model" => %{"entities" => [%{"name" => "Gym", "fields" => []}], "relations" => []},
        "components" => ["web layer"],
        "external_services" => [],
        "excluded_scope" => [%{"item" => "payments", "reason" => "not in MVP boundary"}],
        "estimated_cost" => "~$5 (estimate)"
      }
    end

    test "refuses when no technical_design artifact exists" do
      assert {:error, errors} = Gate.check(:design_to_scaffold, %{}, MapSet.new())
      assert Enum.any?(errors, &(&1 =~ "technical_design"))
    end

    test "refuses an unsupported profile, by name" do
      design = Map.put(valid_design(), "profile", "python-django")

      assert {:error, errors} =
               Gate.check(:design_to_scaffold, %{technical_design: design}, MapSet.new())

      assert Enum.any?(errors, &(&1 =~ "python-django"))
    end

    test "passes a valid, supported design" do
      assert :ok =
               Gate.check(:design_to_scaffold, %{technical_design: valid_design()}, MapSet.new())
    end
  end

  describe "scaffold_gate (docs/spec-v2.md §5): install succeeded, run started, health check returned" do
    defp run(purpose, exit_code) do
      %Sprat.Store.Runs{
        purpose: purpose,
        exit_code: exit_code,
        command: purpose,
        args: [],
        cwd: "/tmp"
      }
    end

    test "refuses when no runs are recorded at all" do
      assert {:error, errors} =
               Gate.check(:scaffold_gate, %{}, MapSet.new(), %{}, MapSet.new(), [])

      assert Enum.any?(errors, &(&1 =~ "install"))
      assert Enum.any?(errors, &(&1 =~ "run command starting"))
      assert Enum.any?(errors, &(&1 =~ "health check"))
    end

    test "refuses when the health check failed even though install and run succeeded" do
      runs = [run("install", 0), run("run", 0), run("health_check", 1)]

      assert {:error, errors} =
               Gate.check(:scaffold_gate, %{}, MapSet.new(), %{}, MapSet.new(), runs)

      assert Enum.any?(errors, &(&1 =~ "the health check"))
      refute Enum.any?(errors, &(&1 =~ "install"))
    end

    test "passes when install, run and health_check all recorded a zero exit code" do
      runs = [run("install", 0), run("run", 0), run("health_check", 0)]
      assert :ok = Gate.check(:scaffold_gate, %{}, MapSet.new(), %{}, MapSet.new(), runs)
    end
  end
end
