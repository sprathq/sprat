defmodule Sprat.Mission do
  @moduledoc """
  Joins a plain user submission to a real run (docs/spec-v1.md §5/§8,
  scoped to this build's single-agent slice — no PM/Analyst, no
  delegation, no gates): one mission, one `researcher` task, run through
  `Sprat.Agent.Loop` against the owner's OpenAI key, streaming into the
  zoned UI via `Sprat.Session.PubSub` (never the renderer directly — §13)
  and `Sprat.Session.add_block/2` for the finished transcript entries.

  Runs in its own unlinked `Task` (`start/3` returns immediately) so a
  crash never takes the session down — a crash is recorded as a
  `task.transitioned -> failed` event and a visible error block, not
  silence.

  Cancellation (Ctrl+C, §13 "cancellation closes the HTTP stream, records
  usage seen so far and transitions the task") is a `:persistent_term`
  flag per session id — `cancel/1` sets it, the loop's `cancel?` polls it,
  `finish/1` always clears it. `ponytail:` one flag per session, not per
  task, because V1 runs one task at a time per session; add a per-task
  registry if that ever stops being true.

  ## One task at a time per session

  §8 gives every task exactly one owner, and this build runs one agent —
  so a submission that arrives while the session's current task is still
  `running` is **refused with a visible message**, not queued and not
  silently dropped, and no second mission/task is created. `start/3`
  checks a `:persistent_term` "active task" marker (set for the duration
  of `run_task/9`, cleared in its `after`) before doing anything else.
  This also closes the crash this module used to hit
  (`finish_ok/4` forcing `{:ok, _} = Tasks.transition(..., :completed,
  ...)`): every transition call here now goes through `settle/4`, which
  handles `{:error, :invalid_transition}` instead of crashing — a task
  already moved to a terminal state by something else (Recovery on a
  process restart, most often) is reported to the user, never forced.

  ## Context across submissions (§9 context package)

  Each run's `context_package` is assembled by `build_context/5` from the
  session's own stored transcript (`Sprat.Store.Messages`, prior user
  turns and prior agent final answers) plus the sources recorded so far
  in the session — never just the latest sentence — bounded to a share of
  the model's context window, oldest turns dropped first with an explicit
  note when that happens. The current request and the role prompt are
  never dropped. A `context.assembled` event records the token estimate,
  the source ids included and whether anything was dropped, visible in
  the Debug view's Events tab.
  """

  alias Sprat.Agent.Loop
  alias Sprat.Agent.Tools.{Calculate, RecordClaim, RecordSource, WebFetch, WebSearch}
  alias Sprat.Model.{OpenAI, Pricing}

  alias Sprat.Store.{
    Claims,
    Events,
    Grants,
    Messages,
    Missions,
    Projection,
    Sessions,
    Sources,
    Tasks
  }

  alias Sprat.{Budget, Config, Secrets, Session, Steering}
  alias Sprat.Session.PubSub
  alias Sprat.Store.Usage

  # web_search is added at run time only when search is actually
  # configured (see `search_enabled?/1`) -- §7: "If no search is
  # available, Sprat says so at the start of the mission ... and labels
  # every output 'no live research'", which starts with never offering
  # the tool to the model in the first place.
  @base_tools [WebFetch, Calculate, RecordSource, RecordClaim]
  @default_model "gpt-5-nano"
  @standard_budget "5.00"
  @deep_budget "15.00"
  @stream_tail_lines 6

  # -- context package (§9) ------------------------------------------------
  # Same 4-chars/token estimate `Sprat.Agent.Loop`/`Sprat.Agent.Tools.WebFetch`
  # already use — good enough for a budget, never claimed as a real count.
  @chars_per_token 4
  # Share of the model's context window this build spends on prior-turn
  # history; the rest is headroom for the role prompt, tool results and
  # the model's own output. `ponytail:` a single constant, not a config
  # setting — revisit if a real run ever needs it tuned per project.
  @history_budget_fraction 0.3
  @fallback_context_window 128_000

  # Same strengthening as Sprat.Orchestrator's search_note(true), and for
  # the same reason (defect backlog item 5: a real event-log count found
  # composed fetches concentrated on documentation/package hosts whose
  # URLs look guessable but frequently aren't) — kept in sync by hand
  # since this module's single-stage prompt isn't built from the same
  # `search_note/1` helper.
  @role_prompt """
  You are Sprat's researcher agent, running a single-stage research task \
  for the user directly (no product manager, no analyst — you own this \
  end to end). Use web_search to find pages that might answer the \
  question — do not guess or compose URLs from memory. This applies \
  doubly to documentation and package-index sites (hex.pm, hexdocs.pm, \
  github.com, elixirforum.com and similar): their URL structure looks \
  guessable but often isn't — search for the exact page instead of \
  guessing a path. web_search's \
  results are candidates, not evidence: title and snippet are the search \
  model's own paraphrase (snippet_origin: "model_summary"), never quote \
  or cite one directly. Use web_fetch to read the pages search finds (its \
  URLs are fetched without an approval prompt) and calculate for any \
  arithmetic. web_fetch returns an extract, not the full page — its \
  "text" may be truncated; the full page is kept as evidence regardless. \
  For every URL a claim in your answer relies on, call record_source (and \
  record_claim for the specific claim it supports, with a confidence and \
  a one-line justification) before you finish — an answer that cites a \
  URL you never recorded is not evidence, it's an unlabelled assertion. \
  Be concise and concrete; say plainly what you could not verify, and \
  label anything you didn't get from a source as an assumption rather \
  than stating it as fact.
  """

  @no_search_role_prompt """
  You are Sprat's researcher agent, running a single-stage research task \
  for the user directly (no product manager, no analyst — you own this \
  end to end). Live web search is not available in this mission (no \
  search backend configured) — you have no web_search tool, and only \
  web_fetch, which still requires a URL the user gave you or a link on a \
  page already fetched. State plainly that you have no live research \
  ability for this mission and every claim not sourced this way is model \
  knowledge, not verified evidence. Use calculate for any arithmetic. For \
  every URL a claim in your answer relies on, call record_source (and \
  record_claim for the specific claim it supports, with a confidence and \
  a one-line justification) before you finish. Be concise and concrete; \
  say plainly what you could not verify, and label anything you didn't \
  get from a source as an assumption rather than stating it as fact.
  """

  @doc "Cancels the running mission (if any) for `session_id`. Idempotent."
  def cancel(session_id), do: :persistent_term.put(cancel_key(session_id), true)

  defp cancel_key(session_id), do: {__MODULE__, :cancel, session_id}
  defp cancelled?(session_id), do: :persistent_term.get(cancel_key(session_id), false)
  defp clear_cancel(session_id), do: :persistent_term.erase(cancel_key(session_id))

  defp active_key(session_id), do: {__MODULE__, :active, session_id}
  defp active?(session_id), do: :persistent_term.get(active_key(session_id), false)
  defp mark_active(session_id), do: :persistent_term.put(active_key(session_id), true)
  defp clear_active(session_id), do: :persistent_term.erase(active_key(session_id))

  @doc """
  True while this quick single-agent path is running for `session_id`
  (docs/spec-v1.md §10). `Sprat.Session.Commands.handle_plain/3` reads
  this — mirrors `Sprat.Orchestrator.busy?/1` exactly, see its own doc.
  """
  def busy?(session_id), do: active?(session_id)

  defp active_mission_key(session_id), do: {__MODULE__, :active_mission, session_id}

  defp mark_active_mission(session_id, mission_id),
    do: :persistent_term.put(active_mission_key(session_id), mission_id)

  defp clear_active_mission(session_id),
    do: :persistent_term.erase(active_mission_key(session_id))

  @doc "Mirrors `Sprat.Orchestrator.active_mission_id/1` — see its own doc."
  def active_mission_id(session_id),
    do: :persistent_term.get(active_mission_key(session_id), nil)

  @doc """
  Starts a mission for `text` submitted in `session_id`. Returns
  immediately; the run happens in a background `Task`. `opts` (mainly for
  tests): `:store`, `:budget`, `:model_mod`, `:api_key`, `:model_id`
  (skips key/model resolution), `:sync?` (runs inline, for tests only).

  Refuses to start a second run while one is already active for this
  session (see moduledoc "One task at a time per session") — the
  submission is not queued, not silently dropped: a visible message says
  so, and nothing is created.
  """
  def start(session_id, text, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:sprat, :mission_defaults, []), opts)
    store = Keyword.get(opts, :store, Sprat.Store)
    budget_mod = Keyword.get(opts, :budget, Sprat.Budget)
    session = Sessions.get(store, session_id)

    if active?(session_id) do
      system(session_id, [
        "Still working on the previous request — this message wasn't sent. " <>
          "Wait for the researcher to finish, or press Ctrl+C to interrupt, then resend."
      ])
    else
      # Marked here, synchronously, before the (possibly async) runner ever
      # starts — not inside it — so a second `start/3` call arriving before
      # the background `Task` has actually begun still sees the session as
      # busy rather than racing it.
      mark_active(session_id)

      runner = fn ->
        try do
          run(session, session_id, store, budget_mod, text, opts)
        after
          clear_active(session_id)
          clear_active_mission(session_id)
        end
      end

      if Keyword.get(opts, :sync?, false) do
        runner.()
      else
        Task.start(runner)
      end
    end

    :ok
  end

  defp run(session, session_id, store, budget_mod, text, opts) do
    with {:ok, api_key} <- resolve_key(session_id, store, opts),
         {:ok, model_id} <- resolve_model(session, session_id, store, api_key, opts),
         {:ok, cap} <- resolve_budget(session, session_id, store, opts) do
      run_task(session, session_id, store, budget_mod, text, model_id, cap, api_key, opts)
    else
      :cancelled -> system(session_id, ["Mission not started: cancelled."])
      {:error, message} -> system(session_id, [message])
    end
  end

  defp resolve_key(_session_id, _store, opts) do
    case Keyword.get(opts, :api_key) || Secrets.resolve() do
      key when is_binary(key) ->
        Secrets.register(key)
        {:ok, key}

      {:ok, key, _source} ->
        Secrets.register(key)
        {:ok, key}

      :error ->
        {:error,
         "No OpenAI key configured (OPENAI_API_KEY, .env, or the OS credential store — " <>
           "run `sprat doctor`). Your message is saved but nothing ran."}
    end
  end

  # -- model selection (owner decision #2: manual, allowlist-intersected picker) --

  defp resolve_model(session, session_id, _store, api_key, opts) do
    case Keyword.get(opts, :model_id) || Config.model(session.project_path) do
      nil -> pick_first_model(session, session_id, api_key)
      model_id -> {:ok, model_id}
    end
  end

  defp pick_first_model(session, session_id, api_key) do
    catalog = Pricing.load()

    model_id =
      case OpenAI.list_models(api_key: api_key) do
        {:ok, ids} ->
          case Pricing.intersect(catalog, ids) do
            %{tested: [first | _]} -> first.id
            _ -> @default_model
          end

        {:error, _reason} ->
          @default_model
      end

    Config.put_model(session.project_path, model_id)

    system(session_id, [
      "Picked model `#{model_id}` for this project (first run — tested, allowlisted). " <>
        "Run /model to change it."
    ])

    {:ok, model_id}
  end

  @doc """
  Runs the `/model` picker: lists the account's models intersected with
  the shipped allowlist (tested first, untested second, with a warning),
  waits on a blocking numbered prompt, and persists the choice.
  """
  def pick_model(session_id, opts \\ []) do
    store = Keyword.get(opts, :store, Sprat.Store)
    session = Sessions.get(store, session_id)

    Task.start(fn ->
      with {:ok, api_key} <- resolve_key(session_id, store, opts),
           {:ok, ids} <- OpenAI.list_models(api_key: api_key) do
        catalog = Pricing.load()
        %{tested: tested, untested: untested} = Pricing.intersect(catalog, ids)
        options = model_options(tested, untested)

        case Session.await_permission(session_id, model_prompt(options)) do
          {:ok, n} when n < length(options) ->
            {model_id, _label} = Enum.at(options, n)
            Config.put_model(session.project_path, model_id)
            system(session_id, ["Model set to `#{model_id}`."])

          _ ->
            system(session_id, ["Model unchanged."])
        end
      else
        {:error, reason} when is_binary(reason) -> system(session_id, [reason])
        {:error, reason} -> system(session_id, ["Could not list models: #{inspect(reason)}"])
      end
    end)

    :ok
  end

  defp model_options(tested, untested) do
    tested_opts = Enum.map(tested, &{&1.id, "#{&1.id} (tested#{price_note(&1.price)})"})
    untested_opts = Enum.map(untested, &{&1, "#{&1} (untested — price unknown, not verified)"})
    tested_opts ++ untested_opts
  end

  defp price_note(%{input: nil}), do: ", price unknown"
  defp price_note(_), do: ""

  defp model_prompt(options) do
    %{
      title: "Pick a model",
      lines: ["Tested models first, then untested (still selectable, unverified):"],
      options: Enum.map(options, fn {_id, label} -> label end),
      selected: 0
    }
  end

  # -- budget (owner decision: $5 default, first mission confirms) ------------

  defp resolve_budget(session, session_id, _store, opts) do
    case Keyword.get(opts, :budget_cap) || Config.budget_usd(session.project_path) do
      nil -> confirm_budget(session, session_id)
      %Decimal{} = cap -> {:ok, cap}
    end
  end

  defp confirm_budget(session, session_id) do
    prompt = %{
      title: "Confirm mission budget",
      lines: ["First mission in this project. Pick a hard cap (V1 enforces it exactly):"],
      options: ["$#{@standard_budget} — standard depth", "$#{@deep_budget} — deep research"],
      selected: 0
    }

    case Session.await_permission(session_id, prompt) do
      {:ok, 1} -> {:ok, persist_budget(session, @deep_budget)}
      {:ok, _} -> {:ok, persist_budget(session, @standard_budget)}
      :cancelled -> :cancelled
    end
  end

  defp persist_budget(session, amount) do
    cap = Decimal.new(amount)

    # A user-level cap (Sprat.Config) can only ever be narrowed by a
    # project, never raised — if the offered $5/$15 choice would exceed
    # it, fall back to the user's own cap instead of silently ignoring
    # the enforcement error (see Sprat.Config.enforce_project_budget/2).
    case Config.put_budget_usd(session.project_path, cap) do
      :ok -> cap
      {:error, :exceeds_user_cap} -> Config.budget_usd_user()
    end
  end

  # -- search availability (§7: "no search available" is decided once, up
  # front, not discovered mid-mission) --------------------------------

  # Only "openai" is implemented (docs/design/web-search-options.md §7);
  # since it rides the same key already resolved for the main model
  # (§7's "no second API key"), search is available exactly when that key
  # resolved and the configured provider is the one backend that exists.
  defp resolve_search(session, api_key) do
    provider = Config.search_provider(session.project_path)
    model = Config.search_model(session.project_path)
    enabled? = provider == "openai" and is_binary(api_key) and api_key != ""
    %{enabled?: enabled?, provider: provider, model: model}
  end

  defp warn_no_live_search(session_id),
    do:
      system(session_id, [
        "No live search configured for this mission — the researcher has no web_search " <>
          "tool and can only fetch URLs you give it. Outputs are labelled \"no live " <>
          "research\" (docs/spec-v1.md §7)."
      ])

  # -- the run itself -----------------------------------------------------

  defp run_task(session, session_id, store, budget_mod, text, model_id, cap, api_key, opts) do
    {:ok, mission} = Missions.create(store, session_id, %{objective: text})
    mark_active_mission(session_id, mission.id)
    record_attachments(store, mission.id, Keyword.get(opts, :attachments, []))
    :ok = Budget.set_cap(budget_mod, mission.id, cap)
    :persistent_term.put(cap_key(session_id), cap)

    {:ok, task} = Tasks.create(store, mission.id, %{role: "researcher", objective: text})

    {:ok, task} =
      Tasks.transition(store, task.id, :running, %{session_id: session_id, actor: "sprat"})

    catalog = Keyword.get(opts, :catalog) || Pricing.load()

    context_package =
      build_context(store, session_id, mission.id, task.id, text, model_id, catalog)

    record_message(store, session_id, task.id, "user", "Assigned to Researcher: #{text}")
    broadcast_message(session_id, "user", "researcher", :assignment)
    broadcast_agents(session_id, [agent_view(task, :active, "starting")])

    {granted_urls, auto_hosts} = granted_fetches(store, session_id)
    auto_urls = MapSet.union(granted_urls, user_supplied_urls(text))

    search = resolve_search(session, api_key)
    if not search.enabled?, do: warn_no_live_search(session_id)

    loop_opts = %{
      model_mod: Keyword.get(opts, :model_mod, OpenAI),
      model_id: model_id,
      role_prompt: if(search.enabled?, do: @role_prompt, else: @no_search_role_prompt),
      context_package: context_package,
      tools: if(search.enabled?, do: [WebSearch | @base_tools], else: @base_tools),
      session_id: session_id,
      mission_id: mission.id,
      task_id: task.id,
      agent_id: "researcher",
      store: store,
      budget: budget_mod,
      api_key: api_key,
      catalog: catalog,
      tool_context: %{
        auto_fetch_urls: auto_urls,
        auto_fetch_hosts: auto_hosts,
        store: store,
        session_id: session_id,
        mission_id: mission.id,
        task_id: task.id,
        budget: budget_mod,
        catalog: catalog,
        api_key: api_key,
        search_provider: search.provider,
        search_model: search.model,
        secrets: Secrets.redaction_set()
      },
      on_delta: fn delta -> handle_delta(session_id, store, task, delta) end,
      steering_fetch: fn -> Steering.take_pending(store, session_id, mission.id) end,
      cancel?: fn -> cancelled?(session_id) end
    }

    result = run_and_settle(session, session_id, store, task, loop_opts, Loop.run(loop_opts))
    # ponytail: cleared here rather than in the `after` below (which also
    # covers a crash mid-run) because `mission` isn't bound on every path
    # into `after` -- a crash before this point leaves one mission's worth
    # of URLs in the persistent_term set, which is a bounded, session-scale
    # leak, not an unbounded one. Revisit if that ever proves wrong.
    WebSearch.clear_auto_fetch_urls(mission.id)
    result
  after
    clear_cancel(session_id)
  end

  defp run_and_settle(session, session_id, store, task, loop_opts, result) do
    case result do
      {:ok, %{content: content}} ->
        finish_ok(session_id, store, task, content)

      {:needs_approval, request, resume} ->
        handle_approval(session, session_id, store, task, loop_opts, request, resume)

      {:cancelled, _} ->
        finish_cancelled(session_id, store, task)

      {:error, reason} ->
        finish_error(session_id, store, task, reason)
    end
  end

  defp handle_approval(session, session_id, store, task, loop_opts, request, resume) do
    broadcast_agents(session_id, [
      agent_view(task, :waiting_on_user, "waiting for fetch approval")
    ])

    case Session.await_permission(session_id, fetch_prompt(request)) do
      {:ok, 0} ->
        record_grant(store, session_id, task.mission_id, "url", request.url)
        decision = {:approved, %{auto_fetch_urls: MapSet.new([request.url])}}
        continue_after_approval(session, session_id, store, task, loop_opts, resume, decision)

      {:ok, 1} ->
        host = URI.parse(request.url).host
        record_grant(store, session_id, task.mission_id, "domain", host)
        decision = {:approved, %{auto_fetch_hosts: MapSet.new([host])}}
        continue_after_approval(session, session_id, store, task, loop_opts, resume, decision)

      {:ok, _} ->
        continue_after_approval(session, session_id, store, task, loop_opts, resume, :denied)

      :cancelled ->
        continue_after_approval(session, session_id, store, task, loop_opts, resume, :denied)
    end
  end

  defp continue_after_approval(session, session_id, store, task, loop_opts, resume, decision) do
    run_and_settle(session, session_id, store, task, loop_opts, Loop.resume(resume, decision))
  end

  # -- grants (§9 "Reuse valid grants without repetitive prompts") --------

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

  # Seeds this run's auto-approved URLs/hosts from every grant already
  # recorded in this session, so a domain approved earlier in the
  # conversation (a *previous* mission — each submission is its own
  # mission in V1) is never re-prompted. `resource_scope` is respected
  # exactly: a "domain" grant matches only that exact host (never a
  # subdomain, never widened).
  # §9's fetch rule auto-approves "URLs that came from ... the user" — a
  # URL the user typed in their own submission is fetched without asking
  # (only URLs the *model* composes, or builds from a query string, need
  # approval). Without this, a plain "fetch https://example.com" hung
  # forever waiting on an approval prompt nobody could ever answer.
  @url_regex ~r/https?:\/\/[^\s<>"'\)\]]+/
  defp user_supplied_urls(text) do
    Regex.scan(@url_regex, text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,;:!?"))
    |> MapSet.new()
  end

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

  # -- context package (§9: assemble the run's messages from the stored
  # transcript, not just the latest sentence) -----------------------------

  @doc false
  # Public (via @doc false) so mission_test.exs can assert on the string
  # directly without going through a full Loop.run round trip.
  def build_context(store, session_id, mission_id, task_id, text, model_id, catalog) do
    budget_chars = context_window(catalog, model_id) * @history_budget_fraction * @chars_per_token

    turns =
      Messages.by_session(store, session_id)
      # `Sprat.Session.add_block/2` persists its own copy of every block to
      # this same table (JSON-encoded, for the transcript replay on
      # resume) — filtering to rows this module itself wrote (always
      # tagged with a `task_id`) keeps history to the one clean,
      # plain-text copy per turn instead of double-counting both.
      |> Enum.filter(&(&1.role in ["user", "researcher"] and not is_nil(&1.task_id)))
      |> Enum.map(&{&1.role, &1.content})

    {kept, dropped?} = fit_turns(turns, round(budget_chars))
    sources = session_sources(store, session_id)
    claims = session_claims(store, session_id)

    package = render_context(kept, dropped?, sources, claims, text)
    token_estimate = div(byte_size(package), @chars_per_token)

    Events.append(store, session_id, "context.assembled", %{
      mission_id: mission_id,
      task_id: task_id,
      payload: %{
        "turns_included" => length(kept),
        "turns_dropped" => length(turns) - length(kept),
        "truncated" => dropped?,
        "token_estimate" => token_estimate,
        "source_ids" => Enum.map(sources, & &1.id)
      }
    })

    package
  end

  defp context_window(catalog, model_id) do
    case Pricing.find(catalog, model_id) do
      %{context_window: window} when is_integer(window) and window > 0 -> window
      _ -> @fallback_context_window
    end
  end

  # Drops the oldest turns first until the remaining ones fit
  # `budget_chars`. The current request and the role prompt are assembled
  # separately by the caller and never touched here (§9: "Critical
  # instructions and acceptance criteria cannot be silently dropped").
  defp fit_turns(turns, budget_chars) do
    total = Enum.reduce(turns, 0, fn {_role, content}, acc -> acc + byte_size(content || "") end)

    if total <= budget_chars do
      {turns, false}
    else
      {drop_oldest(turns, total, budget_chars), true}
    end
  end

  defp drop_oldest([], _total, _budget_chars), do: []

  defp drop_oldest([{_role, content} | rest] = turns, total, budget_chars) do
    if total <= budget_chars,
      do: turns,
      else: drop_oldest(rest, total - byte_size(content || ""), budget_chars)
  end

  # Sources recorded anywhere in this session (every mission belonging to
  # it — each submission is its own mission in V1, but "this domain" in a
  # follow-up message means a source recorded in an *earlier* one).
  defp session_sources(store, session_id) do
    store
    |> Missions.by_session(session_id)
    |> Enum.flat_map(&Sources.by_mission(store, &1.id))
  end

  defp session_claims(store, session_id) do
    store
    |> Missions.by_session(session_id)
    |> Enum.flat_map(&Claims.by_mission(store, &1.id))
  end

  defp render_context(turns, dropped?, sources, claims, text) do
    [
      history_section(turns, dropped?),
      sources_section(sources),
      claims_section(claims),
      "Current request:\n#{text}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp history_section([], false), do: ""

  defp history_section(turns, dropped?) do
    note =
      if dropped?,
        do: "[Some earlier turns in this session were omitted to fit the context window.]\n",
        else: ""

    lines = Enum.map(turns, fn {role, content} -> "#{turn_label(role)}: #{content}" end)
    note <> "Prior conversation in this session (oldest first):\n" <> Enum.join(lines, "\n")
  end

  defp turn_label("user"), do: "User"
  defp turn_label("researcher"), do: "Researcher"

  defp sources_section([]), do: ""

  defp sources_section(sources) do
    lines =
      Enum.map(sources, fn s ->
        "- #{s.title || "(untitled)"} — #{s.url} (source id: #{s.id})" <>
          Sprat.Attachments.content_block(s)
      end)

    "Sources already recorded in this session:\n" <> Enum.join(lines, "\n")
  end

  # `@`-attach (docs/spec-v1.md §6): each attachment was already read,
  # hashed and blob-stored by `Sprat.Session.Commands.handle_plain/3`
  # before this mission existed — this just needs `mission.id` to write
  # the `Sprat.Store.Sources` row, which is why it happens here rather
  # than in the caller.
  defp record_attachments(store, mission_id, attachments) do
    Enum.each(attachments, &Sprat.Attachments.record_source(store, mission_id, &1))
  end

  defp claims_section([]), do: ""

  defp claims_section(claims) do
    lines =
      Enum.map(claims, fn c ->
        assumption = if c.is_assumption, do: " [assumption]", else: ""
        "- (#{c.confidence}) #{c.text}#{assumption}"
      end)

    "Claims already recorded in this session:\n" <> Enum.join(lines, "\n")
  end

  defp fetch_prompt(request) do
    %{
      title: "Fetch URL",
      lines: [
        "The researcher wants to fetch a URL it composed itself (docs/spec-v1.md §9):",
        "  #{request.url}"
      ],
      options: ["Yes", "Yes, and allow #{URI.parse(request.url).host} for this mission", "No"],
      selected: 0
    }
  end

  # A task already moved off `running` by something else (Recovery on a
  # process restart is the one this was written for; see
  # `Sprat.Store.Recovery`) must never be forced through the rest of the
  # state machine — `{:ok, _} = Tasks.transition(...)` used to crash the
  # whole Task with a `MatchError` the instant that happened
  # (`(MatchError) no match of right hand side value: {:error,
  # :invalid_transition}`). `transition_chain/4` walks `statuses` in order
  # and stops the moment one is rejected, reporting where it actually got
  # to instead of raising.
  defp transition_chain(store, task_id, statuses, session_id) do
    Enum.reduce_while(statuses, {:ok, nil}, fn to_status, _acc ->
      case Tasks.transition(store, task_id, to_status, %{session_id: session_id}) do
        {:ok, task} -> {:cont, {:ok, task}}
        {:error, :invalid_transition} -> {:halt, {:stale, Tasks.get(store, task_id)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp finish_ok(session_id, store, task, content) do
    case transition_chain(store, task.id, [:review_pending, :completed], session_id) do
      {:ok, _task} ->
        record_message(store, session_id, task.id, "researcher", content || "(no content)")

        :ok =
          Session.add_block(session_id, %{
            kind: :agent_message,
            role: "researcher",
            markdown: content || ""
          })

        broadcast_message(session_id, "researcher", "user", :handoff)
        broadcast_agents(session_id, [agent_view(task, :done, "handed off")])

      {:stale, current} ->
        record_message(store, session_id, task.id, "researcher", content || "(no content)")

        :ok =
          Session.add_block(session_id, %{
            kind: :system,
            text:
              "Researcher finished with an answer, but this task was already " <>
                "#{stale_status(current)} (most likely a process restart) — the answer is " <>
                "recorded, but the task could not be marked completed:\n\n" <>
                (content || "(no content)")
          })

        broadcast_agents(session_id, [
          agent_view(task, :blocked, "finished after #{stale_status(current)}")
        ])

      {:error, _reason} ->
        record_message(store, session_id, task.id, "researcher", content || "(no content)")

        :ok =
          Session.add_block(session_id, %{
            kind: :error,
            message: "Researcher finished, but its task could no longer be found.",
            suggestion: nil
          })
    end

    broadcast_inspector(session_id, task.mission_id, store)
    broadcast_budget(session_id, task.mission_id, store)
    Session.notify_finished(session_id, :completed)
  end

  defp stale_status(nil), do: "gone"
  defp stale_status(%{status: status}), do: status

  defp failure_suggestion({:http_error, 401, _body}),
    do: "Check the OpenAI key — run `sprat doctor`."

  defp failure_suggestion({:http_error, status, _body}) when status in [403, 404],
    do: "The model may not be enabled for this key — run /model to pick another."

  defp failure_suggestion(:price_unknown),
    do: "This model's price isn't in the allowlist — run /model."

  defp failure_suggestion({:would_exceed_cap, _}), do: "Over the mission budget cap."
  defp failure_suggestion(_), do: nil

  # Human message for the conversation (task brief: a raw tuple like
  # `{:http_error, 401, ""}` must never reach the transcript) — the raw
  # `reason` stays available in the debug view via `Tasks.transition/4`'s
  # own `reason: inspect(reason)`, set unchanged in `finish_error/4` below.
  defp failure_message({:http_error, 401, _body}),
    do: "Researcher failed: the OpenAI key was rejected (401 Unauthorized)."

  defp failure_message({:http_error, status, _body}) when status in [403, 404],
    do: "Researcher failed: the API call was rejected (HTTP #{status})."

  defp failure_message({:http_error, status, _body}),
    do: "Researcher failed: the API call failed (HTTP #{status})."

  defp failure_message(:price_unknown),
    do: "Researcher failed: this model's price isn't in the allowlist."

  defp failure_message({:would_exceed_cap, _}),
    do: "Researcher failed: would exceed the mission budget cap."

  defp failure_message(:timeout), do: "Researcher failed: timed out."
  defp failure_message(_), do: "Researcher failed: an unexpected error occurred."

  # Single-step version of `transition_chain/4` that carries `attrs`
  # (`:reason`) through — used by `finish_cancelled/3` and `finish_error/4`,
  # which each make exactly one transition attempt and must not crash if
  # the task already moved (same root cause as `finish_ok/4`, see its
  # comment).
  defp safe_transition(store, task_id, to_status, attrs) do
    case Tasks.transition(store, task_id, to_status, attrs) do
      {:ok, task} -> {:ok, task}
      {:error, :invalid_transition} -> {:stale, Tasks.get(store, task_id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_cancelled(session_id, store, task) do
    text =
      case safe_transition(store, task.id, :interrupted, %{
             session_id: session_id,
             reason: "cancelled by user"
           }) do
        {:ok, _task} ->
          "Researcher interrupted — usage so far is recorded as estimated."

        {:stale, current} ->
          "Researcher was cancelled, but this task was already #{stale_status(current)} — " <>
            "usage so far is recorded as estimated."

        {:error, _reason} ->
          "Researcher was cancelled, but its task could no longer be found."
      end

    :ok = Session.add_block(session_id, %{kind: :system, text: text})

    broadcast_agents(session_id, [agent_view(task, :blocked, "cancelled")])
    broadcast_inspector(session_id, task.mission_id, store)
    broadcast_budget(session_id, task.mission_id, store)
  end

  defp finish_error(session_id, store, task, reason) do
    case safe_transition(store, task.id, :failed, %{
           session_id: session_id,
           reason: inspect(reason)
         }) do
      {:ok, _task} ->
        :ok =
          Session.add_block(session_id, %{
            kind: :error,
            message: failure_message(reason),
            suggestion: failure_suggestion(reason)
          })

      {:stale, current} ->
        :ok =
          Session.add_block(session_id, %{
            kind: :error,
            message:
              "#{failure_message(reason)} (task was already #{stale_status(current)}, not " <>
                "re-marked failed)",
            suggestion: failure_suggestion(reason)
          })

      {:error, _reason} ->
        :ok =
          Session.add_block(session_id, %{
            kind: :error,
            message: failure_message(reason),
            suggestion: failure_suggestion(reason)
          })
    end

    broadcast_agents(session_id, [agent_view(task, :blocked, "failed: #{inspect(reason)}")])
    broadcast_inspector(session_id, task.mission_id, store)
    broadcast_budget(session_id, task.mission_id, store)
    Session.notify_finished(session_id, :failed)
  end

  # -- streaming into the zones --------------------------------------------

  defp handle_delta(session_id, _store, task, %{type: :content, text: text}) do
    accumulate(task.id, text)
    tail = tail_lines(task.id)
    broadcast_agents(session_id, [agent_view(task, :active, "streaming", tail)])
  end

  defp handle_delta(session_id, store, task, %{type: :tool_call, name: name})
       when is_binary(name) do
    broadcast_agents(session_id, [agent_view(task, :waiting_on_tool, "calling #{name}")])
    broadcast_budget(session_id, task.mission_id, store)
  end

  defp handle_delta(_session_id, _store, _task, _delta), do: :ok

  defp accumulate(task_id, text) do
    key = {__MODULE__, :buffer, task_id}
    current = :persistent_term.get(key, "")
    :persistent_term.put(key, current <> text)
  end

  defp tail_lines(task_id) do
    :persistent_term.get({__MODULE__, :buffer, task_id}, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_every(10)
    |> Enum.map(&Enum.join(&1, " "))
    |> Enum.take(-@stream_tail_lines)
  end

  # -- view models / broadcasts (never the renderer directly — §13) -------

  defp agent_view(task, state, activity, stream_tail \\ nil) do
    %{
      id: task.id,
      role: :researcher,
      label: "Researcher",
      state: state,
      elapsed_s: nil,
      tokens: nil,
      activity: activity,
      stream_tail: stream_tail
    }
  end

  defp broadcast_agents(session_id, agents),
    do: PubSub.broadcast(session_id, {:agents_updated, %{agents: agents}})

  defp broadcast_budget(session_id, mission_id, store) do
    cap = :persistent_term.get(cap_key(session_id), nil)

    spent =
      case Usage.by_mission(store, mission_id) |> Usage.totals() do
        %{cost: nil} -> nil
        %{cost: cost} -> cost
      end

    PubSub.broadcast(session_id, {:live_updated, %{budget: %{spent: spent, cap: cap}}})
  end

  defp cap_key(session_id), do: {__MODULE__, :cap, session_id}

  defp broadcast_message(session_id, from, to, type),
    do:
      PubSub.broadcast(
        session_id,
        {:message_added, %{from: from, to: to, type: type, at: clock()}}
      )

  defp broadcast_inspector(session_id, mission_id, store) do
    sources = Sources.by_mission(store, mission_id)
    tasks = Tasks.by_mission(store, mission_id)
    totals = Projection.usage_totals(store, mission_id)

    PubSub.broadcast(
      session_id,
      {:inspector_updated, %{sources: sources, tasks: tasks, events: [], usage: totals}}
    )
  end

  defp clock, do: DateTime.utc_now() |> DateTime.to_string() |> String.slice(11, 8)

  defp record_message(store, session_id, task_id, role, content),
    do: Messages.append(store, session_id, %{task_id: task_id, role: role, content: content})

  defp system(session_id, lines),
    do: Session.add_block(session_id, %{kind: :system, text: Enum.join(lines, "\n")})
end
