defmodule Sprat.PM.PolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sprat.Observer.Model.{Decision, Finding, Item, Session}
  alias Sprat.PM.Policy

  @now ~U[2026-11-23 14:00:00Z]
  @item %Item{id: "B.5", text: "onboarding screens"}

  defp decision(attrs \\ []) do
    struct(
      %Decision{
        action: :unblock,
        message: "Stop retrying the archive; switch Debug to automatic signing and move on.",
        confidence: :high,
        evidence_used: ["transcript:1822"]
      },
      attrs
    )
  end

  defp ctx(attrs \\ []) do
    base = %{
      autonomy: :act,
      finding: %Finding{id: "L1-abc", rule: "L1", project_root: "/r", session_id: "s1"},
      session: %Session{session_id: "s1", config_dir: "/c"},
      item: @item,
      now: @now,
      ledger: %{
        last_delivery_at_by_session: %{},
        sent_texts_by_session: %{},
        pm_runs_for_finding: 1,
        answers_given: MapSet.new()
      },
      budget: %{
        project_spent_today: 0.5,
        project_cap: 3.0,
        fleet_spent_today: 2.0,
        fleet_cap: 15.0
      },
      owner_typing?: false
    }

    Enum.reduce(attrs, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp ledger(attrs), do: Map.merge(ctx().ledger, Map.new(attrs))

  describe "autonomy" do
    test "watch: noop, escalate still escalates" do
      assert Policy.authorize(decision(), ctx(autonomy: :watch)) == {:noop, :watch}

      assert Policy.authorize(decision(action: :escalate), ctx(autonomy: :watch)) ==
               {:escalate, :pm_escalated}
    end

    test "propose: every decision is proposed" do
      for a <- [:unblock, :answer, :reassign, :resume, :wait] do
        d = decision(action: a, answer_source: "docs/spec-v3.md §5")
        assert Policy.authorize(d, ctx(autonomy: :propose)) == {:propose, :autonomy}
      end
    end

    test "act: delivers unblock, answer, reassign; wait is a noop" do
      assert {:deliver, "[sprat] Stop retrying" <> _} = Policy.authorize(decision(), ctx())

      assert {:deliver, _} =
               Policy.authorize(
                 decision(action: :answer, answer_source: "docs/spec-v3.md §5"),
                 ctx()
               )

      assert {:deliver, _} =
               Policy.authorize(decision(action: :reassign, next_item: "B.5"), ctx())

      assert Policy.authorize(decision(action: :wait), ctx()) == {:noop, :wait}
    end

    test "resume is proposed under act, delivered under act_resume" do
      d = decision(action: :resume, message: "Continue with B.5 from PAUSE.md step 3.")
      assert Policy.authorize(d, ctx()) == {:propose, :resume_needs_act_resume}
      assert {:deliver, _} = Policy.authorize(d, ctx(autonomy: :act_resume))
    end

    test "low confidence is proposed, never acted on" do
      assert Policy.authorize(decision(confidence: :low), ctx()) == {:propose, :low_confidence}
    end
  end

  describe "§8.4 owner-only" do
    test "owner_needed? and escalate decisions escalate whatever the autonomy" do
      for level <- [:watch, :propose, :act, :act_resume] do
        assert {:escalate, _} =
                 Policy.authorize(decision(owner_needed?: true), ctx(autonomy: level))
      end
    end

    test "answer without a recorded source escalates" do
      assert Policy.authorize(decision(action: :answer), ctx()) ==
               {:escalate, :no_recorded_answer}
    end

    test "the same question is never answered twice" do
      d = decision(action: :answer, answer_source: "PAUSE.md")
      c = ctx(ledger: ledger(answers_given: MapSet.new(["L1-abc"])))
      assert Policy.authorize(d, c) == {:escalate, :already_answered}
    end

    @positives [
      push: "Commit the fix and git push to origin.",
      push: "Then force-push the branch.",
      push: "Push the branch to origin when green.",
      deploy: "Deploy the app once the tests pass.",
      deploy: "Run fly deploy afterwards.",
      deploy: "Ship it to production.",
      deploy: "terraform apply the change.",
      publish: "Publish the package to hex.",
      publish: "npm publish after bumping.",
      send: "Send the newsletter to all customers.",
      send: "send an email to the venue owners",
      rm_rf: "Clean up with rm -rf _build deps.",
      rm_rf: "rm -fr priv/static",
      drop: "DROP TABLE networks and recreate it.",
      drop: "Run mix ecto.reset to start fresh.",
      delete_data: "Delete all the user records first.",
      delete_data: "Run DELETE FROM points WHERE 1=1.",
      delete_data: "wipe the production data",
      shared_migration: "Run the migration on production.",
      shared_migration: "migrate the shared database",
      shared_migration: "Point at the staging DB and migrate.",
      credentials: "Generate a new API key for Stripe.",
      credentials: "Paste the password into .env.",
      credentials: "Import the iOS Distribution certificate.",
      credentials: "Create an access token on GitHub.",
      credentials: "Sign in to the App Store Connect account and get the private key.",
      purchase: "Buy the domain.",
      purchase: "Upgrade the plan to Pro so the build minutes suffice.",
      purchase: "Subscribe to the paid tier.",
      scope: "Add a new roadmap item for the backfill."
    ]

    @negatives [
      "Run mix test and fix the failing assertion in ledger_test.exs.",
      "The deployment_config_test is failing on a nil.",
      "The published_at column is nil for drafts.",
      "Push forward with B.5 onboarding screens.",
      "Write an Ecto migration for the networks table and run mix ecto.migrate locally.",
      "The token parser rejects whitespace; trim before matching.",
      "Use the credentials fixture already in test/support.",
      "Remove the dead branch in Ledger.apply/2.",
      "The certificate test is skipped on CI; leave it.",
      "Delete the unused helper function in lib/x.ex.",
      "rm the stale tmp file test/tmp/out.json",
      "Switch Debug to automatic signing.",
      "Send the result to the next function in the pipe.",
      "Drop the unused alias.",
      "The pricing page copy mentions purchases; keep the wording."
    ]

    test "positive examples are refused with their category" do
      for {category, text} <- @positives do
        assert category in Policy.owner_only(text), "#{inspect(category)} not matched: #{text}"

        assert {:refuse, {:owner_only, _}} = Policy.authorize(decision(message: text), ctx()),
               text
      end
    end

    test "negative examples pass" do
      for text <- @negatives do
        assert Policy.owner_only(text) == [],
               "false positive: #{text} → #{inspect(Policy.owner_only(text))}"
      end
    end

    test "owner-only content is refused even under propose" do
      assert {:refuse, {:owner_only, :push}} =
               Policy.authorize(decision(message: "git push it"), ctx(autonomy: :propose))
    end
  end

  describe "§9.2 guardrails" do
    test "no evidence is refused" do
      assert Policy.authorize(decision(evidence_used: []), ctx()) == {:refuse, :no_evidence}
    end

    test "more than three PM runs for a finding escalates" do
      assert {:deliver, _} =
               Policy.authorize(decision(), ctx(ledger: ledger(pm_runs_for_finding: 3)))

      assert Policy.authorize(decision(), ctx(ledger: ledger(pm_runs_for_finding: 4))) ==
               {:escalate, :pm_run_limit}

      assert Policy.authorize(
               decision(),
               ctx(ledger: ledger(pm_runs_for_finding: %{"L1-abc" => 4}))
             ) ==
               {:escalate, :pm_run_limit}
    end

    test "budget caps drop to propose" do
      over_project = %{
        project_spent_today: 3.0,
        project_cap: 3.0,
        fleet_spent_today: 3.0,
        fleet_cap: 15.0
      }

      over_fleet = %{
        project_spent_today: 0.1,
        project_cap: 3.0,
        fleet_spent_today: 15.2,
        fleet_cap: 15.0
      }

      assert Policy.authorize(decision(), ctx(budget: over_project)) == {:propose, :budget_cap}
      assert Policy.authorize(decision(), ctx(budget: over_fleet)) == {:propose, :budget_cap}
    end

    test "one delivery per session per 20 minutes, else hold until then" do
      last = DateTime.add(@now, -5 * 60)
      c = ctx(ledger: ledger(last_delivery_at_by_session: %{"s1" => last}))

      assert Policy.authorize(decision(), c) ==
               {:noop, {:hold, :rationed, DateTime.add(last, 20 * 60)}}

      c =
        ctx(ledger: ledger(last_delivery_at_by_session: %{"s1" => DateTime.add(@now, -21 * 60)}))

      assert {:deliver, _} = Policy.authorize(decision(), c)
    end

    test "owner typing holds delivery" do
      assert Policy.authorize(decision(), ctx(owner_typing?: true)) ==
               {:noop, {:hold, :owner_typing, DateTime.add(@now, 120)}}
    end

    test "never the same text twice to the same session" do
      sent = Policy.message_for(decision(), @item)
      c = ctx(ledger: ledger(sent_texts_by_session: %{"s1" => [sent]}))
      assert Policy.authorize(decision(), c) == {:refuse, :duplicate_text}

      c = ctx(ledger: ledger(sent_texts_by_session: %{"s2" => [sent]}))
      assert {:deliver, _} = Policy.authorize(decision(), c)
    end

    test "a deliverable decision with no message is refused" do
      assert Policy.authorize(decision(message: "  "), ctx()) == {:refuse, :no_message}
    end
  end

  describe "message_for/2" do
    test "prefix and roadmap suffix" do
      assert Policy.message_for(decision(message: " Do X. "), @item) ==
               "[sprat] Do X. (roadmap: B.5 onboarding screens)"
    end

    test "does not double the prefix; omits the suffix with no item" do
      assert Policy.message_for(decision(message: "[sprat] Do X."), nil) == "[sprat] Do X."
    end
  end

  property "nothing is ever delivered under watch or propose, or with owner-only content" do
    check all(
            action <- member_of([:unblock, :answer, :reassign, :resume, :wait, :escalate]),
            autonomy <- member_of([:watch, :propose, :act, :act_resume]),
            confidence <- member_of([:low, :medium, :high]),
            bad <- member_of([nil | Enum.map(@positives, &elem(&1, 1))]),
            msg <- string(:printable, min_length: 1, max_length: 40)
          ) do
      message = if bad, do: msg <> " " <> bad, else: msg

      d =
        decision(action: action, confidence: confidence, message: message, answer_source: "spec")

      result = Policy.authorize(d, ctx(autonomy: autonomy))

      if autonomy in [:watch, :propose] or bad != nil or confidence == :low do
        refute match?({:deliver, _}, result)
      end

      case result do
        {:deliver, text} ->
          assert String.starts_with?(text, "[sprat] ")
          assert String.ends_with?(text, "(roadmap: B.5 onboarding screens)")

        _ ->
          :ok
      end
    end
  end
end
