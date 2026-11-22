defmodule Sprat.Workflow.ArtifactSchema do
  @moduledoc """
  Pure per-artifact-type required-field checks (docs/spec-v1.md §5 Gates
  table: "the required artifacts exist, validate against their schema").
  `content` is the artifact's decoded JSON body (a map with string keys —
  it comes back off `write_artifact`'s tool arguments and off
  `Sprat.Store.Artifacts`' JSON-decoded `content` column, both string-keyed).

  Deliberately not a general JSON-Schema engine (ponytail: ten fixed
  shapes, hand-written checks are shorter and give better error text than
  a schema-validator dependency would for ten call sites). What IS shared
  across all ten is one small idea, applied uniformly instead of patched
  in per type as each defect surfaced live (the replay-harness brief's
  root-cause requirement): `@specs`/`@item_specs` are the *single* place a
  field's canonical name, accepted synonyms and a worked example are
  declared, and three things are generated from that one place instead of
  drifting apart by hand:

    * `normalize/2` — copies a synonym's value onto its canonical key
      (top-level via `@specs`, and inside each item of a list field via
      `@item_specs`) before anything is validated or stored, so a gate or
      a later reader only ever has to know the canonical name.
    * `validate/2` — every missing/malformed field named, with its
      canonical name, a one-line description, a worked example, and the
      keys actually received (never a bare field-name list with no
      indication of what would have satisfied it).
    * `describe/1` — the same field list rendered as prompt prose plus one
      full worked example artifact, so a stage's prompt (`Idea`/
      `Opportunity`) can splice in "what this artifact must look like"
      instead of maintaining separate hand-written prose that can say
      something the schema doesn't enforce, or omit something it does.

  Every synonym below is either observed directly in a live run's
  rejected `write_artifact` calls (noted inline) or added defensively by
  the same standard, per the build brief's item 8 audit, even where no
  live failure happened to hit that exact type yet.
  """

  @recommendations ~w(go revise validate_first stop)

  # Top-level field specs per artifact type: canonical name, accepted
  # synonyms (a model's actual past spellings, or a defensive guess of
  # the same shape), a one-line description and a worked example value.
  @specs %{
    intake_summary: [
      %{
        name: "objective",
        synonyms: ~w(goal idea),
        doc: "the restated objective (string)",
        example: "gym booking software for small studios"
      },
      %{
        name: "depth",
        synonyms: [],
        doc: "one of \"quick\", \"standard\", \"deep\"",
        example: "quick"
      },
      %{
        name: "open_questions",
        synonyms: ~w(questions clarifying_questions),
        doc:
          "list of at most three direction-changing questions (or the assumption made instead of asking)",
        example: ["target customer unclear — assumed small independent studios"]
      }
    ],
    # A live run wrote `practical_findings`/`findings`/`key_claims` instead
    # of `claims`, and `gaps` instead of `limitations`, and was rejected
    # every time by an error that never said the field name it wanted
    # (mis_EUlIEBaOwFUh, mis_xR7oKZnpA0Rb, mis_NtCpr_KXm0Ki — the
    # replay-harness brief's primary defect).
    research_memo: [
      %{
        name: "summary",
        synonyms: [],
        doc: "a short prose summary (string)",
        example: "Existing booking tools are clunky for single-location gyms."
      },
      %{
        name: "claims",
        synonyms: ~w(findings key_findings practical_findings key_claims material_claims),
        doc: "list of claim objects: {text, source_ids} or {text, is_assumption: true}",
        example: [%{"text" => "users want fewer taps", "is_assumption" => true}]
      },
      %{
        name: "limitations",
        synonyms: ~w(limitations_section caveats gaps),
        doc: "what the research did not cover (string, or list of strings/objects)",
        example: "no live web search available"
      }
    ],
    source_register: [
      %{
        name: "sources",
        synonyms: ~w(entries results),
        doc: "list of {title, url}",
        example: [%{"title" => "competitor app store page", "url" => "https://example.com/app"}]
      }
    ],
    competitor_matrix: [
      %{
        name: "competitors",
        synonyms: ~w(matrix comparison),
        doc: "list of {name, strengths, weaknesses}",
        example: [
          %{
            "name" => "CompetitorApp",
            "strengths" => "established brand",
            "weaknesses" => "no mobile app"
          }
        ]
      }
    ],
    assumption_register: [
      %{
        name: "assumptions",
        synonyms: [],
        doc: "list of {text, risk}",
        example: [%{"text" => "users will pay monthly", "risk" => "high"}]
      }
    ],
    product_directions: [
      %{
        name: "directions",
        synonyms: [],
        doc: "1-3 directions, each {customer, problem, value, scope, validation_approach}",
        example: [
          %{
            "customer" => "small gym owners",
            "problem" => "manual booking spreadsheets",
            "value" => "fewer no-shows",
            "scope" => "single-location booking calendar",
            "validation_approach" => "5 pilot gyms for 2 weeks"
          }
        ]
      }
    ],
    opportunity_scorecard: [
      %{
        name: "dimensions",
        synonyms: ~w(scores ratings),
        doc:
          "one entry per §6 dimension, each {name, rating (1-5 or \"unknown\"), evidence}. " <>
            "The names are fixed: " <>
            "pain_severity, willingness_to_pay, buyer_reachability, alternative_weakness, " <>
            "feasibility, unit_economics, founder_advantage. Rate \"unknown\" where you " <>
            "have no evidence — never guess, and never average",
        example: [
          %{"name" => "pain_severity", "rating" => 4, "evidence" => "src_1"},
          %{"name" => "willingness_to_pay", "rating" => "unknown", "evidence" => ""},
          %{"name" => "buyer_reachability", "rating" => 3, "evidence" => "src_2"},
          %{"name" => "alternative_weakness", "rating" => 4, "evidence" => "src_2"},
          %{"name" => "feasibility", "rating" => 4, "evidence" => "src_3"},
          %{"name" => "unit_economics", "rating" => "unknown", "evidence" => ""},
          %{"name" => "founder_advantage", "rating" => 2, "evidence" => "src_3"}
        ]
      }
    ],
    recommendation_memo: [
      %{
        name: "recommendation",
        synonyms: ~w(decision),
        doc: "one of go, revise, validate_first, stop",
        example: "go"
      },
      %{
        name: "evidence",
        synonyms: ~w(sources evidence_ids source_ids),
        doc: "list of existing source ids this recommendation cites",
        example: ["src_test_1"]
      },
      %{
        name: "tradeoffs",
        synonyms: ~w(tradeoff risks),
        doc: "the tradeoffs of this recommendation (string)",
        example: "limited to a single location for the pilot"
      }
    ],
    product_brief: [
      %{
        name: "problem",
        synonyms: ~w(problem_statement),
        doc: "the problem (string)",
        example: "manual booking spreadsheets"
      },
      %{
        name: "customer",
        synonyms: ~w(target_customer),
        doc: "the target customer (string)",
        example: "small gym owners"
      },
      %{
        name: "mvp_scope",
        synonyms: ~w(scope),
        doc: "the smallest useful scope (string)",
        example: "single-location booking calendar"
      }
    ],
    # docs/spec-v2.md §8: profile, data model, components, external
    # services, what is excluded and why, and an estimated build cost.
    # The design stage's gate (§5) additionally requires the named
    # `profile` to be one `Sprat.Build.Profile` actually ships — checked
    # in `extra_checks/2` below, not here, since this module stays a pure
    # per-type shape check with no knowledge of the profile registry.
    technical_design: [
      %{
        name: "profile",
        synonyms: ~w(stack stack_profile),
        doc: "the stack profile name (e.g. \"elixir-phoenix\")",
        example: "elixir-phoenix"
      },
      %{
        name: "data_model",
        synonyms: ~w(schema),
        doc: "{entities: [{name, fields}], relations: [{from, to, kind}]}",
        example: %{
          "entities" => [
            %{"name" => "Gym", "fields" => ["name", "address"]},
            %{"name" => "Booking", "fields" => ["gym_id", "starts_at"]}
          ],
          "relations" => [%{"from" => "Gym", "to" => "Booking", "kind" => "has_many"}]
        }
      },
      %{
        name: "components",
        synonyms: ~w(modules),
        doc: "list of the app's main components/contexts (list of strings or objects)",
        example: ["Bookings context", "web (LiveView) layer"]
      },
      %{
        name: "external_services",
        synonyms: ~w(integrations),
        doc: "list of external services this MVP talks to, or [] if none",
        example: [],
        allow_blank: true
      },
      %{
        name: "excluded_scope",
        synonyms: ~w(exclusions out_of_scope not_building),
        doc: "list of {item, reason} — what is deliberately not built, and why",
        example: [%{"item" => "payments", "reason" => "not in the brief's MVP boundary"}]
      },
      %{
        name: "estimated_cost",
        synonyms: ~w(cost_estimate estimate),
        doc: "the estimated build cost, labelled as an estimate (string)",
        example: "~$3-5 in model spend (estimate)"
      }
    ],
    validation_plan: [
      %{
        name: "experiments",
        synonyms: [],
        doc:
          "list of {assumption, participant_criteria, method, budget, duration, " <>
            "success_threshold, failure_threshold, decision}",
        example: [
          %{
            "assumption" => "users will pay monthly",
            "participant_criteria" => "5 pilot gyms",
            "method" => "in-app trial",
            "budget" => "$500",
            "duration" => "2 weeks",
            "success_threshold" => "3 of 5 gyms convert",
            "failure_threshold" => "0 of 5 gyms convert",
            "decision" => "scale or pivot"
          }
        ]
      }
    ]
  }

  # Item-level synonyms: for a list-of-objects field (named by the outer
  # key), the same tolerance applied to each object's own fields — the
  # `risk`/`risk_rating`/`risk_rank`/`rank` case, generalised. Only fields
  # actually checked downstream (by this module's own shape validators, or
  # by `Sprat.Workflow.Gate`'s claim/evidence checks) need an entry here;
  # extra fields an item carries are never rejected.
  @item_specs %{
    research_memo: %{
      "claims" => %{
        "text" => ~w(claim fact),
        # `source_id` (singular) shows up as a bare string in the wild —
        # `normalize/2` wraps it in a list when copying onto the plural
        # canonical key.
        "source_ids" => ~w(source_id evidence)
      }
    },
    assumption_register: %{
      "assumptions" => %{"risk" => ~w(risk_rating risk_rank rank severity)}
    },
    product_directions: %{
      "directions" => %{
        "customer" => ~w(target_customer),
        "problem" => ~w(pain_point),
        "value" => ~w(value_prop benefit),
        "scope" => ~w(mvp_scope),
        "validation_approach" => ~w(validation)
      }
    },
    validation_plan: %{
      "experiments" => %{
        "assumption" => ~w(hypothesis),
        "participant_criteria" => ~w(participants),
        "method" => ~w(approach),
        "success_threshold" => ~w(success_criteria),
        "failure_threshold" => ~w(failure_criteria),
        "decision" => ~w(next_step)
      }
    }
  }

  @doc "Every artifact type this module knows how to validate."
  def types, do: Map.keys(@specs)

  @doc "The canonical top-level field names `type` requires, in declared order."
  def fields(type) when is_map_key(@specs, type), do: Enum.map(@specs[type], & &1.name)

  @doc """
  Copies each field's synonym value onto its canonical key (top-level, and
  inside each item of a list field) wherever the canonical key is absent
  or blank and a synonym is present. Non-destructive: the synonym key is
  left in place too. Safe to call on content this module doesn't know
  (returns it unchanged) or on a malformed shape (a non-map, a field that
  isn't the type it should be) — those are `validate/2`'s job to reject,
  with an actionable message; `normalize/2` never raises.
  """
  def normalize(type, content) when is_map(content) do
    content
    |> normalize_top(Map.get(@specs, type, []))
    |> normalize_items(Map.get(@item_specs, type, %{}))
  end

  def normalize(_type, content), do: content

  defp normalize_top(content, specs) do
    Enum.reduce(specs, content, fn %{name: name, synonyms: synonyms}, acc ->
      if blank?(Map.get(acc, name)) do
        case find_synonym(acc, synonyms) do
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      else
        acc
      end
    end)
  end

  defp normalize_items(content, item_specs) do
    Enum.reduce(item_specs, content, fn {list_field, field_synonyms}, acc ->
      case Map.get(acc, list_field) do
        items when is_list(items) ->
          Map.put(acc, list_field, Enum.map(items, &normalize_item(&1, field_synonyms)))

        _ ->
          acc
      end
    end)
  end

  defp normalize_item(item, field_synonyms) when is_map(item) do
    Enum.reduce(field_synonyms, item, fn {canonical, synonyms}, acc ->
      if blank?(Map.get(acc, canonical)) do
        case find_synonym(acc, synonyms) do
          nil -> acc
          value -> Map.put(acc, canonical, listify(canonical, value))
        end
      else
        acc
      end
    end)
  end

  defp normalize_item(item, _field_synonyms), do: item

  defp find_synonym(map, synonyms), do: Enum.find_value(synonyms, &non_blank(Map.get(map, &1)))

  defp non_blank(value), do: if(blank?(value), do: nil, else: value)

  # A plural canonical field (`source_ids`) fed a singular synonym's
  # scalar value (`source_id`) needs wrapping, or every later `is_list`
  # check on it fails.
  defp listify(canonical, value) when is_binary(value) do
    if String.ends_with?(canonical, "s") and not is_list(value), do: [value], else: value
  end

  defp listify(_canonical, value), do: value

  # A list-of-items field whose own item-shape validator (below) already
  # gives a more specific "at least one X is required"/"X must be a list"
  # message than the generic missing-field check would — routed straight
  # there instead of also being subject to `require_fields/2`, so an empty
  # list gets that specific message, not the generic one.
  @delegated_to_item_validator MapSet.new([
                                 :assumption_register,
                                 :product_directions,
                                 :validation_plan
                               ])

  @doc "`:ok` or `{:error, [reason, ...]}` — every missing/invalid field named, not just the first."
  def validate(type, content) when is_map_key(@specs, type) do
    content = normalize(type, content)

    if MapSet.member?(@delegated_to_item_validator, type) do
      extra_checks(type, content)
    else
      case require_fields(type, content) do
        :ok -> extra_checks(type, content)
        error -> error
      end
    end
  end

  def validate(type, _content), do: {:error, ["unknown artifact type: #{type}"]}

  defp extra_checks(:assumption_register, content),
    do: validate_ranked(Map.get(content, "assumptions", []))

  defp extra_checks(:product_directions, content),
    do: validate_directions(Map.get(content, "directions", []))

  defp extra_checks(:validation_plan, content),
    do: validate_experiments(Map.get(content, "experiments", []))

  defp extra_checks(:recommendation_memo, content) do
    case validate_recommendation(content["recommendation"]) do
      :ok -> :ok
      {:error, errs} -> {:error, errs}
    end
  end

  # §6 fixes the dimensions and their weights, and says the code does the
  # arithmetic. A live discovery mission invented its own six dimensions
  # (underservedness, network_effects_or_data_flywheel, ...) and supplied its
  # own total, because nothing checked either.
  defp extra_checks(:opportunity_scorecard, content) do
    required = Sprat.Workflow.Scorecard.default_weights() |> Map.keys() |> Enum.map(&to_string/1)

    present =
      content
      |> Map.get("dimensions", [])
      |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, "dimension")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    case Enum.reject(required, &MapSet.member?(present, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         [
           "opportunity_scorecard is missing the §6 dimension(s): #{Enum.join(missing, ", ")}. " <>
             "Every dimension must appear, rated 1-5 or \"unknown\" with its evidence. " <>
             "Got: #{present |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}"
         ]}
    end
  end

  # docs/spec-v2.md §5 Design->Scaffold gate: "names a supported profile;
  # the data model has entities and relations; excluded scope is listed."
  # A brief needing an unsupported stack stops here, named explicitly
  # (§4: "does not improvise a stack it cannot verify") — never a bare
  # "invalid profile".
  defp extra_checks(:technical_design, content) do
    results = [
      validate_profile(content["profile"]),
      validate_data_model(content["data_model"]),
      validate_excluded_scope(content["excluded_scope"])
    ]

    errors =
      Enum.flat_map(results, fn
        :ok -> []
        {:error, errs} -> errs
      end)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp extra_checks(_type, _content), do: :ok

  defp validate_profile(profile) when is_binary(profile) and profile != "" do
    supported = Sprat.Build.Profile.names()

    if profile in supported do
      :ok
    else
      {:error,
       [
         "technical_design names an unsupported profile: #{inspect(profile)} — " <>
           "supported profiles: #{Enum.join(supported, ", ")}"
       ]}
    end
  end

  defp validate_profile(_), do: {:error, ["technical_design \"profile\" must be a string"]}

  defp validate_data_model(%{"entities" => entities, "relations" => relations})
       when is_list(entities) and is_list(relations) do
    if entities == [] do
      {:error, ["technical_design data_model must have at least one entity"]}
    else
      :ok
    end
  end

  defp validate_data_model(_) do
    {:error,
     [
       "technical_design \"data_model\" must be {entities: [...], relations: [...]} " <>
         "with at least one entity"
     ]}
  end

  defp validate_excluded_scope(scope) when is_list(scope) and scope != [], do: :ok

  defp validate_excluded_scope(_) do
    {:error,
     [
       "technical_design \"excluded_scope\" must be a non-empty list of what is deliberately " <>
         "not built and why"
     ]}
  end

  defp require_fields(type, content) do
    specs = Map.fetch!(@specs, type)
    missing = Enum.filter(specs, &missing_field?(content, &1))

    if missing == [] do
      :ok
    else
      {:error, Enum.map(missing, &field_error(type, &1, content))}
    end
  end

  # A field flagged `allow_blank: true` (currently only
  # `technical_design`'s "external_services") is genuinely satisfied by
  # `[]` — "or [] if none" is a real answer, not a missing one — so it's
  # only "missing" when the key is absent entirely. Every other field
  # keeps the plain `blank?/1` check.
  defp missing_field?(content, %{allow_blank: true} = spec),
    do: not Map.has_key?(content, spec.name)

  defp missing_field?(content, spec), do: blank?(Map.get(content, spec.name))

  # Actionable by construction: canonical field name, what it means, an
  # example value, the synonyms already tolerated, and the keys the
  # artifact actually arrived with — the exact information a live run's
  # error ("research_memo failed validation: claims; limitations") never
  # gave the model a chance to act on.
  defp field_error(type, spec, content) do
    base =
      "#{type} missing required field \"#{spec.name}\": #{spec.doc}. Example: " <>
        "#{JSON.encode!(spec.example)}."

    with_synonyms =
      if spec.synonyms == [] do
        base
      else
        base <> " Also accepted: #{Enum.join(spec.synonyms, ", ")}."
      end

    with_synonyms <> " Got fields: #{content |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{} = m) when map_size(m) == 0, do: true
  defp blank?(_), do: false

  defp validate_ranked(assumptions) when is_list(assumptions) do
    if assumptions == [] do
      {:error, ["at least one assumption is required"]}
    else
      spec = Map.fetch!(@item_specs, :assumption_register)["assumptions"]["risk"]

      if Enum.any?(assumptions, &(is_map(&1) and Map.has_key?(&1, "risk"))) do
        :ok
      else
        keys = assumptions |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()

        {:error,
         [
           "no assumption is ranked by risk: each assumption needs a \"risk\" field " <>
             "(e.g. \"risk\": \"high\"). Also accepted: #{Enum.join(spec, ", ")}. " <>
             "Got keys: #{Enum.join(keys, ", ")}"
         ]}
      end
    end
  end

  defp validate_ranked(_), do: {:error, ["assumptions must be a list"]}

  defp validate_directions(directions) when is_list(directions) do
    required = ~w(customer problem value scope validation_approach)

    cond do
      directions == [] ->
        {:error, ["at least one direction is required"]}

      length(directions) > 3 ->
        {:error, ["at most three directions are allowed, got #{length(directions)}"]}

      true ->
        errors =
          directions
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {d, i} ->
            Enum.filter(required, &blank?(Map.get(d, &1)))
            |> Enum.map(&"direction #{i} missing \"#{&1}\" (example: #{direction_example(&1)})")
          end)

        if errors == [], do: :ok, else: {:error, errors}
    end
  end

  defp validate_directions(_), do: {:error, ["directions must be a list"]}

  defp direction_example(field) do
    [example] = @specs.product_directions |> Enum.map(& &1.example) |> List.flatten()
    JSON.encode!(Map.fetch!(example, field))
  end

  defp validate_recommendation(rec) when rec in @recommendations, do: :ok

  defp validate_recommendation(other),
    do:
      {:error,
       [
         "recommendation must be one of #{Enum.join(@recommendations, ", ")}, got #{inspect(other)}"
       ]}

  defp validate_experiments(experiments) when is_list(experiments) do
    required =
      ~w(assumption participant_criteria method budget duration success_threshold failure_threshold decision)

    if experiments == [] do
      {:error, ["at least one experiment is required"]}
    else
      errors =
        experiments
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {e, i} ->
          Enum.filter(required, &blank?(Map.get(e, &1)))
          |> Enum.map(&"experiment #{i} missing \"#{&1}\"")
        end)

      if errors == [], do: :ok, else: {:error, errors}
    end
  end

  defp validate_experiments(_), do: {:error, ["experiments must be a list"]}

  @doc """
  Prompt-facing shape description for `type`, generated from `@specs` —
  the single source of truth `validate/2` also reads — plus one full
  worked example artifact (build brief item 4: "Include one worked
  example value per artifact type in the generated description").
  """
  def describe(type) when is_map_key(@specs, type) do
    specs = Map.fetch!(@specs, type)

    fields =
      Enum.map_join(specs, "\n", fn spec ->
        synonym_note =
          if spec.synonyms == [], do: "", else: " (also: #{Enum.join(spec.synonyms, ", ")})"

        "  - #{spec.name}#{synonym_note}: #{spec.doc}"
      end)

    "#{type} must include:\n#{fields}\nWorked example:\n#{JSON.encode!(example(type))}"
  end

  @doc "Merges every field's worked example into one full example artifact for `type`."
  def example(type) when is_map_key(@specs, type) do
    @specs |> Map.fetch!(type) |> Map.new(&{&1.name, &1.example})
  end
end
