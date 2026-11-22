defmodule Sprat.Workflow.Gate do
  @moduledoc """
  Pure gate checks (docs/spec-v1.md §5 Gates table): "the required
  artifacts exist, validate against their schema and reference existing
  sources. An LLM judges content quality; code judges completeness." This
  module is the code half — the completeness rule — and it always names
  the specific missing item (§10 "Gate result: ✓ or ✗ with the specific
  missing item"). The content-quality half (an unlabelled unsourced claim
  slipping past `is_assumption`) is the stage's own prompt asking the
  model to label honestly; this gate enforces the *structural* rule that
  every non-assumption claim's `source_ids` actually exist.

  `artifacts` maps artifact type atoms to that type's latest version's
  decoded content (string-keyed maps, straight off `Sprat.Store.Artifacts`
  or a stage's `write_artifact` calls). `source_ids` is the set of source
  ids that actually exist in this mission (`Sprat.Store.Sources.by_mission/2`
  ids) — passing this in rather than a store connection is what keeps this
  module pure and fast to test.
  """

  alias Sprat.Workflow.ArtifactSchema

  @doc """
  Checks a gate. `recorded` maps claim ids to the claims already written by
  `record_claim`, so a memo may reference them instead of restating them.
  `stale_types` (docs/spec-v1.md §10, default empty — every existing
  caller/test that predates steering sees the exact same behaviour as
  before) is the set of artifact type atoms `Sprat.Store.Artifacts.stale_types/2`
  currently has flagged for this mission: a gate never lets a stale
  artifact satisfy its own existence requirement, however good its
  content — see `require_artifact/3`.
  """
  def check(gate, artifacts, source_ids), do: check(gate, artifacts, source_ids, %{})

  def check(gate, artifacts, source_ids, recorded),
    do: check(gate, artifacts, source_ids, recorded, MapSet.new())

  def check(gate, artifacts, source_ids, recorded, stale_types),
    do: check(gate, artifacts, source_ids, recorded, stale_types, [])

  def check(:intake_to_research, artifacts, _source_ids, _recorded, stale_types, _runs) do
    require_artifact(artifacts, :intake_summary, stale_types)
  end

  def check(:research_to_analysis, artifacts, source_ids, recorded, stale_types, _runs) do
    with :ok <- require_artifact(artifacts, :research_memo, stale_types) do
      check_claims_cite_sources(artifacts[:research_memo], source_ids, recorded)
    end
  end

  def check(:analysis_gate, artifacts, _source_ids, _recorded, stale_types, _runs) do
    require_artifact(artifacts, :assumption_register, stale_types)
  end

  def check(:recommendation_to_delivery, artifacts, source_ids, _recorded, stale_types, _runs) do
    with :ok <- require_artifact(artifacts, :recommendation_memo, stale_types) do
      check_evidence_cites_sources(artifacts[:recommendation_memo], source_ids)
    end
  end

  # Idea shaping delivers a brief and a plan; opportunity discovery delivers a
  # plan alone (docs/spec-v1.md §5B ends at "a validation plan with interview
  # questions, prototype scope, willingness-to-pay tests and success/failure
  # thresholds"). A shared gate demanded a product_brief from both, so a
  # discovery mission that had passed all six earlier stages failed at the
  # last one asking for an artifact its workflow never produces.
  def check(:delivery_gate, artifacts, _source_ids, _recorded, stale_types, _runs) do
    [:product_brief, :validation_plan]
    |> Enum.map(&require_artifact(artifacts, &1, stale_types))
    |> collect_errors()
  end

  def check(:validation_plan_gate, artifacts, _source_ids, _recorded, stale_types, _runs) do
    require_artifact(artifacts, :validation_plan, stale_types)
  end

  # docs/spec-v2.md §5 Design->Scaffold gate: "Design artifact validates;
  # names a supported profile; data model has entities and relations;
  # excluded scope is listed." Every one of those is a `technical_design`
  # shape/content rule, already enforced by
  # `Sprat.Workflow.ArtifactSchema.validate/2`'s `extra_checks/2` for that
  # type (single source of truth, same as every other gate here) —
  # `require_artifact/3` runs it.
  def check(:design_to_scaffold, artifacts, _source_ids, _recorded, stale_types, _runs) do
    require_artifact(artifacts, :technical_design, stale_types)
  end

  # docs/spec-v2.md §5 Scaffold->Plan gate: "The scaffold runs: install
  # succeeded, run command starts, health check returns, recorded with
  # command, exit code and output hash." Unlike every other gate, this
  # one checks *execution evidence* (`runs`, `Sprat.Store.Runs` rows for
  # this mission), never an artifact — a scaffold that "should work" but
  # was never actually started/health-checked fails here, by name, with
  # no Runs row to point to.
  def check(:scaffold_gate, _artifacts, _source_ids, _recorded, _stale_types, runs) do
    [
      require_successful_run(runs, "install", "dependency install"),
      require_successful_run(runs, "run", "the run command starting"),
      require_successful_run(runs, "health_check", "the health check")
    ]
    |> collect_errors()
  end

  def check(other, _artifacts, _source_ids, _recorded, _stale_types, _runs),
    do: {:error, ["unknown gate: #{other}"]}

  defp require_successful_run(runs, purpose, description) do
    case Enum.find(runs, &(&1.purpose == purpose)) do
      nil ->
        {:error, ["no #{description} run is recorded (purpose: #{purpose})"]}

      %{exit_code: 0} ->
        :ok

      %{exit_code: exit_code} ->
        {:error,
         ["#{description} failed (purpose: #{purpose}, exit code: #{inspect(exit_code)})"]}
    end
  end

  # -- artifact existence + schema -----------------------------------------

  # Staleness is checked before existence/schema, and is a hard stop
  # regardless of how good the stale content is — docs/spec-v1.md §10 "A
  # later stage's gate must not treat a stale artifact as satisfying a
  # requirement if the steering invalidated it". This is deliberately
  # narrow: it only blocks *this* gate's own `require_artifact` calls (the
  # handful of artifact types each gate names explicitly above) from
  # treating a flagged-stale artifact as satisfying THIS check. It does
  # not cascade to a stage's `required_inputs` context (a stale artifact's
  # latest content still reaches the model there, alongside the steering
  # that made it stale — see `Sprat.Orchestrator.build_stage_context/5` —
  # so the model can judge and, if it agrees, rewrite it), it does not
  # touch any artifact type never flagged stale, and it clears itself the
  # moment `Sprat.Store.Artifacts.write/3` writes any new version of that
  # type, whether or not that rewrite actually addressed the steering.
  defp require_artifact(artifacts, type, stale_types) do
    if MapSet.member?(stale_types, type) do
      {:error,
       [
         "#{type} artifact is stale (user steering changed scope after it was written) — " <>
           "rewrite it before this gate can pass"
       ]}
    else
      require_artifact(artifacts, type)
    end
  end

  defp require_artifact(artifacts, type) do
    case Map.get(artifacts, type) do
      nil ->
        {:error, ["#{type} artifact does not exist"]}

      %{"incomplete" => true, "reason" => reason} when is_binary(reason) and reason != "" ->
        :ok

      content ->
        type
        |> ArtifactSchema.validate(content)
        |> tag_errors(type)
    end
  end

  defp tag_errors(:ok, _type), do: :ok
  defp tag_errors({:error, errors}, type), do: {:error, Enum.map(errors, &"#{type}: #{&1}")}

  defp collect_errors(results) do
    errors =
      Enum.flat_map(results, fn
        :ok -> []
        {:error, errs} -> errs
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  # -- claim/evidence -> source existence ------------------------------------

  # A memo may state a claim inline (`%{"text" =>, "source_ids" =>}`) or, as a
  # live run did, reference one it already recorded with `record_claim`
  # (`%{"claim_id" => "clm_..."}`). The second form is the better one — the
  # claim's text, confidence and sources live in the store rather than being
  # duplicated — but the gate used to read it as a claim with no text and no
  # source, and rejected every stage that used it.
  defp check_claims_cite_sources(memo, source_ids, recorded) do
    claims = Map.get(memo, "claims", [])

    missing =
      claims
      |> Enum.map(&resolve_claim(&1, recorded))
      |> Enum.reject(&(&1["is_assumption"] == true))
      |> Enum.flat_map(fn claim ->
        ids = Map.get(claim, "source_ids", [])

        cond do
          claim["unknown_claim_id"] ->
            ["unknown claim id: #{claim["unknown_claim_id"]}"]

          ids == [] ->
            ["claim #{describe_claim(claim)} has no source and is not labelled as an assumption"]

          true ->
            ids
            |> Enum.filter(&(not MapSet.member?(source_ids, &1)))
            |> Enum.map(&"unknown source id: #{&1}")
        end
      end)

    if missing == [], do: :ok, else: {:error, missing}
  end

  defp resolve_claim(%{"claim_id" => id} = claim, recorded) when is_binary(id) do
    case Map.get(recorded, id) do
      nil -> Map.put(claim, "unknown_claim_id", id)
      resolved -> Map.merge(resolved, Map.delete(claim, "claim_id"))
    end
  end

  # A live run's research_memo listed claims as bare strings, not objects
  # (mis_NtCpr_KXm0Ki) — treated as unsourced claim text rather than
  # crashing on `claim["source_ids"]` against a binary.
  defp resolve_claim(claim, _recorded) when is_binary(claim), do: %{"text" => claim}
  defp resolve_claim(claim, _recorded), do: claim

  defp describe_claim(%{"text" => text}) when is_binary(text),
    do: inspect(String.slice(text, 0, 60))

  defp describe_claim(claim), do: inspect(Map.take(claim, ["claim_id", "section"]))

  defp check_evidence_cites_sources(memo, source_ids) do
    ids = Map.get(memo, "evidence", [])
    missing = Enum.filter(ids, &(not MapSet.member?(source_ids, &1)))
    if missing == [], do: :ok, else: {:error, Enum.map(missing, &"unknown source id: #{&1}")}
  end
end
