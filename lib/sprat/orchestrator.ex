defmodule Sprat.Orchestrator do
  @moduledoc """
  Walks a `Sprat.Workflow.Template` stage by stage (docs/spec-v1.md §5/§8):
  creates a `task` per stage, assembles its context package, runs
  `Sprat.Agent.Loop`, records the stage's deliverables as artifacts, runs
  the stage's gate, and advances, retries within the review-round limit,
  or stops. Mirrors `Sprat.Mission` closely on purpose — same busy guard,
  same cancel flag, same safe-transition pattern — because that module is
  this one's proven prior art for exactly this "run a loop, settle a
  task" problem; the difference is the outer loop over stages instead of
  a single fixed prompt.

  One role runs every stage in this build: `stage.role` is read, never
  hardcoded, so a later build can vary it per stage without touching this
  module (build brief scope decision).
  """

  alias Sprat.Agent.Loop

  alias Sprat.Agent.Tools.{
    Calculate,
    RecordClaim,
    RecordSource,
    WebFetch,
    WebSearch,
    WriteArtifact
  }

  alias Sprat.Model.{OpenAI, Pricing}

  alias Sprat.Store.{
    Artifacts,
    Claims,
    Decisions,
    Events,
    Grants,
    Messages,
    Missions,
    Runs,
    Sources,
    Tasks
  }

  alias Sprat.{Budget, Secrets, Session, Steering}
  alias Sprat.Session.PubSub
  alias Sprat.Workflow.{Gate, Template}

  @review_rounds 1

  # docs/spec-v1.md §8: "The Orchestrator stops a task that makes three
  # consecutive model turns with no new source, artifact change or state
  # progress, and surfaces it as stalled."
  @stall_turns 3

  defp active_key(session_id), do: {__MODULE__, :active, session_id}
  defp active?(session_id), do: :persistent_term.get(active_key(session_id), false)
  defp mark_active(session_id), do: :persistent_term.put(active_key(session_id), true)
  defp clear_active(session_id), do: :persistent_term.erase(active_key(session_id))

  @doc """
  True while a staged mission is running (or paused mid-run — a fetch
  approval, a failure's retry/skip/abandon prompt — anything that hasn't
  reached a terminal state or the Directions choice point yet) for
  `session_id`. `Sprat.Session.Commands.handle_plain/3` reads this to
  decide whether a plain message is a fresh submission or mid-mission
  steering (docs/spec-v1.md §10) for the mission `active_mission_id/1`
  names.
  """
  def busy?(session_id), do: active?(session_id)

  defp active_mission_key(session_id), do: {__MODULE__, :active_mission, session_id}

  defp mark_active_mission(session_id, mission_id),
    do: :persistent_term.put(active_mission_key(session_id), mission_id)

  defp clear_active_mission(session_id),
    do: :persistent_term.erase(active_mission_key(session_id))

  @doc """
  The mission id `busy?/1` is currently running for `session_id`, or
  `nil` — briefly, in the instant between `start/5` marking the session
  active and `run/5` actually creating the mission row, `busy?/1` can be
  true while this is still `nil`; a caller queuing steering treats that
  as "nothing to attach it to yet" (see `Sprat.Session.Commands`).
  """
  def active_mission_id(session_id),
    do: :persistent_term.get(active_mission_key(session_id), nil)

  defp cancel_key(session_id), do: {__MODULE__, :cancel, session_id}
  def cancel(session_id), do: :persistent_term.put(cancel_key(session_id), true)
  defp cancelled?(session_id), do: :persistent_term.get(cancel_key(session_id), false)
  defp clear_cancel(session_id), do: :persistent_term.erase(cancel_key(session_id))

  # -- stall detection (docs/spec-v1.md §8) ---------------------------------
  #
  # Scoped per `task_id` (a fresh id every `run_stage/11` call, and reset
  # by `init_stall_tracker/3` on every `retry_stage/13` attempt too) so a
  # stall in one stage, or one retry attempt, never bleeds into the next
  # stage's or attempt's fresh run.
  #
  # `record_turn_progress/3` is the only thing that advances the streak,
  # and it runs exactly once per completed turn via `Loop`'s
  # `on_turn_end`. `stalled?/1` is a read-only check of the current
  # streak — safe to call from `cancel?`, which `Sprat.Agent.Loop` may
  # poll more than once per turn (real model adapters poll it mid-stream)
  # without that polling itself counting as "no progress".
  defp stall_tracker_key(task_id), do: {__MODULE__, :stall, task_id}

  defp init_stall_tracker(store, mission_id, task_id) do
    :persistent_term.put(
      stall_tracker_key(task_id),
      {progress_snapshot(store, mission_id, task_id), 0}
    )
  end

  defp clear_stall_tracker(task_id) do
    clear_deadline(task_id)
    :persistent_term.erase(stall_tracker_key(task_id))
  end

  # Everything that produces evidence counts as progress: §8 stops a stage
  # that produces "no new evidence, artifact change, or state progress". Two
  # live runs died here — one after searching and fetching six pages that had
  # not yet become sources, one while it was recording claims off sources it
  # had already gathered.
  #
  # A REJECTED `write_artifact` is also counted (`rejected_writes/2`,
  # scoped to this task): a stage actively retrying its deliverable after a
  # validation error is making progress even when validation says no — the
  # replay-harness brief's item 6. Without this, three straight rejected
  # `write_artifact` turns trip the stall detector on their own, exactly
  # like the live "research_memo failed validation" runs that were killed
  # as stalled with a perfectly good final attempt one turn away. That
  # exemption is itself bounded — see `reject_cap_exceeded?/2` — so a
  # genuinely stuck loop (same type, rejected, forever) still terminates.
  defp progress_snapshot(store, mission_id, task_id) do
    sources = length(Sources.by_mission(store, mission_id))
    claims = length(Claims.by_mission(store, mission_id))

    artifacts =
      Artifacts.by_mission(store, mission_id) |> Enum.map(& &1.latest_version) |> Enum.sum()

    {sources, claims, artifacts, successful_fetches(store, mission_id),
     rejected_writes(store, task_id)}
  end

  defp successful_fetches(store, mission_id) do
    store
    |> Events.by_mission(mission_id)
    |> Enum.count(fn event ->
      event.type == "tool.completed" and evidence_fetch?(decode_payload(event.payload))
    end)
  end

  # Events store their payload as the raw JSON column, not a decoded map.
  defp decode_payload(payload) when is_binary(payload) do
    case JSON.decode(payload) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_payload(payload) when is_map(payload), do: payload
  defp decode_payload(_), do: %{}

  defp evidence_fetch?(payload) do
    payload["ok?"] == true and payload["tool"] in ["web_fetch", "web_search"]
  end

  defp rejected_writes(store, task_id) do
    store |> Events.by_task(task_id) |> Enum.count(&rejected_write?/1)
  end

  defp rejected_write?(%{type: "tool.completed"} = event) do
    payload = decode_payload(event.payload)
    payload["tool"] == "write_artifact" and payload["ok?"] == false
  end

  defp rejected_write?(_event), do: false

  # A stage actively retrying the SAME artifact type after each rejection
  # is still "no new evidence, artifact change, or state progress" once it
  # keeps failing indefinitely — §8's stall exemption above (item 6 of the
  # replay-harness brief) can't be unconditional or a stage stuck writing
  # garbage would just never stop. Capped at 5 consecutive rejections of
  # one type: generous enough that a model correcting field names one
  # mistake at a time (the exact shape every live failure took) always has
  # room to succeed, tight enough to fail fast once it's clearly not
  # converging.
  @max_consecutive_same_type_rejects 5

  defp reject_cap_exceeded?(store, task_id) do
    case same_type_reject_streak(store, task_id) do
      {_type, streak} -> streak >= @max_consecutive_same_type_rejects
      nil -> false
    end
  end

  # The trailing run of `tool.completed` `write_artifact` rejections of the
  # SAME artifact type, oldest-to-newest task events read from the tail
  # backwards. `nil` once anything else happens (a successful write, a
  # different tool, or a rejection of a different type) — only an
  # unbroken run of the same failure counts toward the cap.
  defp same_type_reject_streak(store, task_id) do
    store
    |> Events.by_task(task_id)
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn event, acc ->
      if event.type == "tool.completed" do
        reject_streak_step(acc, decode_payload(event.payload))
      else
        {:cont, acc}
      end
    end)
  end

  defp reject_streak_step(acc, %{"tool" => "write_artifact", "ok?" => false} = payload) do
    case acc do
      nil ->
        {:cont, {payload["artifact_type"], 1}}

      {type, count} ->
        if payload["artifact_type"] == type, do: {:cont, {type, count + 1}}, else: {:halt, acc}
    end
  end

  defp reject_streak_step(acc, _payload), do: {:halt, acc}

  defp record_turn_progress(store, mission_id, task_id) do
    {last_snapshot, streak} =
      :persistent_term.get(stall_tracker_key(task_id), {{0, 0, 0, 0, 0}, 0})

    current = progress_snapshot(store, mission_id, task_id)
    next_streak = if current == last_snapshot, do: streak + 1, else: 0
    :persistent_term.put(stall_tracker_key(task_id), {current, next_streak})
    :ok
  end

  # §8 gives each stage wall-time, call and token limits, and Depth defines
  # all three — but only `model_calls` was ever enforced, so a "quick" stage
  # ran for a quarter of an hour and gathered 21 sources against a 5-10
  # target. The deadline is checked from the same `cancel?` the loop already
  # polls between turns.
  defp deadline_key(task_id), do: {__MODULE__, :deadline, task_id}

  defp set_deadline(task_id, wall_seconds) when is_integer(wall_seconds) do
    :persistent_term.put(deadline_key(task_id), System.monotonic_time(:second) + wall_seconds)
  end

  defp set_deadline(_task_id, _), do: :ok

  defp clear_deadline(task_id), do: :persistent_term.erase(deadline_key(task_id))

  defp past_deadline?(task_id) do
    case :persistent_term.get(deadline_key(task_id), nil) do
      nil -> false
      at -> System.monotonic_time(:second) >= at
    end
  end

  defp stalled?(task_id) do
    {_snapshot, streak} = :persistent_term.get(stall_tracker_key(task_id), {{0, 0, 0, 0}, 0})
    streak >= @stall_turns
  end

  # -- per-stage real outcome (checklist honesty) ----------------------------
  #
  # `broadcast_checklist/5` used to infer a past stage's status purely from
  # its position in the template (`stage_before?/3`) — a stage the user
  # skipped after a failure is, by definition, "before" whatever comes
  # after it, so it always rendered `:done`, the same glyph as a stage
  # whose gate genuinely passed. This tracker records what actually
  # happened to each stage of the CURRENT mission (`:done` from
  # `finish_stage/12`'s gate-passed branch, `:skipped` from
  # `offer_recovery/12`'s skip branch) so the checklist can render the
  # truth for every earlier stage instead of assuming success.
  #
  # Cleared at the mission's genuine terminal points (delivered, abandoned)
  # rather than every time `run/6` (or a `user_choice/2` resumption)
  # returns: the Directions stage suspends the walk mid-mission awaiting
  # `user_choice/2`, and clearing here on that ordinary pause would wipe
  # out an earlier skip's memory before the walk resumes and rebroadcasts
  # the checklist for the remaining stages.
  defp outcomes_key(mission_id), do: {__MODULE__, :stage_outcomes, mission_id}
  defp init_outcomes(mission_id), do: :persistent_term.put(outcomes_key(mission_id), %{})
  defp clear_outcomes(mission_id), do: :persistent_term.erase(outcomes_key(mission_id))

  defp record_outcome(mission_id, stage_id, outcome) do
    outcomes = :persistent_term.get(outcomes_key(mission_id), %{})
    :persistent_term.put(outcomes_key(mission_id), Map.put(outcomes, stage_id, outcome))
  end

  defp stage_outcome(mission_id, stage_id) do
    :persistent_term.get(outcomes_key(mission_id), %{}) |> Map.get(stage_id)
  end

  defp skipped_stage_count(mission_id) do
    :persistent_term.get(outcomes_key(mission_id), %{})
    |> Map.values()
    |> Enum.count(&(&1 == :skipped))
  end

  @doc """
  Starts a staged mission. Same busy-guard contract as `Sprat.Mission.start/3`
  (see its moduledoc "One task at a time per session") — refuses a second
  run while one is active, with a visible message, never queuing silently.
  `template_mod` is `Sprat.Workflow.Idea` or `Sprat.Workflow.Opportunity`;
  `depth` is `:quick | :standard | :deep`.
  """
  def start(session_id, text, template_mod, depth, opts \\ []) do
    store = Keyword.get(opts, :store, Sprat.Store)
    budget_mod = Keyword.get(opts, :budget, Sprat.Budget)

    if active?(session_id) do
      system(session_id, [
        "Still running a staged mission — this message wasn't sent. Wait for it to " <>
          "finish, or press Ctrl+C to interrupt, then resend."
      ])

      :ok
    else
      mark_active(session_id)
      template = template_mod.template(depth)

      runner = fn ->
        try do
          run(session_id, store, budget_mod, text, template, opts)
        after
          clear_active(session_id)
          clear_active_mission(session_id)
          clear_cancel(session_id)
        end
      end

      if Keyword.get(opts, :sync?, false), do: runner.(), else: Task.start(runner)
      :ok
    end
  end

  defp run(session_id, store, budget_mod, text, template, opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    api_key = Keyword.fetch!(opts, :api_key)
    catalog = Keyword.get(opts, :catalog) || Pricing.load()

    {:ok, mission} = Missions.create(store, session_id, %{objective: text})
    mark_active_mission(session_id, mission.id)

    Enum.each(
      Keyword.get(opts, :attachments, []),
      &Sprat.Attachments.record_source(store, mission.id, &1)
    )

    # `/build` (docs/spec-v2.md §5) seeds a fresh mission with the
    # originating mission's already-delivered `product_brief` artifact,
    # so `Sprat.Workflow.Build`'s :technical_design stage finds it via
    # the same `required_inputs` -> `Artifacts.latest/3` path every other
    # stage's prior deliverables flow through — no cross-mission read
    # anywhere else in this module.
    Enum.each(Keyword.get(opts, :seed_artifacts, []), fn {type, content} ->
      Artifacts.write(store, mission.id, %{
        type: type,
        owning_role: "researcher",
        content: content,
        created_by: "researcher"
      })
    end)

    init_outcomes(mission.id)
    cap = Keyword.get(opts, :budget_cap, Decimal.new("5.00"))
    :ok = Budget.set_cap(budget_mod, mission.id, cap)

    stage = Template.first_stage(template)

    run_stage(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      text,
      model_id,
      api_key,
      catalog,
      opts
    )
  end

  # docs/spec-v2.md §5 Scaffold: "code, not a model turn" — a stage whose
  # `executor` is set (`Sprat.Workflow.Build`'s :scaffold stage) skips the
  # whole model-loop machinery below entirely and runs deterministically,
  # settling straight into the same `finish_stage/12`/`offer_recovery/12`
  # paths every other stage uses, so the gate, checklist, retry and
  # checkpoint machinery are all still exactly one code path.
  defp run_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         %{executor: executor} = stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       )
       when is_function(executor) do
    {:ok, task} =
      Tasks.create(store, mission.id, %{role: stage.role, objective: "#{stage.title}: #{text}"})

    {:ok, task} =
      Tasks.transition(store, task.id, :running, %{session_id: session_id, actor: "sprat"})

    announce_stage(session_id, budget_mod, template, stage, mission.id)

    design =
      case stage.required_inputs do
        [type | _] -> Artifacts.latest(store, mission.id, type)
        [] -> %{}
      end

    result = run_executor(executor, mission, task, design, session_id, store)

    record_message(
      store,
      session_id,
      task.id,
      stage.role,
      deterministic_summary(stage, result)
    )

    case result do
      :ok ->
        finish_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          task,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )

      {:error, reason} ->
        clear_stall_tracker(task.id)
        safe_transition(store, task.id, :failed, session_id, inspect(reason))
        broadcast_inspector(session_id, mission.id, store)

        offer_recovery(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts,
          inspect(reason)
        )
    end
  end

  defp run_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    {:ok, task} =
      Tasks.create(store, mission.id, %{role: stage.role, objective: "#{stage.title}: #{text}"})

    {:ok, task} =
      Tasks.transition(store, task.id, :running, %{session_id: session_id, actor: "sprat"})

    announce_stage(session_id, budget_mod, template, stage, mission.id)
    init_stall_tracker(store, mission.id, task.id)

    context_package = build_stage_context(store, session_id, mission.id, stage, text)

    loop_opts =
      stage_loop_opts(
        session_id,
        store,
        budget_mod,
        mission,
        stage,
        task,
        text,
        context_package,
        model_id,
        api_key,
        catalog,
        opts
      )

    settle_stage(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      task,
      text,
      model_id,
      api_key,
      catalog,
      opts,
      Loop.run(loop_opts)
    )
  end

  defp run_executor(executor, mission, task, design, session_id, store) do
    executor.(mission, task, design, session_id: session_id, store: store)
  rescue
    e -> {:error, Exception.format(:error, e, __STACKTRACE__)}
  end

  defp deterministic_summary(stage, :ok), do: "#{stage.title} completed."

  defp deterministic_summary(stage, {:error, reason}),
    do: "#{stage.title} failed: #{inspect(reason)}"

  # Shared by `run_stage/11` and `retry_stage/13` so both seed
  # `auto_fetch_urls`/`auto_fetch_hosts` the same way `Sprat.Mission.run_task/9`
  # does — from grants already recorded for this session (`granted_fetches/2`,
  # a session-scoped reuse: `Sprat.Store.Grants`'s own moduledoc records
  # validity as checked at the session level, and a staged mission's later
  # stages/retries are all still the same session) and from URLs literally
  # present in the mission's own submitted `text` (`user_supplied_urls/1`) —
  # otherwise a user who pastes a URL in `/idea` gets prompted to approve
  # their own URL (the exact false-positive `Sprat.Mission`'s own comment
  # warns about).
  @base_stage_tools [WebFetch, Calculate, RecordSource, RecordClaim, WriteArtifact]

  # Search rides the same key as the main model, so it is available exactly
  # when that key resolved (docs/design/web-search-options.md §7). A stage
  # without it can only fetch URLs the user supplied, which is what made
  # Research stall before `web_search` existed.
  defp stage_tools(true), do: [WebSearch | @base_stage_tools]
  defp stage_tools(false), do: @base_stage_tools

  # Both halves are required: the key pays for the sub-call and the model
  # names what runs it. A live run searched with the model missing and the
  # tool failed with "no search model configured", which the agent then
  # worked around by guessing URLs from memory.
  defp search_enabled?(api_key, search_model),
    do: is_binary(api_key) and api_key != "" and is_binary(search_model) and search_model != ""

  # The stage prompt must describe the tools the stage was actually handed,
  # or a researcher with search still guesses URLs from memory — which is
  # what a live run did after web_search merged but was not wired in here.
  # The generic "do not guess or compose URLs from memory" sentence below
  # already existed and a real event-log count (defect backlog item 5)
  # still found ~1 in 5 fetches were composed anyway, concentrated on a
  # handful of documentation/package hosts (hex.pm, hexdocs.pm, github.com,
  # elixirforum.com) — the model guessing a plausible-looking path
  # (`hex.pm/docs/usage`, `hex.pm/packages/X/dependents`) instead of
  # searching for the real one, which then needs a §9 approval prompt for
  # a URL that's frequently wrong anyway. This is prompt guidance, not a
  # §9 policy change: composed URLs still prompt exactly as before: it
  # just gives the model a concrete reason to search these hosts instead
  # of guessing at them.
  defp search_note(true),
    do:
      " Use web_search to find pages that might answer the question — do not guess or " <>
        "compose URLs from memory. Its snippets are model summaries, not evidence: fetch " <>
        "a page before citing it. This applies doubly to documentation and package-index " <>
        "sites (hex.pm, hexdocs.pm, github.com, elixirforum.com and similar): their URL " <>
        "structure looks guessable but often isn't — a guessed path is as likely to 404 " <>
        "as it is to be right, and every guess needs a user approval prompt whether or " <>
        "not it works. Search for the exact page instead."

  defp search_note(false),
    do:
      " You have no live web search tool — only web_fetch on URLs the user gave you or " <>
        "links found on a page you already fetched. Label the output \"no live research\" " <>
        "if you end up with no usable sources (docs/spec-v1.md §7)."

  defp stage_loop_opts(
         session_id,
         store,
         budget_mod,
         mission,
         stage,
         task,
         text,
         context_package,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    {granted_urls, auto_hosts} = granted_fetches(store, session_id)
    auto_urls = MapSet.union(granted_urls, user_supplied_urls(text))
    set_deadline(task.id, Map.get(stage.limits, :wall_seconds))

    %{
      model_mod: Keyword.get(opts, :model_mod, OpenAI),
      model_id: model_id,
      role_prompt:
        stage.prompt <> search_note(search_enabled?(api_key, Keyword.get(opts, :search_model))),
      context_package: context_package,
      tools: stage_tools(search_enabled?(api_key, Keyword.get(opts, :search_model))),
      session_id: session_id,
      mission_id: mission.id,
      task_id: task.id,
      agent_id: stage.role,
      attempt: task.attempt,
      store: store,
      budget: budget_mod,
      api_key: api_key,
      catalog: catalog,
      max_turns: Map.get(stage.limits, :model_calls, 20),
      tool_context: %{
        store: store,
        session_id: session_id,
        mission_id: mission.id,
        task_id: task.id,
        role: stage.role,
        allowed_artifact_types: MapSet.new(Enum.map(stage.deliverables, &to_string/1)),
        auto_fetch_urls: auto_urls,
        auto_fetch_hosts: auto_hosts,
        budget: budget_mod,
        catalog: catalog,
        api_key: api_key,
        search_provider: Keyword.get(opts, :search_provider, "openai"),
        search_model: Keyword.get(opts, :search_model),
        secrets: Secrets.redaction_set(),
        # A hard, structural "never dial out" guard (see
        # `Sprat.Agent.Tools.WebFetch`/`WebSearch`'s own comments) —
        # `opts[:network_disabled]` is how the offline replay harness
        # guarantees zero live network egress regardless of what a
        # replayed mission's recorded turns ask a tool to fetch.
        network_disabled: Keyword.get(opts, :network_disabled, false),
        replay_fetch_lookup: Keyword.get(opts, :replay_fetch_lookup),
        replay_search_lookup: Keyword.get(opts, :replay_search_lookup)
      },
      on_delta: fn _delta -> :ok end,
      steering_fetch: fn -> Steering.take_pending(store, session_id, mission.id) end,
      cancel?: fn ->
        cancelled?(session_id) or stalled?(task.id) or past_deadline?(task.id) or
          reject_cap_exceeded?(store, task.id)
      end,
      on_turn_end: fn _turn ->
        record_turn_progress(store, mission.id, task.id)
        # A research stage can run for many minutes; without this the meter
        # keeps whatever it showed when the stage began (a live run sat at
        # "<$0.01" while the mission had actually spent $0.06).
        broadcast_budget(session_id, budget_mod, mission.id)
        broadcast_inspector(session_id, mission.id, store)
      end
    }
  end

  defp settle_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         task,
         text,
         model_id,
         api_key,
         catalog,
         opts,
         result
       ) do
    case result do
      {:ok, %{content: content}} ->
        clear_stall_tracker(task.id)
        record_message(store, session_id, task.id, stage.role, content || "(no content)")

        finish_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          task,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )

      # `Loop.run/1` returns `{:cancelled, _}` both for a real mid-stream
      # user cancel (docs/spec-v1.md §13) and for the stall detector
      # tripping `cancel?` from `on_turn_end` (§8) — `stalled?/1` is the
      # one already-idempotent signal that tells them apart (it just reads
      # the streak `on_turn_end` maintained during the run; it doesn't
      # itself advance it, so calling it here doesn't change the answer).
      {:cancelled, _} ->
        cond do
          # Everything the gate needs is already in the store: the stage did
          # its job, whether it stopped on its own or was cut off for going
          # quiet or running long. A live run wrote its source_register and
          # research_memo, kept turning, and was failed as stalled with every
          # deliverable already recorded.
          (stalled?(task.id) or past_deadline?(task.id) or reject_cap_exceeded?(store, task.id)) and
              run_gate(store, mission.id, stage) == :ok ->
            clear_stall_tracker(task.id)

            finish_stage(
              session_id,
              store,
              budget_mod,
              mission,
              template,
              stage,
              task,
              text,
              model_id,
              api_key,
              catalog,
              opts
            )

          stalled?(task.id) or past_deadline?(task.id) or reject_cap_exceeded?(store, task.id) ->
            timed_out? = past_deadline?(task.id) and not stalled?(task.id)
            reject_capped? = reject_cap_exceeded?(store, task.id)
            clear_stall_tracker(task.id)

            reason =
              cond do
                # Checked ahead of the plain stall message: a same-type
                # reject streak also advances the stall streak's snapshot
                # (item 6), so without this ordering the generic "stalled"
                # message would fire first and hide the actual cause.
                reject_capped? ->
                  {type, count} = same_type_reject_streak(store, task.id)

                  "write_artifact for #{type} was rejected #{count} times in a row " <>
                    "without a successful write — stopping instead of burning more turns"

                timed_out? ->
                  "hit this stage's time limit (#{Map.get(stage.limits, :wall_seconds)}s) " <>
                    "before producing everything the gate requires"

                true ->
                  "stalled: 3 consecutive turns with no new source, claim, artifact or fetch"
              end

            safe_transition(store, task.id, :failed, session_id, reason)

            Events.append(store, session_id, "task.stalled", %{
              mission_id: mission.id,
              task_id: task.id,
              payload: %{reason: reason}
            })

            system(session_id, ["#{stage.title} stopped — #{reason}"])

            offer_recovery(
              session_id,
              store,
              budget_mod,
              mission,
              template,
              stage,
              text,
              model_id,
              api_key,
              catalog,
              opts,
              reason
            )

          true ->
            clear_stall_tracker(task.id)
            safe_transition(store, task.id, :interrupted, session_id, "cancelled by user")

            system(session_id, [
              "#{stage.title} interrupted — usage so far is recorded as estimated."
            ])
        end

      # `Sprat.Agent.Tools.WebFetch` asks for approval on any URL not
      # already in `tool_context`'s `auto_fetch_urls`/`auto_fetch_hosts`.
      # Mirrors `Sprat.Mission.handle_approval/6` + `continue_after_approval/6`:
      # show a blocking numbered prompt, record the decision as a grant
      # (reused by `stage_loop_opts/12` on every later stage/retry in this
      # session), then resume the SAME stage's loop with the decision and
      # re-settle whatever comes back — recursively, since a resumed loop
      # can itself hit another `{:needs_approval, ...}`. The task's DB
      # status stays `running` throughout (matching Mission's own
      # precedent) — only the UI-facing agent state broadcasts
      # `:waiting_on_user`, so a pending approval reads as "waiting on
      # you", never as a failure.
      {:needs_approval, request, resume} ->
        broadcast_agent_state(session_id, stage, :waiting_on_user, "waiting for fetch approval")
        # The task's DB status and budget tracking both stay put while a
        # prompt is up (nothing is "running" — the model isn't spending
        # tokens, the clock the budget meter reads shouldn't move either,
        # see `Budget`), but the checklist previously kept the stage's
        # `:active` spinner going through the whole prompt: a user
        # watching the checklist alone (not the Agents card) couldn't
        # tell "thinking" from "waiting on me". `:waiting_on_user` here
        # renders the same distinct "?" glyph/word `Theme` already gives
        # the agent card (`Zones.Mission.checklist_state/1`), and flips
        # back to `:active` below once a decision comes back in, whether
        # approved or denied — the stage really is running again then.
        broadcast_checklist(session_id, mission.id, template, stage.id, :waiting_on_user)

        decision =
          case Session.await_permission(session_id, fetch_prompt(request)) do
            {:ok, 0} ->
              record_grant(store, session_id, mission.id, "url", request.url)
              {:approved, %{auto_fetch_urls: MapSet.new([request.url])}}

            {:ok, 1} ->
              host = URI.parse(request.url).host
              record_grant(store, session_id, mission.id, "domain", host)
              {:approved, %{auto_fetch_hosts: MapSet.new([host])}}

            {:ok, _} ->
              :denied

            :cancelled ->
              :denied
          end

        max_turns = Map.get(stage.limits, :model_calls, 20)
        broadcast_agent_state(session_id, stage, :active, "resuming")
        broadcast_checklist(session_id, mission.id, template, stage.id, :active)

        settle_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          task,
          text,
          model_id,
          api_key,
          catalog,
          opts,
          Loop.resume(resume, decision, max_turns)
        )

      # More specific than the generic `{:error, reason}` clause below —
      # must stay above it (Elixir matches top to bottom). Budget
      # exhaustion (docs/spec-v1.md §12) is a mission-level event, not
      # just a task-level failure: the mission itself moves to
      # `paused_budget` via `Missions.transition/4` so the state is real
      # and resumable (the user can raise the cap and return to
      # `active`), not just a system message. `{:error, _}` from
      # `Missions.transition/4` (e.g. a second stage racing the same
      # exhausted cap and finding the mission already `paused_budget`, or
      # otherwise terminal) is swallowed on purpose — the task-level
      # failure above and the system message below still stand either way.
      {:error, {:would_exceed_cap, detail}} ->
        clear_stall_tracker(task.id)
        safe_transition(store, task.id, :failed, session_id, "would exceed mission budget cap")

        Missions.transition(store, mission.id, :paused_budget, %{
          session_id: session_id,
          reason: "would exceed mission budget cap: #{inspect(detail)}"
        })

        broadcast_budget(session_id, budget_mod, mission.id, "paused_budget")

        reason = "would exceed mission budget cap (#{inspect(detail)})"

        system(session_id, [
          "Mission paused (budget): the cap would be exceeded (#{inspect(detail)}). " <>
            "Raise the cap or export what exists — later stages were not started."
        ])

        offer_recovery(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts,
          reason
        )

      {:error, reason} ->
        clear_stall_tracker(task.id)
        safe_transition(store, task.id, :failed, session_id, inspect(reason))
        system(session_id, ["#{stage.title} failed: #{inspect(reason)}"])

        offer_recovery(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts,
          inspect(reason)
        )
    end
  end

  # Shared by every terminal-failure site in `settle_stage/13` and
  # `retry_or_surface/13`'s give-up branch (stalled, would-exceed-budget,
  # generic error, gate exhausted) so the user always gets the same visible
  # next action instead of the mission just going quiet: the checklist is
  # rebroadcast as `:failed` for the current stage (the coordinator's exact
  # complaint — otherwise it keeps showing the stage's last broadcast
  # status, `:active`, and the spinner never stops), then a blocking
  # numbered prompt (`Session.await_permission/2`, same mechanism
  # `Sprat.Mission`'s fetch/model/budget prompts already use) offers retry,
  # skip, or abandon.
  defp offer_recovery(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts,
         reason
       ) do
    broadcast_checklist(session_id, mission.id, template, stage.id, :failed)

    case Session.await_permission(session_id, recovery_prompt(stage, reason)) do
      {:ok, 0} ->
        system(session_id, ["Retrying #{stage.title} from scratch..."])

        run_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )

      {:ok, 1} ->
        record_outcome(mission.id, stage.id, :skipped)

        skip_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )

      {:ok, 2} ->
        finish_mission(
          store,
          session_id,
          mission,
          :cancelled,
          "abandoned by the user after #{stage.title} failed"
        )

        system(session_id, [
          "Mission abandoned after #{stage.title} failed. Run /artifacts to see what exists so far."
        ])

        clear_outcomes(mission.id)

      # Anything else — the prompt dismissed, the session going away, a
      # mission already settled elsewhere (a budget pause landing
      # concurrently) — leaves the mission's own status alone. Only an
      # explicit "abandon" cancels a mission.
      _ ->
        system(session_id, [
          "#{stage.title} left unresolved. Run /artifacts to see what exists so far."
        ])

        clear_outcomes(mission.id)
    end
  end

  defp recovery_prompt(stage, reason) do
    %{
      title: "#{stage.title} failed",
      lines: [reason],
      options: [
        "Retry #{stage.title} from scratch",
        "Skip #{stage.title} (mark its deliverables incomplete) and continue",
        "Abandon this mission"
      ],
      selected: 0
    }
  end

  # "Skip" mirrors the `incomplete` escape hatch `Sprat.Workflow.Gate.require_artifact/2`
  # already honors: write every one of the stage's deliverables as an
  # explicit incomplete artifact, then `advance/11` exactly as if this
  # stage's gate had passed.
  defp skip_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    Enum.each(stage.deliverables, fn type ->
      Artifacts.write(store, mission.id, %{
        type: type,
        owning_role: stage.role,
        content: %{"incomplete" => true, "reason" => "user skipped after a failure"},
        created_by: stage.role
      })
    end)

    broadcast_inspector(session_id, mission.id, store)
    system(session_id, ["Skipped #{stage.title} — continuing with incomplete deliverables."])

    advance(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      text,
      model_id,
      api_key,
      catalog,
      opts
    )
  end

  # Gate check + advance/retry/stop (docs/spec-v1.md §5 Gates, §8 "review
  # rounds"). No gate (`stage.gate == nil`, e.g. Directions, Scoring) means
  # the stage's own deliverable check is enough — advance straight away.
  defp finish_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         task,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    case run_gate(store, mission.id, stage) do
      :ok ->
        {:ok, _} = Tasks.transition(store, task.id, :review_pending, %{session_id: session_id})
        {:ok, _} = Tasks.transition(store, task.id, :completed, %{session_id: session_id})
        record_outcome(mission.id, stage.id, :done)
        gate_result(session_id, stage, :ok, [])
        broadcast_checklist(session_id, mission.id, template, stage.id, :done)
        broadcast_budget(session_id, budget_mod, mission.id)
        broadcast_inspector(session_id, mission.id, store)

        advance(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )

      {:error, errors} ->
        broadcast_inspector(session_id, mission.id, store)

        retry_or_surface(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          task,
          text,
          model_id,
          api_key,
          catalog,
          opts,
          errors
        )
    end
  end

  defp run_gate(_store, _mission_id, %{gate: nil}), do: :ok

  defp run_gate(store, mission_id, stage) do
    artifacts = Artifacts.latest_all(store, mission_id)
    source_ids = Sources.by_mission(store, mission_id) |> Enum.map(& &1.id) |> MapSet.new()

    recorded =
      store
      |> Claims.by_mission_with_sources(mission_id)
      |> Map.new(fn {claim, claim_source_ids} ->
        {claim.id,
         %{
           "text" => claim.text,
           "source_ids" => claim_source_ids,
           "is_assumption" => claim.is_assumption
         }}
      end)

    stale_types = Artifacts.stale_types(store, mission_id)
    runs = Runs.by_mission(store, mission_id)
    Gate.check(stage.gate, artifacts, source_ids, recorded, stale_types, runs)
  end

  # Bounded retry (docs/spec-v1.md §8 "review rounds"): `@review_rounds`
  # is the number of retries allowed on top of the first attempt, so
  # `task.attempt <= @review_rounds` (checked while the task is still
  # `running`, i.e. before any transition for *this* gate result) decides
  # whether this failure gets another attempt.
  #
  # This diverges from the plan's literal brief in two ways, both
  # necessary to get a real bounded-retry-then-fail cycle out of the
  # existing, unchanged `Sprat.Store.TaskState` graph (confirmed with the
  # plan coordinator rather than guessed):
  #
  #   1. The cap check is `task.attempt <= @review_rounds` (not
  #      `@review_rounds + 1`) — the brief's literal condition let one
  #      extra retry through, contradicting its own test comment
  #      ("review_rounds default is 1 (§8 scheduling defaults) -> attempt
  #      caps at 2").
  #   2. The terminal "give up" transition goes straight from `running`
  #      to `failed`, skipping `review_pending`/`changes_requested` for
  #      that case. `TaskState`'s graph only allows
  #      `changes_requested -> queued` (never `-> failed`) and
  #      `review_pending -> {completed, changes_requested, cancelled}`
  #      (never `-> failed`) — `failed` is reachable only from `running`.
  #      Going through review_pending/changes_requested first (as the
  #      brief's literal code did) makes the terminal `:failed` transition
  #      structurally invalid and crashes with a `MatchError`. The retry
  #      path still goes through review_pending -> changes_requested (so
  #      the gate failure is recorded as a `task.transitioned` event, for
  #      the Inspector/Debug view) before returning to running via queued
  #      (which is where `attempt` bumps) — but `errors` is passed straight
  #      through to `retry_stage/13` for the retry's own context package,
  #      not re-derived from the event log: `Events.by_task/2`'s last event
  #      for this task is, by the time `retry_stage/13` would read it, the
  #      `queued -> running` transition (no `:reason`), not the
  #      `changes_requested` one that actually carries the gate errors —
  #      reading it back would always yield "(reason unavailable)",
  #      silently defeating the whole point of the retry.
  defp retry_or_surface(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         task,
         text,
         model_id,
         api_key,
         catalog,
         opts,
         errors
       ) do
    reason = Enum.join(errors, "; ")

    if task.attempt <= @review_rounds do
      {:ok, task} = Tasks.transition(store, task.id, :review_pending, %{session_id: session_id})

      {:ok, task} =
        Tasks.transition(store, task.id, :changes_requested, %{
          session_id: session_id,
          reason: reason
        })

      {:ok, task} = Tasks.transition(store, task.id, :queued, %{session_id: session_id})
      {:ok, task} = Tasks.transition(store, task.id, :running, %{session_id: session_id})

      system(session_id, [
        "↻ #{stage.title} needs another pass (attempt #{task.attempt} of #{@review_rounds + 1})"
      ])

      retry_stage(
        session_id,
        store,
        budget_mod,
        mission,
        template,
        stage,
        task,
        text,
        model_id,
        api_key,
        catalog,
        opts,
        errors
      )
    else
      clear_stall_tracker(task.id)

      {:ok, _} =
        Tasks.transition(store, task.id, :failed, %{
          session_id: session_id,
          reason: "gate failed after #{task.attempt} attempts: #{reason}"
        })

      broadcast_inspector(session_id, mission.id, store)

      system(session_id, [
        "✗ #{stage.title} could not pass its gate after #{task.attempt} attempts:",
        Enum.map_join(errors, "\n", &"  - #{&1}")
      ])

      offer_recovery(
        session_id,
        store,
        budget_mod,
        mission,
        template,
        stage,
        text,
        model_id,
        api_key,
        catalog,
        opts,
        "gate failed after #{task.attempt} attempts: #{reason}"
      )
    end
  end

  # Re-runs the same stage, folding the prior gate failure into the
  # context package so the retry sees exactly what was missing — the
  # spec's "changes_requested" round, not a blind repeat. `errors` comes
  # straight from the gate check that triggered this retry (see
  # `retry_or_surface/13`'s comment on why it isn't re-derived from the
  # event log).
  defp retry_stage(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         task,
         text,
         model_id,
         api_key,
         catalog,
         opts,
         errors
       ) do
    init_stall_tracker(store, mission.id, task.id)

    context_package =
      build_stage_context(store, session_id, mission.id, stage, text) <>
        "\n\nThe previous attempt failed this stage's gate:\n" <>
        Enum.map_join(errors, "\n", &"- #{&1}")

    loop_opts =
      stage_loop_opts(
        session_id,
        store,
        budget_mod,
        mission,
        stage,
        task,
        text,
        context_package,
        model_id,
        api_key,
        catalog,
        opts
      )

    settle_stage(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      task,
      text,
      model_id,
      api_key,
      catalog,
      opts,
      Loop.run(loop_opts)
    )
  end

  # Directions ends the automated walk here (the user-choice point) —
  # `user_choice/2` resumes from this exact point. Every other stage
  # advances straight to the next one.
  defp advance(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         %{id: :directions} = stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    await_user_choice(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      text,
      model_id,
      api_key,
      catalog,
      opts
    )
  end

  # docs/spec-v2.md §5 checkpoint 1 ("design approved"): the design gate
  # passing is not itself enough to start scaffolding — pause here, the
  # same way Directions does, for approve/revise-with-instructions/
  # abandon (§5 build brief item 3: "Reuse await_user_choice/user_choice
  # — do not invent a second mechanism").
  defp advance(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         %{id: :technical_design} = stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    await_checkpoint1(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      stage,
      text,
      model_id,
      api_key,
      catalog,
      opts
    )
  end

  defp advance(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    case Template.stage_after(template, stage.id) do
      nil ->
        # `MissionState` has had a `completed` state since it was written and
        # nothing ever transitioned into it, so a delivered mission stayed
        # `active` forever — `/export`, `/tasks` and any later resume had to
        # infer delivery from the artifacts instead of reading the column.
        finish_mission(store, session_id, mission, :completed, completion_reason(mission.id))
        system(session_id, [delivered_message(mission.id)])
        Session.notify_finished(session_id, :completed)
        clear_outcomes(mission.id)

      next_stage ->
        run_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          next_stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )
    end
  end

  # A mission's terminal state is recorded once, and a refusal never takes the
  # run down: by the time we get here the work is already durable, and a
  # mission that raced to a terminal state elsewhere (a budget pause settling
  # concurrently) has simply already been settled.
  defp finish_mission(store, session_id, mission, to_status, reason) do
    case Missions.transition(store, mission.id, to_status, %{
           session_id: session_id,
           reason: reason
         }) do
      {:ok, _} ->
        :ok

      {:error, :invalid_transition} ->
        Events.append(store, session_id, "mission.transition_refused", %{
          mission_id: mission.id,
          payload: %{to: to_string(to_status), reason: reason}
        })

        :ok
    end
  end

  defp completion_reason(mission_id) do
    case skipped_stage_count(mission_id) do
      0 -> "all stages delivered"
      n -> "delivered with #{n} stage(s) skipped with incomplete deliverables"
    end
  end

  # Part 3 of the checklist-honesty fix: "Mission delivered — all stages
  # complete" reads as a clean, fully-successful run — not true when one
  # or more stages were skipped with incomplete deliverables (§ the same
  # `outcomes_key/1` tracker Part 1 built for the checklist).
  defp delivered_message(mission_id) do
    case skipped_stage_count(mission_id) do
      0 ->
        "Mission delivered — all stages complete. Run /artifacts to see what was produced."

      n ->
        "Mission delivered, but #{n} stage(s) were skipped with incomplete deliverables — " <>
          "run /artifacts to see what's missing."
    end
  end

  @doc """
  True when a staged mission is paused at its user-choice point. The session
  routes a plain message to `user_choice/2` instead of starting a new
  single-agent run — without this, a mission that asked the user to pick a
  direction sat paused while their answer was handled as an unrelated chat
  question, which is exactly what a live run did.
  """
  def pending_choice?(session_id) do
    :persistent_term.get({__MODULE__, :pending, session_id}, nil) != nil
  end

  @doc """
  Answers the pending Directions choice (docs/spec-v1.md §5 "the user
  picks, combines, rejects or adds constraints"). Persists `answer` as a
  decision (`Sprat.Store.Decisions`) and resumes the walk from the stage
  after Directions with `answer` folded into the context text every later
  stage sees. Same busy guard as `start/5` — refuses to resume while
  another run is active — and, when `sync?: true` was passed to the
  original `start/5` call (carried through in the pending state), resumes
  synchronously too; otherwise resumes in a background `Task.start`,
  mirroring `Sprat.Mission.pick_model/2`.
  """
  def user_choice(session_id, answer) do
    key = {__MODULE__, :pending, session_id}

    case :persistent_term.get(key, nil) do
      nil ->
        system(session_id, ["No pending direction choice for this session."])

      pending ->
        if active?(session_id) do
          system(session_id, [
            "Still running a staged mission — this message wasn't sent. Wait for it to " <>
              "finish, or press Ctrl+C to interrupt, then resend."
          ])
        else
          resume_after_choice(session_id, key, pending, answer)
        end
    end

    :ok
  end

  defp resume_after_choice(session_id, key, %{kind: :checkpoint1} = pending, answer) do
    %{
      store: store,
      budget_mod: budget_mod,
      mission: mission,
      template: template,
      stage: stage,
      text: text,
      model_id: model_id,
      api_key: api_key,
      catalog: catalog,
      opts: opts
    } = pending

    :persistent_term.erase(key)

    case classify_checkpoint_answer(answer) do
      :abandon ->
        finish_mission(
          store,
          session_id,
          mission,
          :cancelled,
          "abandoned by the user at checkpoint 1 (design)"
        )

        system(session_id, [
          "Mission abandoned at the design checkpoint. Run /artifacts to see what exists so far."
        ])

        clear_outcomes(mission.id)

      {:revise, instructions} ->
        {:ok, _} =
          Decisions.record(store, mission.id, %{
            summary: "Checkpoint 1: revise design — #{instructions}",
            evidence_for: nil,
            evidence_against: nil
          })

        combined_text =
          "#{text}\n\nUser requested changes to the technical design at checkpoint 1: " <>
            instructions

        run_stage_async(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          combined_text,
          model_id,
          api_key,
          catalog,
          opts
        )

      :approve ->
        {:ok, _} =
          Decisions.record(store, mission.id, %{
            summary: "Checkpoint 1: design approved",
            evidence_for: nil,
            evidence_against: nil
          })

        next_stage = Template.stage_after(template, stage.id)

        run_stage_async(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          next_stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )
    end
  end

  defp resume_after_choice(session_id, key, pending, answer) do
    %{
      store: store,
      budget_mod: budget_mod,
      mission: mission,
      template: template,
      stage: stage,
      text: text,
      model_id: model_id,
      api_key: api_key,
      catalog: catalog,
      opts: opts
    } = pending

    :persistent_term.erase(key)

    {:ok, _} =
      Decisions.record(store, mission.id, %{
        summary: "User choice after Directions: #{answer}",
        evidence_for: nil,
        evidence_against: nil
      })

    combined_text = "#{text}\n\nUser's choice after Directions: #{answer}"
    next_stage = Template.stage_after(template, stage.id)

    run_stage_async(
      session_id,
      store,
      budget_mod,
      mission,
      template,
      next_stage,
      combined_text,
      model_id,
      api_key,
      catalog,
      opts
    )
  end

  # A revise-with-instructions answer starts "revise" (case-insensitive),
  # optionally followed by ":"/"-" and the instructions; abandon starts
  # "abandon"; anything else — including blank/"approve"/"yes" — is
  # approve, matching `recovery_prompt/2`'s "anything else leaves it
  # unresolved" caution but for a genuinely two-outcome default (approve
  # is the expected common case at a checkpoint, unlike a failure prompt).
  defp classify_checkpoint_answer(answer) do
    trimmed = String.trim(answer)
    downcased = String.downcase(trimmed)

    cond do
      String.starts_with?(downcased, "abandon") ->
        :abandon

      String.starts_with?(downcased, "revise") ->
        {:revise, Regex.replace(~r/^revise[:\-]?\s*/i, trimmed, "")}

      true ->
        :approve
    end
  end

  defp run_stage_async(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    mark_active(session_id)
    mark_active_mission(session_id, mission.id)

    runner = fn ->
      try do
        run_stage(
          session_id,
          store,
          budget_mod,
          mission,
          template,
          stage,
          text,
          model_id,
          api_key,
          catalog,
          opts
        )
      after
        clear_active(session_id)
        clear_active_mission(session_id)
      end
    end

    if Keyword.get(opts, :sync?, false), do: runner.(), else: Task.start(runner)
  end

  defp await_user_choice(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    :persistent_term.put(
      {__MODULE__, :pending, session_id},
      %{
        kind: :directions,
        store: store,
        budget_mod: budget_mod,
        mission: mission,
        template: template,
        stage: stage,
        text: text,
        model_id: model_id,
        api_key: api_key,
        catalog: catalog,
        opts: opts
      }
    )

    # Same fix as the fetch-approval clause in `settle_stage/13`: the
    # Directions stage genuinely stops here (no loop running, nothing
    # spending budget) until `user_choice/2` resumes it, but the
    # checklist/agent-card broadcasts were left at whatever `announce_stage/5`
    # set when Directions started (`:active`, the spinner) — a user
    # watching the Mission checklist alone couldn't tell this pause from
    # the model still thinking. `:waiting_on_user` is the same distinct
    # state the fetch-approval pause and the agent card already use.
    broadcast_agent_state(
      session_id,
      stage,
      :waiting_on_user,
      "waiting for your direction choice"
    )

    broadcast_checklist(session_id, mission.id, template, stage.id, :waiting_on_user)

    system(session_id, [
      "Directions ready — pick one, combine, reject, or add a constraint, then continue."
    ])
  end

  # docs/spec-v2.md §5 checkpoint 1: "show the design summary, the
  # profile, and the estimated cost, and accept approve /
  # revise-with-instructions / abandon." Same pending/pause mechanism as
  # `await_user_choice/11` above (`kind: :checkpoint1` is the only
  # difference `resume_after_choice/4` needs to answer differently) —
  # §13's per-project `auto` setting is a real seam here (a future
  # `checkpoint1_auto?/1` could skip straight to `run_stage_async/11`),
  # deliberately left unbuilt: the default is `ask`, always, in this build.
  defp await_checkpoint1(
         session_id,
         store,
         budget_mod,
         mission,
         template,
         stage,
         text,
         model_id,
         api_key,
         catalog,
         opts
       ) do
    :persistent_term.put(
      {__MODULE__, :pending, session_id},
      %{
        kind: :checkpoint1,
        store: store,
        budget_mod: budget_mod,
        mission: mission,
        template: template,
        stage: stage,
        text: text,
        model_id: model_id,
        api_key: api_key,
        catalog: catalog,
        opts: opts
      }
    )

    broadcast_agent_state(session_id, stage, :waiting_on_user, "waiting for design approval")
    broadcast_checklist(session_id, mission.id, template, stage.id, :waiting_on_user)

    design = Artifacts.latest(store, mission.id, :technical_design) || %{}

    system(session_id, [
      "Checkpoint 1 — design ready:",
      "  Profile: #{design["profile"] || "(missing)"}",
      "  Estimated cost: #{design["estimated_cost"] || "(missing)"}",
      "  Excluded from this MVP: #{format_excluded_scope(design["excluded_scope"])}",
      "Reply \"approve\" to scaffold it, \"revise: <instructions>\" to redo the design, " <>
        "or \"abandon\" to stop."
    ])
  end

  defp format_excluded_scope(list) when is_list(list) and list != [] do
    Enum.map_join(list, "; ", fn
      %{"item" => item, "reason" => reason} -> "#{item} (#{reason})"
      other -> inspect(other)
    end)
  end

  defp format_excluded_scope(_), do: "(none listed)"

  # -- fetch approval (mirrors Sprat.Mission's §9 fetch rule) ---------------

  defp fetch_prompt(request) do
    %{
      title: "Fetch URL",
      lines: [
        "This stage wants to fetch a URL it composed itself (docs/spec-v1.md §9):",
        "  #{request.url}"
      ],
      options: ["Yes", "Yes, and allow #{URI.parse(request.url).host} for this mission", "No"],
      selected: 0
    }
  end

  defp record_grant(store, session_id, mission_id, scope, resource) do
    Grants.record(store, session_id, %{
      action: "web_fetch",
      resource: resource,
      resource_scope: scope,
      lifetime: "session",
      decision: "approved",
      mission_id: mission_id
    })
  end

  # Grants are session-scoped (Sprat.Store.Grants's own moduledoc: validity
  # is checked at the session level, not per-mission) — reused verbatim so
  # a grant approved in one stage, or one staged mission, is never
  # re-prompted anywhere else in the same session.
  defp granted_fetches(store, session_id) do
    grants = Grants.by_session(store, session_id) |> Enum.filter(&(&1.action == "web_fetch"))

    urls =
      grants
      |> Enum.filter(&(&1.resource_scope == "url"))
      |> Enum.map(& &1.resource)
      |> MapSet.new()

    hosts =
      grants
      |> Enum.filter(&(&1.resource_scope == "domain"))
      |> Enum.map(& &1.resource)
      |> MapSet.new()

    {urls, hosts}
  end

  # A URL the user typed in their own submitted text is fetched without
  # asking (only a URL the *model* composes needs approval) — see
  # `Sprat.Mission.user_supplied_urls/1`'s comment for why this matters.
  @url_regex ~r/https?:\/\/[^\s<>"'\)\]]+/
  defp user_supplied_urls(text) do
    Regex.scan(@url_regex, text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,;:!?"))
    |> MapSet.new()
  end

  # -- context (generalised from Sprat.Mission.build_context/7) -------------

  defp build_stage_context(store, session_id, mission_id, stage, text) do
    inputs =
      stage.required_inputs
      |> Enum.map(fn type -> {type, Artifacts.latest(store, mission_id, type)} end)
      |> Enum.reject(fn {_type, content} -> is_nil(content) end)

    sources = Sources.by_mission(store, mission_id)

    [
      inputs_section(inputs),
      sources_section(sources),
      Steering.context_section(store, session_id, mission_id),
      "Objective: #{text}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> tap(fn package ->
      Events.append(store, session_id, "context.assembled", %{
        mission_id: mission_id,
        payload: %{
          "stage" => stage.id,
          "inputs" => Enum.map(inputs, &elem(&1, 0)),
          "token_estimate" => div(byte_size(package), 4)
        }
      })
    end)
  end

  defp inputs_section([]), do: ""

  defp inputs_section(inputs) do
    lines = Enum.map(inputs, fn {type, content} -> "- #{type}: #{JSON.encode!(content)}" end)
    "Prior artifacts this stage depends on:\n" <> Enum.join(lines, "\n")
  end

  defp sources_section([]), do: ""

  defp sources_section(sources) do
    lines =
      Enum.map(sources, fn s ->
        "- #{s.title || "(untitled)"} — #{s.url} (source id: #{s.id})" <>
          Sprat.Attachments.content_block(s)
      end)

    "Sources already recorded in this mission:\n" <> Enum.join(lines, "\n")
  end

  # -- broadcasts (never the renderer directly — §13) ------------------------

  defp announce_stage(session_id, budget_mod, template, stage, mission_id) do
    :ok = Session.add_block(session_id, %{kind: :stage_change, name: stage.title, reason: nil})
    broadcast_agent_state(session_id, stage, :active, "starting")
    broadcast_checklist(session_id, mission_id, template, stage.id, :active)
    broadcast_budget(session_id, budget_mod, mission_id)
  end

  # Single-agent view broadcast for the stage currently running (never the
  # renderer directly — §13). `announce_stage/5` uses this for the normal
  # `:active` state; `settle_stage/13`'s `{:needs_approval, ...}` clause
  # reuses it for `:waiting_on_user`, mirroring `Sprat.Mission.agent_view/4`.
  defp broadcast_agent_state(session_id, stage, state, activity) do
    PubSub.broadcast(session_id, {
      :agents_updated,
      %{
        agents: [
          %{
            id: stage.id,
            role: String.to_atom(stage.role),
            label: stage.title,
            state: state,
            elapsed_s: nil,
            tokens: nil,
            activity: activity,
            stream_tail: nil
          }
        ]
      }
    })
  end

  # Feeds `Sprat.Terminal.Zones.Mission.handle_view_update/2`'s `checklist`
  # key (`%{stages: [{label, status}]}`, `status: :done | :skipped | :active
  # | :failed | :queued`) with every stage of the current template, not
  # just the one that changed — the zone replaces its whole checklist on
  # each broadcast, so a partial update would blank out every other stage
  # on screen. A stage before `current_stage_id` renders its REAL outcome
  # from `stage_outcome/2` (`:done` or `:skipped`) instead of always
  # `:done` — `stage_before?/3` alone can't tell a genuinely completed
  # stage from one the user skipped after a failure, since a skip still
  # advances past it. `stage_outcome/2` defaults to `:done` only for a
  # stage this mission hasn't recorded an outcome for yet, which shouldn't
  # happen for anything `stage_before?/3` says is already past.
  defp broadcast_checklist(session_id, mission_id, template, current_stage_id, current_status) do
    stages =
      Enum.map(template.stages, fn s ->
        status =
          cond do
            s.id == current_stage_id ->
              current_status

            stage_before?(template, s.id, current_stage_id) ->
              stage_outcome(mission_id, s.id) || :done

            true ->
              :queued
          end

        {s.title, status}
      end)

    PubSub.broadcast(session_id, {:live_updated, %{checklist: %{stages: stages}}})
  end

  defp stage_before?(template, id, current_id) do
    ids = Enum.map(template.stages, & &1.id)
    Enum.find_index(ids, &(&1 == id)) < Enum.find_index(ids, &(&1 == current_id))
  end

  # Reuses `Sprat.Budget`'s own tracked cap + `Sprat.Store.Usage`-backed
  # spent total (via `Budget.status/2`) instead of duplicating
  # `Sprat.Mission.broadcast_budget/3`'s persistent_term-cap-plus-manual-
  # Usage-query logic — the Orchestrator already has `budget_mod` in scope
  # everywhere it needs this, so there's no need for Mission's separate
  # `cap_key` bookkeeping here.
  defp broadcast_budget(session_id, budget_mod, mission_id, mission_status \\ nil) do
    %{spent: spent, cap: cap} = Budget.status(budget_mod, mission_id)

    PubSub.broadcast(
      session_id,
      {:live_updated, %{budget: %{spent: spent, cap: cap, mission_status: mission_status}}}
    )
  end

  # Same shape `Sprat.Mission.broadcast_inspector/3` feeds the Inspector
  # zone (`Terminal.Zones.Inspector.handle_view_update/2`), extended with
  # `:artifacts` — the Orchestrator's stage deliverables, absent from
  # Mission's single-agent path.
  defp broadcast_inspector(session_id, mission_id, store) do
    PubSub.broadcast(
      session_id,
      {:inspector_updated,
       %{
         sources: Sources.by_mission(store, mission_id),
         tasks: Tasks.by_mission(store, mission_id),
         artifacts: Artifacts.by_mission_with_content(store, mission_id),
         events: [],
         usage: Sprat.Store.Projection.usage_totals(store, mission_id)
       }}
    )
  end

  defp gate_result(session_id, stage, :ok, _errors) do
    :ok = Session.add_block(session_id, %{kind: :system, text: "✓ #{stage.title} gate passed."})
  end

  defp safe_transition(store, task_id, to_status, session_id, reason) do
    case Tasks.transition(store, task_id, to_status, %{session_id: session_id, reason: reason}) do
      {:ok, task} -> task
      {:error, _} -> nil
    end
  end

  defp record_message(store, session_id, task_id, role, content),
    do: Messages.append(store, session_id, %{task_id: task_id, role: role, content: content})

  defp system(session_id, lines),
    do: Session.add_block(session_id, %{kind: :system, text: Enum.join(List.wrap(lines), "\n")})
end
