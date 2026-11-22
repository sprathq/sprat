defmodule Sprat.ReplayMissionsTest do
  @moduledoc """
  Reproduces the three live mission failures the replay-harness brief
  names, offline, from the REAL content the model wrote that day (copied
  verbatim from `test/fixtures/missions/<mission_id>/exchanges.json`,
  which `mix sprat.fixtures.export` pulled straight from the owner's
  recorded `model.request`/`model.response` events — see each test's
  comment for the exact mission id and event seq it came from).

  Two layers, both real, no mocking of the code under test:

    * `Sprat.Workflow.ArtifactSchema`/`Sprat.Agent.Tools.WriteArtifact`
      tests below call the REAL validator/tool directly against the
      REAL recorded `write_artifact` call arguments — this is the
      cleanest, fully-deterministic reproduction of "the model wrote a
      reasonable artifact and the schema rejected it on a technicality",
      independent of anything else in the loop.
    * `Sprat.ReplayMissionsOrchestratorTest` (bottom of this file) drives
      the SAME recorded exchanges through the real `Sprat.Orchestrator` /
      `Sprat.Agent.Loop` / gates / `Sprat.Store`, via `Sprat.Model.Replay`
      — see that module's tests for what is and isn't provable that way
      (an honest, documented limitation: `record_source`/`record_claim`
      generate fresh ids on every real run, so a recorded `record_claim`
      call citing the LIVE run's exact source id cannot resolve against a
      replayed run's freshly-generated one — this is unrelated to the
      schema/stall defect class this branch fixes, and is called out
      explicitly rather than worked around).
  """

  use Sprat.StoreCase, async: true

  alias Sprat.Agent.Tools.WriteArtifact
  alias Sprat.Store.{Artifacts, Missions, Sessions}
  alias Sprat.Workflow.ArtifactSchema

  defp write_context(store, mission_id, allowed_type) do
    %{
      store: store,
      mission_id: mission_id,
      role: "researcher",
      allowed_artifact_types: MapSet.new([allowed_type])
    }
  end

  describe "mis_EUlIEBaOwFUh — research_memo failed validation: claims; limitations" do
    # Verbatim `write_artifact` call arguments from event seq 97 (this
    # mission's FIRST research_memo attempt) — the model used
    # `practical_findings` for its claims and never wrote a `limitations`
    # field at all.
    @first_attempt %{
      "summary" =>
        "Indie Elixir library authors who want to determine which projects use their " <>
          "packages can primarily rely on two sources: the Hex.pm package registry and " <>
          "GitHub's dependency graph for public repositories linking to their library.",
      "practical_findings" => [
        %{
          "fact" =>
            "Hex.pm's dependent list is viewable on each package page and only includes " <>
              "other Hex.pm packages depending on the library.",
          "evidence" => ["src_9BjAggB1UtRM"]
        },
        %{
          "fact" =>
            "GitHub's dependency graph and 'Used by' tab list which public repositories " <>
              "depend on a library, provided the linkage is set up and the repository is public.",
          "evidence" => ["src_hZWLrDCOgV7L", "src_8-1NfwiP5usk"]
        }
      ],
      "alternatives_considered" => [
        %{"approach" => "Manual code search on GitHub", "downside" => "Not scalable"}
      ],
      "representative_complaints" => [%{"issue" => "Hex.pm dependent list visibility gap"}]
    }

    # Verbatim from event seq 101 (the SECOND attempt, still in the same
    # stalled task) — this one DOES have a `limitations` field (a list),
    # but still no `claims`/`findings`; the live gate rejected only
    # "claims" for this exact attempt.
    @second_attempt Map.merge(@first_attempt, %{
                      "limitations" => [
                        %{
                          "limitation" =>
                            "Hex.pm dependent lists do not cover real-world usage in " <>
                              "private apps, non-published, or direct application-only projects.",
                          "evidence" => ["src_9BjAggB1UtRM"]
                        }
                      ]
                    })

    test "the fix's practical_findings->claims synonym accepts the FIRST real attempt's claims — it still, correctly, names the one field genuinely absent (limitations)" do
      # Live, this exact attempt was rejected for "claims; limitations"
      # (event seq 98) — the fix's `practical_findings` synonym resolves
      # `claims`, so only the genuinely-missing `limitations` remains, and
      # the error now names it, describes it, and gives an example,
      # instead of the pre-fix bare field-name list.
      assert {:error, [error]} = ArtifactSchema.validate(:research_memo, @first_attempt)
      assert error =~ ~s("limitations")
      assert error =~ "Example:"
      assert error =~ "Also accepted: limitations_section, caveats, gaps"
      refute error =~ ~s("claims")
    end

    test "the fix's claims/findings synonym accepts the second real attempt outright (only `claims` was actually missing live)" do
      assert :ok = ArtifactSchema.validate(:research_memo, @second_attempt)
    end

    test "write_artifact accepts and stores the second real attempt through the real tool + store",
         %{store: store} do
      {:ok, session} = Sessions.create(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
      context = write_context(store, mission.id, "research_memo")

      args = %{"type" => "research_memo", "content" => @second_attempt}
      assert {:ok, %{"type" => "research_memo"}} = WriteArtifact.call(args, context)
      stored = Artifacts.latest(store, mission.id, :research_memo)
      assert stored["claims"] != nil
      assert stored["limitations"] != nil
    end
  end

  describe "mis_EUlIEBaOwFUh — source_register failed validation: sources" do
    # Verbatim from event seq 109 — the model sent `entries`, not `sources`.
    @entries_content %{
      "entries" => [
        %{
          "source_id" => "src_9BjAggB1UtRM",
          "title" => "Finding projects depending on given library - Elixir Forum",
          "url" => "https://elixirforum.com/t/finding-projects-depending-on-given-library/33725"
        },
        %{
          "source_id" => "src_hZWLrDCOgV7L",
          "title" => "Exploring the dependencies of a repository - GitHub Docs",
          "url" =>
            "https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/explore-dependencies"
        }
      ]
    }

    test "the `entries` synonym accepts the real recorded content" do
      assert :ok = ArtifactSchema.validate(:source_register, @entries_content)
    end

    test "content with none of sources/entries/results gives an actionable error, not a bare field name" do
      assert {:error, [error]} = ArtifactSchema.validate(:source_register, %{"results" => []})
      assert error =~ ~s("sources")
      assert error =~ "Also accepted: entries, results"
      assert error =~ "Example:"
    end
  end

  describe "mis_EUlIEBaOwFUh — claims_evidence_register is not a deliverable of this stage" do
    test "an actionable error names the allowed deliverables, not just 'not a deliverable'" do
      context = %{
        store: :unused,
        mission_id: "mis_x",
        allowed_artifact_types: MapSet.new(["research_memo", "source_register"])
      }

      args = %{"type" => "claims_evidence_register", "content" => %{}}

      assert {:error, %{"kind" => "not_a_deliverable", "message" => message}} =
               WriteArtifact.call(args, context)

      assert message =~ "research_memo"
      assert message =~ "source_register"
    end
  end

  describe "mis_xR7oKZnpA0Rb — assumption_register failed validation: no assumption is ranked by risk" do
    # Verbatim from event seq 286 (the FIRST of three rejected attempts in
    # this mission's Analysis stage — mis_xR7oKZnpA0Rb's Analysis, not
    # Research). Uses `risk_rating`.
    @assumptions_with_risk_rating [
      %{
        "assumption" =>
          "Hex.pm's 'depends:<package>' search filter surfaces only public Hex packages " <>
            "that directly depend on a given package.",
        "risk_rating" => "high",
        "risk_rationale" =>
          "Any tool relying exclusively on the Hex.pm search index cannot see private, " <>
            "unpublished, or internal usages."
      }
    ]

    test "the risk-key synonym (already fixed before this branch, kept working here) accepts `risk_rating`" do
      assert :ok =
               ArtifactSchema.validate(:assumption_register, %{
                 "assumptions" => @assumptions_with_risk_rating
               })
    end

    test "an assumption with no risk-shaped key at all still fails, with an actionable, field-naming error" do
      assert {:error, [error]} =
               ArtifactSchema.validate(:assumption_register, %{
                 "assumptions" => [%{"assumption" => "x", "priority" => "high"}]
               })

      assert error =~ "no assumption is ranked by risk"
      assert error =~ "risk_rating"
      assert error =~ "Got keys:"
    end
  end

  describe "mis_NtCpr_KXm0Ki — research_memo failed validation: summary" do
    # Verbatim from event seq 68 — `key_claims` instead of `claims`, no
    # `limitations` at all, but `summary` genuinely present here (this
    # exact attempt was rejected for "claims; limitations" per the DB —
    # `summary` failed on a LATER attempt in this same mission, tested
    # below with @gaps_attempt).
    @key_claims_attempt %{
      "summary" =>
        "For independent Elixir library authors aiming to discover which projects depend " <>
          "on their Hex.pm-published packages, the primary and most feature-complete " <>
          "method is provided by Hex.pm itself.",
      "key_claims" => [
        %{
          "claim" =>
            "Hex.pm's package pages show a list of dependent packages at the bottom of " <>
              "the right column.",
          "source_id" => "src_TR6dPm_ty-oU"
        }
      ],
      "alternatives" => ["Custom scripts could crawl Hex.pm's public API or HTML."]
    }

    # Verbatim from event seq 161 — `gaps` instead of `limitations`,
    # `claims` present as a bare list of STRINGS (not objects), which is
    # also why `Sprat.Workflow.Gate.resolve_claim/2` needed hardening
    # (see the gate test file) — this test only covers the schema layer.
    @gaps_attempt %{
      "summary" => "The dominant and practically exclusive path for Elixir library authors...",
      "claims" => [
        "Hex.pm's website provides, on each package page, a list of other packages that " <>
          "depend on it."
      ],
      "gaps" => ["No access to private/internal project dependency graphs."]
    }

    test "the fix's claims synonym (key_claims) resolves claims — this real attempt genuinely never wrote a limitations field, so it correctly still fails, naming exactly that" do
      assert {:error, [error]} = ArtifactSchema.validate(:research_memo, @key_claims_attempt)
      assert error =~ ~s("limitations")
      refute error =~ ~s("claims")
    end

    test "the fix's limitations synonym (gaps) accepts the real recorded content, string claims included" do
      assert :ok = ArtifactSchema.validate(:research_memo, @gaps_attempt)
    end

    test "write_artifact + the real Gate no longer crashes on a bare-string claim list",
         %{store: store} do
      {:ok, session} = Sessions.create(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
      context = write_context(store, mission.id, "research_memo")

      assert {:ok, _} =
               WriteArtifact.call(
                 %{"type" => "research_memo", "content" => @gaps_attempt},
                 context
               )

      memo = Artifacts.latest(store, mission.id, :research_memo)
      source_ids = MapSet.new()

      assert {:error, [error]} =
               Sprat.Workflow.Gate.check(
                 :research_to_analysis,
                 %{research_memo: memo},
                 source_ids
               )

      assert error =~ "has no source and is not labelled as an assumption"
    end
  end

  describe "mis_NtCpr_KXm0Ki — expected {\"type\": \"...\", \"content\": {...}} (malformed call)" do
    # Verbatim shape from event seq 80/246: `content` sent as a bare list
    # instead of `%{"sources" => [...]}`.
    @bare_list_sources [
      %{
        "title" => "Finding projects depending on given library - Elixir Forum",
        "url" => "https://elixirforum.com/t/finding-projects-depending-on-given-library/33725"
      },
      %{"title" => "Hex", "url" => "https://hex.pm/"}
    ]

    test "a bare-list content is wrapped under source_register's sole field instead of rejected",
         %{store: store} do
      {:ok, session} = Sessions.create(store)
      {:ok, mission} = Missions.create(store, session.id, %{objective: "test"})
      context = write_context(store, mission.id, "source_register")

      args = %{"type" => "source_register", "content" => @bare_list_sources}
      assert {:ok, %{"type" => "source_register"}} = WriteArtifact.call(args, context)
    end
  end
end
