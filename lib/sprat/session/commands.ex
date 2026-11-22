defmodule Sprat.Session.Commands do
  @moduledoc """
  Slash commands wired to real data (docs/spec-v1.md §10). Every view
  reads through `Sprat.Store`/`Sprat.Store.Projection`; a mission that
  never ran (no key configured, or nothing submitted yet) still says so
  honestly instead of fabricating numbers. `handle/3` is the single entry
  point the composer's submitted text goes through — a `/`-prefixed line
  dispatches here, a plain line is recorded and handed to
  `Sprat.Mission.start/3`, which runs a real single-agent mission against
  the configured model (see its moduledoc for the single-agent V1 scope).
  `/idea` and `/research` are the heavier staged path: they dispatch to
  `Sprat.Orchestrator.start/5` instead, walking `Sprat.Workflow.Idea`/
  `Opportunity` stage by stage; `/depth` changes which depth the *next*
  one of those uses. A plain message never takes this path — see
  `handle_plain/3`.
  """

  alias Sprat.Store.{Artifacts, Claims, Events, Missions, Paths, Projection, Sessions, Tasks}
  alias Sprat.CLI.Doctor
  alias Sprat.Export.Markdown
  alias Sprat.{Attachments, Config, Export, Orchestrator, Secrets, Session, Steering}
  alias Sprat.Workflow.{Build, Idea, Opportunity}

  @commands [
    {"idea", "Start the idea-shaping workflow"},
    {"research", "Start the opportunity-discovery workflow"},
    {"build",
     "Start the build workflow (technical design, then scaffold) from the current brief"},
    {"depth", "Change research depth (quick/standard/deep)"},
    {"help", "Commands and keys"},
    {"clear", "Start a new session (the old one stays resumable)"},
    {"resume", "Pick a previous session in this project"},
    {"events", "Event timeline"},
    {"usage", "Usage breakdown"},
    {"sources", "Source register"},
    {"tasks", "Task tree with owner, status, attempt"},
    {"artifacts", "Artifact list and versions"},
    {"open", "Print an artifact's latest version"},
    {"claims", "Claims with confidence, unsupported first"},
    {"model", "Pick the model for this project"},
    {"settings", "Effective settings and where each came from (Alt+s for the live overlay)"},
    {"debug", "Requests/Tools/Events/Costs/Logs (Alt+d for the live overlay)"},
    {"doctor", "Same checks as sprat doctor"},
    {"export",
     "Export the mission as a readable Markdown bundle (README, brief, sources, usage...)"}
  ]

  @doc "The command list, for the composer's `/`-menu (`commands:` option)."
  def list, do: @commands

  @doc """
  Handles one submitted line for `session_id`. Returns `:ok`, or
  `{:switch_session, new_session_id}` for `/clear`, which the caller
  (`Sprat.Session.Shell`) must act on by re-pointing its subscriber.
  """
  def handle(session_id, store, text) do
    case String.trim(text) do
      "/" <> rest -> dispatch(session_id, store, rest)
      "" -> :ok
      plain -> handle_plain(session_id, store, plain)
    end
  end

  # docs/spec-v1.md §10: "Messages typed while agents work are queued and
  # delivered at the next safe boundary... shown dimmed until delivered."
  # Precedence, checked in this order (each one that fires stops there —
  # see each clause's comment for why it has to come before the next):
  #
  #   1. The Directions choice point (`Orchestrator.pending_choice?/1`) —
  #      unchanged, already the one place free text answers a prompt
  #      instead of steering an in-flight turn (there is no in-flight
  #      turn: the walk is paused waiting for exactly this).
  #   2. Any other pending numbered prompt (fetch approval, a stage's
  #      retry/skip/abandon offer, the first-run budget/model pickers —
  #      anything showing in `live.permission`) — free text is never a
  #      valid answer to one of these (only `answer_permission/2`'s
  #      numeric choice is), and a busy mission paused on one isn't
  #      running any turns for steering to reach anyway, so queuing it
  #      would be a message that silently never arrives. Recorded as an
  #      ordinary (non-steering) message instead, with a note that it
  #      wasn't queued — the build brief's "must still go to that prompt,
  #      not the steering queue".
  #   3/4. A staged mission (`Orchestrator.busy?/1`) or the quick
  #      single-agent path (`Sprat.Mission.busy?/1`) actually running a
  #      turn — steering, via `Sprat.Steering.queue/4` instead of the
  #      flat refusal this used to be.
  #   5. Nothing running — the ordinary fresh-mission path, unchanged.
  defp handle_plain(session_id, store, text) do
    cond do
      Orchestrator.pending_choice?(session_id) ->
        :ok = Session.submit_user_message(session_id, text)
        # ponytail: an attachment made while answering a Directions choice
        # isn't threaded through (that path resumes an existing mission
        # rather than creating one) — add if that turns out to matter.
        :ok = Orchestrator.user_choice(session_id, text)

      pending_prompt?(session_id) ->
        :ok = Session.submit_user_message(session_id, text)

        system(session_id, [
          "There's a prompt above waiting for a numbered answer — pick an option (or Esc) " <>
            "before sending another message. This one wasn't sent to the mission."
        ])

      Orchestrator.busy?(session_id) ->
        queue_steering(session_id, store, text, Orchestrator.active_mission_id(session_id))

      Sprat.Mission.busy?(session_id) ->
        queue_steering(session_id, store, text, Sprat.Mission.active_mission_id(session_id))

      true ->
        :ok = Session.submit_user_message(session_id, text)
        session = Sessions.get(store, session_id)
        root = session && session.project_path

        with_attachments(session_id, root, text, fn attachments ->
          :ok = Sprat.Mission.start(session_id, text, store: store, attachments: attachments)
        end)
    end

    :ok
  end

  defp pending_prompt?(session_id), do: Session.snapshot(session_id).live.permission != nil

  # `mission_id` can briefly be `nil` — the instant between the busy flag
  # flipping and the mission row actually being created (see
  # `Orchestrator.active_mission_id/1`'s own doc). Nothing to attach
  # steering to yet in that window; the message is still recorded, just
  # not queued — vanishingly rare in practice (a background `Task` not
  # yet scheduled) and never silent.
  defp queue_steering(session_id, _store, text, nil) do
    :ok =
      Session.add_block(session_id, %{kind: :user_message, text: text, queued?: true})

    system(session_id, [
      "The mission is still starting — this will reach it once it begins."
    ])
  end

  defp queue_steering(session_id, store, text, mission_id) do
    :ok =
      Session.add_block(session_id, %{kind: :user_message, text: text, queued?: true})

    {:ok, _message} = Steering.queue(store, session_id, mission_id, text)

    system(session_id, [
      "queued — will reach the Researcher at the next turn."
    ])
  end

  # -- `@`-attach (docs/spec-v1.md §6/§10) -----------------------------------
  #
  # Shared by a plain message and `/idea`/`/research`: resolves and reads
  # every in-root mention synchronously (no approval needed — attaching is
  # the user's own explicit act) and calls `continuation` with the finished
  # attachment list. An out-of-root mention needs a one-time confirm, which
  # can only resolve once `Sprat.Session.Shell`'s loop is free to receive
  # the answering intent — so only that case defers into a `Task.start`.
  defp with_attachments(session_id, root, text, continuation) do
    {in_root, needs_confirm, refused} = triage_mentions(root, Attachments.mentions(text))
    report_refusals(session_id, refused)

    if needs_confirm == [] do
      continuation.(attach_all(session_id, root, in_root))
    else
      Task.start(fn ->
        {:ok, confirmed} = confirm_all(session_id, needs_confirm)
        continuation.(attach_all(session_id, root, in_root ++ confirmed))
      end)
    end

    :ok
  end

  defp triage_mentions(nil, _mentions), do: {[], [], []}

  defp triage_mentions(root, mentions) do
    {ok, confirm, refused} =
      Enum.reduce(mentions, {[], [], []}, fn raw, {ok, confirm, refused} ->
        case Attachments.resolve(root, raw) do
          {:ok, real, :in_root} -> {[real | ok], confirm, refused}
          {:confirm, real} -> {ok, [real | confirm], refused}
          {:error, :not_found} -> {ok, confirm, refused}
          {:error, reason} -> {ok, confirm, [{raw, reason} | refused]}
        end
      end)

    {Enum.reverse(ok), Enum.reverse(confirm), Enum.reverse(refused)}
  end

  defp confirm_all(session_id, real_paths) do
    confirmed =
      Enum.filter(real_paths, fn real ->
        prompt = %{
          title: "Attach file outside the project",
          lines: [real, "This path is outside the project directory — attach it as evidence?"],
          options: ["Yes, attach it", "No, skip it"],
          selected: 0
        }

        match?({:ok, 0}, Session.await_permission(session_id, prompt))
      end)

    {:ok, confirmed}
  end

  defp attach_all(session_id, root, real_paths) do
    secrets = Secrets.redaction_set()
    blob_root = Paths.blobs_dir()
    results = Enum.map(real_paths, &{&1, Attachments.attach(root, &1, secrets, blob_root)})

    attachments =
      for {_real, {:ok, attachment}} <- results do
        announce_attachment(session_id, attachment)
        attachment
      end

    report_attach_errors(session_id, for({real, {:error, reason}} <- results, do: {real, reason}))
    attachments
  end

  defp announce_attachment(session_id, attachment) do
    rows = if attachment.row_count, do: " (#{attachment.row_count} rows)", else: ""
    truncated = if attachment.truncated?, do: ", truncated to fit", else: ""
    system(session_id, ["Attached #{attachment.path}#{rows}#{truncated} — recorded as evidence."])
  end

  defp report_refusals(_session_id, []), do: :ok

  defp report_refusals(session_id, refused) do
    lines = Enum.map(refused, fn {raw, reason} -> "@#{raw}: #{refusal_message(reason)}" end)
    system(session_id, ["Could not attach:" | lines])
  end

  defp report_attach_errors(_session_id, []), do: :ok

  defp report_attach_errors(session_id, errors) do
    lines =
      Enum.map(errors, fn {real, reason} ->
        "#{Path.basename(real)}: #{refusal_message(reason)}"
      end)

    system(session_id, ["Could not attach:" | lines])
  end

  defp refusal_message(:denied), do: "blocked — matches a deny pattern (.env*, keys, ...)"
  defp refusal_message(:is_a_directory), do: "is a directory, not a file"
  defp refusal_message({:unsupported, ext}), do: "#{ext} files aren't supported yet"
  defp refusal_message(reason), do: inspect(reason)

  # -- /idea, /research, /depth (docs/spec-v1.md §10, §5) -------------------
  #
  # A `/`-prefixed staged command runs the full `Sprat.Orchestrator` stage
  # walk instead of `Sprat.Mission`'s single-agent quick path — the
  # proportionate-work split the plan calls for (`handle_plain/3` above is
  # untouched). Depth persists via `Sprat.Config.research_depth/1`
  # (project-scoped, already the config's natural home for it — see its
  # moduledoc) rather than a new store.

  defp start_staged(session_id, _store, template_mod, "") do
    system(session_id, [
      "Usage: /#{staged_command_name(template_mod)} <what you want researched>"
    ])
  end

  defp start_staged(session_id, store, template_mod, text) do
    session = Sessions.get(store, session_id)
    depth = depth_for(session)

    case resolve_staged_opts(session, store, depth) do
      {:ok, opts} ->
        :ok = Session.submit_user_message(session_id, text)

        with_attachments(session_id, session.project_path, text, fn attachments ->
          :ok =
            Orchestrator.start(
              session_id,
              text,
              template_mod,
              depth,
              Keyword.put(opts, :attachments, attachments)
            )
        end)

      {:error, message} ->
        system(session_id, [message])
    end
  end

  defp staged_command_name(Idea), do: "idea"
  defp staged_command_name(Opportunity), do: "research"

  # docs/spec-v2.md §5: "/build starts the build workflow from an
  # existing mission's brief; a fresh mission can run research and build
  # in one pass." "Refusing with a clear message when there is no brief"
  # (build brief item 5) — the latest mission in this session with a
  # delivered `product_brief` artifact, most recent first, is the brief
  # /build works from; its content is seeded into the new build mission
  # (`Orchestrator.run/6`'s `seed_artifacts:`) so `Sprat.Workflow.Build`'s
  # :technical_design stage finds it the ordinary way.
  defp start_build(session_id, store) do
    session = Sessions.get(store, session_id)

    case latest_brief(store, session_id) do
      nil ->
        system(session_id, [
          "No product brief yet in this session — run /idea first (through Delivery), " <>
            "then /build."
        ])

      brief ->
        depth = depth_for(session)

        case resolve_staged_opts(session, store, depth) do
          {:ok, opts} ->
            text = "Build the MVP for: #{brief["problem"]} (customer: #{brief["customer"]})"
            :ok = Session.submit_user_message(session_id, "/build")

            :ok =
              Orchestrator.start(
                session_id,
                text,
                Build,
                depth,
                Keyword.put(opts, :seed_artifacts, [{:product_brief, brief}])
              )

          {:error, message} ->
            system(session_id, [message])
        end
    end
  end

  defp latest_brief(store, session_id) do
    store
    |> Missions.by_session(session_id)
    |> Enum.reverse()
    |> Enum.find_value(fn mission -> Artifacts.latest(store, mission.id, :product_brief) end)
  end

  defp depth_for(session),
    do: session.project_path |> Config.research_depth() |> String.to_existing_atom()

  defp set_depth(session_id, store, depth_str) do
    session = Sessions.get(store, session_id)

    case depth_str do
      d when d in ["quick", "standard", "deep"] ->
        :ok = Config.put_research_depth(session.project_path, d)
        system(session_id, ["Depth set to #{d} for the next /idea or /research."])

      _ ->
        system(session_id, [
          "Usage: /depth quick|standard|deep. Current: #{Config.research_depth(session.project_path)}"
        ])
    end
  end

  # `Sprat.Orchestrator.start/5` takes `model_id`/`api_key` already
  # resolved (unlike `Sprat.Mission.start/3`, which resolves them itself).
  # This mirrors that resolution — same key lookup, same "no model picked
  # yet" honesty — but deliberately skips `Sprat.Mission`'s interactive
  # first-run flows (auto model pick via a live models list, budget
  # confirm prompt): a staged mission that hits either gap asks the user
  # to run a plain message or /model first instead of silently guessing.
  # ponytail: known simplification — fold in the shared picker if staged
  # missions turn out to be most users' first run in a project.
  defp resolve_staged_opts(session, store, depth) do
    base = Keyword.merge(Application.get_env(:sprat, :mission_defaults, []), store: store)

    with {:ok, api_key} <- resolve_staged_key(base),
         {:ok, model_id} <- resolve_staged_model(session, base) do
      cap =
        Keyword.get(base, :budget_cap) || Config.budget_usd(session.project_path) ||
          default_cap(depth)

      {:ok,
       Keyword.merge(base,
         api_key: api_key,
         model_id: model_id,
         budget_cap: cap,
         search_provider: Config.search_provider(session.project_path),
         search_model: Config.search_model(session.project_path)
       )}
    end
  end

  defp resolve_staged_key(opts) do
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

  defp resolve_staged_model(session, opts) do
    case Keyword.get(opts, :model_id) || Config.model(session.project_path) do
      nil ->
        {:error,
         "No model picked yet for this project — run a plain message or /model first, " <>
           "then retry."}

      model_id ->
        {:ok, model_id}
    end
  end

  defp default_cap(:deep), do: Decimal.new("15.00")
  defp default_cap(_), do: Decimal.new("5.00")

  defp dispatch(session_id, store, rest) do
    {cmd, arg} =
      case String.split(rest, " ", parts: 2) do
        [cmd] -> {cmd, ""}
        [cmd, arg] -> {cmd, String.trim(arg)}
      end

    case cmd do
      "idea" -> start_staged(session_id, store, Idea, arg)
      "research" -> start_staged(session_id, store, Opportunity, arg)
      "build" -> start_build(session_id, store)
      "depth" -> set_depth(session_id, store, arg)
      "help" -> system(session_id, help_lines())
      "clear" -> clear(session_id, store)
      "resume" -> resume_list(session_id, store)
      "events" -> events(session_id, store, arg)
      "usage" -> usage(session_id, store)
      "sources" -> sources(session_id, store)
      "tasks" -> tasks(session_id, store)
      "artifacts" -> artifacts(session_id, store)
      "open" -> open_artifact(session_id, store, arg)
      "claims" -> claims(session_id, store)
      "model" -> Sprat.Mission.pick_model(session_id, store: store)
      "settings" -> settings(session_id, store)
      "debug" -> debug(session_id, store)
      "doctor" -> system(session_id, Doctor.report(store))
      "export" -> export(session_id, store, arg)
      other -> system(session_id, ["Unknown command /#{other}. Try /help."])
    end
  end

  defp system(session_id, lines) when is_list(lines) do
    :ok = Session.add_block(session_id, %{kind: :system, text: Enum.join(lines, "\n")})
  end

  defp help_lines do
    command_lines = Enum.map(@commands, fn {name, desc} -> "  /#{name} — #{desc}" end)

    [
      "Commands:" | command_lines
    ] ++
      [
        "",
        "Keys: Esc interrupt/close · Esc Esc edit an earlier message · Ctrl+C clear/interrupt " <>
          "· Ctrl+D exit · Shift+Tab cycle mode · Ctrl+O verbose · Ctrl+T checklist · Ctrl+L redraw · ? shortcuts"
      ]
  end

  defp clear(session_id, store) do
    session = Sessions.get(store, session_id)
    {:ok, new_session} = Sessions.create(store, %{project_path: session.project_path})

    system(session_id, [
      "Starting a new session (#{new_session.id}). This one stays resumable — " <>
        "run `sprat --resume #{session_id}` to come back to it."
    ])

    {:switch_session, new_session.id}
  end

  defp resume_list(session_id, store) do
    session = Sessions.get(store, session_id)

    other_sessions =
      store |> Sessions.by_project(session.project_path) |> Enum.reject(&(&1.id == session_id))

    case other_sessions do
      [] ->
        system(session_id, ["No other sessions for this project yet."])

      list ->
        lines = Enum.map(list, &"  #{&1.id}  started #{&1.started_at}")

        system(session_id, [
          "Other sessions in this project — `sprat --resume <id>` to switch:" | lines
        ])
    end
  end

  defp events(session_id, store, filter) do
    all = Events.by_session(store, session_id, limit: 100_000)

    matching =
      if filter == "", do: all, else: Enum.filter(all, &String.contains?(&1.type, filter))

    shown = Enum.take(matching, -200)

    lines =
      if shown == [],
        do: ["No events match."],
        else: Enum.map(shown, &"  #{&1.seq}  #{&1.occurred_at}  #{&1.type}")

    note =
      if length(matching) > length(shown),
        do: ["", "(showing the last #{length(shown)} of #{length(matching)})"],
        else: []

    system(session_id, ["Events:" | lines] ++ note)
  end

  defp usage(session_id, store) do
    case Missions.by_session(store, session_id) do
      [] ->
        system(session_id, [
          "No usage recorded — no model backend is configured yet (spec §7/§15). Nothing has been billed."
        ])

      missions ->
        lines =
          Enum.map(missions, fn mission ->
            totals = Projection.usage_totals(store, mission.id)
            cost = if totals.cost, do: "$#{totals.cost}", else: "cost unknown"
            "  #{mission.objective}: #{totals.calls} calls, #{cost}"
          end)

        system(session_id, ["Usage:" | lines])
    end
  end

  defp sources(session_id, store) do
    case Missions.by_session(store, session_id) do
      [] ->
        system(session_id, ["No sources recorded yet."])

      missions ->
        lines =
          missions
          |> Enum.flat_map(&Projection.source_register(store, &1.id))
          |> Enum.map(&"  #{&1.title || &1.url}  (#{&1.source_type})")

        if lines == [],
          do: system(session_id, ["No sources recorded yet."]),
          else: system(session_id, ["Sources:" | lines])
    end
  end

  defp tasks(session_id, store) do
    case Missions.by_session(store, session_id) do
      [] ->
        system(session_id, [
          "No tasks — Sprat has no orchestration engine in this build (out of scope, spec §15)."
        ])

      missions ->
        lines = missions |> Enum.flat_map(&task_tree_lines(store, &1))
        if lines == [], do: system(session_id, ["No tasks yet."]), else: system(session_id, lines)
    end
  end

  defp task_tree_lines(store, mission) do
    case Projection.task_tree(store, mission.id) do
      [] -> []
      nodes -> ["#{mission.objective}:" | Enum.flat_map(nodes, &task_node_lines(&1, 1))]
    end
  end

  defp task_node_lines(%{task: task, children: children}, depth) do
    indent = String.duplicate("  ", depth)
    line = "#{indent}#{task.role} · #{task.objective} (#{task.status}, attempt #{task.attempt})"
    [line | Enum.flat_map(children, &task_node_lines(&1, depth + 1))]
  end

  # -- /artifacts, /open, /claims (staged-workflow's versioned
  # deliverables and claim log, docs/spec-v1.md §5/§6) — same "latest
  # mission in this session" scope /usage and /sources already use. -------

  defp artifacts(session_id, store) do
    case latest_mission(store, session_id) do
      nil ->
        system(session_id, ["No mission yet."])

      mission ->
        list = Artifacts.by_mission(store, mission.id)

        lines =
          Enum.map(list, fn a ->
            content = Artifacts.latest(store, mission.id, a.type)
            stale = if a.stale, do: " [STALE — #{a.stale_reason}]", else: ""

            "  #{a.type} v#{a.latest_version} (#{a.owning_role})#{stale} — #{Markdown.summary(a.type, content)}"
          end)

        system(
          session_id,
          if(list == [], do: ["No artifacts yet."], else: ["Artifacts:" | lines])
        )
    end
  end

  defp open_artifact(session_id, _store, "") do
    system(session_id, ["Usage: /open <artifact type>"])
  end

  # Renders as Markdown, not raw JSON (docs/spec-v1.md §19). Prints
  # straight into the Conversation zone rather than shelling out to
  # `$PAGER` for a long artifact — a real pager spawn races
  # `Sprat.Terminal.Input`'s permanently-blocked raw-stdin reader for the
  # same tty (see its moduledoc on why a plain `System.cmd/3` port never
  # gets real controlling-tty descriptors here), the exact hazard
  # `Terminal.ZonedRenderer`'s `:open_pager` key binding already stubs out
  # as "$PAGER integration: stage 2". Real `$PAGER` support is deferred
  # until that tty-handoff work exists — both need the same fix; `/export`
  # is the honest way to get a long artifact onto disk today.
  defp open_artifact(session_id, store, type) do
    case latest_mission(store, session_id) do
      nil ->
        system(session_id, ["No mission yet."])

      mission ->
        # `Artifacts.latest/3` already does `to_string(type)` internally
        # (types are stored as plain strings, never atoms) — passing the
        # raw arg straight through avoids `String.to_existing_atom/1`'s
        # atom-table fragility (whether a given deliverable type's atom
        # happens to have been loaded yet is not something this command
        # should depend on).
        case Artifacts.latest(store, mission.id, type) do
          nil -> system(session_id, ["No artifact of type #{type} yet."])
          content -> system(session_id, ["# #{type}\n\n" <> Markdown.render(type, content)])
        end
    end
  end

  defp claims(session_id, store) do
    case latest_mission(store, session_id) do
      nil ->
        system(session_id, ["No mission yet."])

      mission ->
        list = Claims.by_mission(store, mission.id)

        # `Claims.by_mission/2` doesn't join `claim_sources`, so
        # `is_assumption` alone is the only available proxy for "no
        # supporting source" (docs/spec-v1.md's definition of
        # unsupported) — confidence is a separate axis and isn't part of
        # that test.
        {unsourced, sourced} = Enum.split_with(list, & &1.is_assumption)
        lines = Enum.map(unsourced ++ sourced, &claim_line/1)

        system(
          session_id,
          if(list == [],
            do: ["No claims recorded yet."],
            else: ["Claims (unsupported first):" | lines]
          )
        )
    end
  end

  defp claim_line(claim) do
    suffix = if claim.is_assumption, do: " [assumption]", else: ""
    "  (#{claim.confidence}) #{claim.text}#{suffix}"
  end

  defp latest_mission(store, session_id),
    do: store |> Missions.by_session(session_id) |> List.last()

  # -- /settings (docs/spec-v1.md §13 "Precedence... /doctor shows
  # effective values and where each came from") — same content the
  # Alt+s overlay shows, as a committed transcript block; see
  # `Sprat.Config.effective/1` for the precedence logic itself. -------------

  defp settings(session_id, store) do
    session = Sessions.get(store, session_id)
    entries = Config.effective(session.project_path)
    key_line = key_status_line(session.project_path)

    lines =
      ["Settings (effective values):", key_line, ""] ++
        Enum.map(entries, &setting_line/1) ++
        ["", "Alt+s opens the live overlay; Enter on an editable row there edits it."]

    system(session_id, lines)
  end

  defp key_status_line(project_path) do
    case Secrets.status(project_path || File.cwd!()) do
      {:ok, %{present: false}} ->
        "  API key: not set (OPENAI_API_KEY, .env, or the OS credential store)"

      {:ok, %{present: true, source: source, last4: last4}} ->
        "  API key: set, from #{Secrets.describe_source(source)} (…#{last4})"
    end
  end

  defp setting_line(%{value: nil} = e), do: "  #{e.label}: unset (#{e.source}) — #{e.note}"

  defp setting_line(%{key: "budget_usd", value: %Decimal{} = d} = e),
    do: "  #{e.label}: $#{Decimal.round(d, 2)} (#{e.source})"

  defp setting_line(e), do: "  #{e.label}: #{e.value} (#{e.source})"

  @doc """
  Runs the editor for one settings row from the `{:settings_edit, key}`
  intent the Alt+s overlay's `Enter` produces (`Sprat.Terminal.Zones.Settings`)
  — the same blocking-numbered-prompt pattern `Sprat.Mission.pick_model/2`
  already uses, so it must run in its own `Task` (never inline in
  `Sprat.Session.Shell`'s loop, which is the very process that has to stay
  free to deliver the prompt's answer back).
  """
  def edit_setting(session_id, store, "model"),
    do: Sprat.Mission.pick_model(session_id, store: store)

  def edit_setting(session_id, store, key) do
    session = Sessions.get(store, session_id)

    Task.start(fn ->
      case editor_spec(key) do
        {label, options, parse} -> run_edit(session_id, session, key, label, options, parse)
        nil -> system(session_id, ["Unknown setting: #{key}."])
      end
    end)

    :ok
  end

  defp editor_spec("budget_usd"),
    do: {"Budget cap", ~w(5.00 10.00 15.00 25.00 50.00), &Decimal.new/1}

  defp editor_spec("warn_percent"),
    do: {"Warn percentage", ~w(50 60 70 80 90), &String.to_integer/1}

  defp editor_spec("permission_mode"),
    do: {"Permission mode default", ~w(normal auto plan), & &1}

  defp editor_spec("research_depth"),
    do: {"Research depth default", ~w(quick standard deep), & &1}

  defp editor_spec("color_mode"), do: {"Colour / ASCII", ~w(auto color ascii), & &1}

  defp editor_spec("notify_bell"),
    do: {"Terminal bell on pause/finish", ~w(on off), &(&1 == "on")}

  defp editor_spec("notify_desktop"),
    do: {"Desktop notification on pause/finish", ~w(on off), &(&1 == "on")}

  defp editor_spec(_), do: nil

  defp run_edit(session_id, session, key, label, options, parse) do
    prompt = %{
      title: "Set #{label}",
      lines: ["Pick a value:"],
      options: options,
      selected: 0
    }

    case Session.await_permission(session_id, prompt) do
      {:ok, n} when n < length(options) ->
        choice = Enum.at(options, n)
        apply_edit(session_id, session, key, label, choice, parse.(choice))

      _ ->
        system(session_id, ["#{label} unchanged."])
    end
  end

  defp apply_edit(session_id, session, key, label, choice, value) do
    case Config.put_project(session.project_path, key, value) do
      :ok ->
        system(session_id, ["#{label} set to #{choice}."])

      {:error, :exceeds_user_cap} ->
        system(session_id, [
          "#{label} not changed: #{choice} exceeds the user-level budget cap " <>
            "(project config can narrow it, never raise it — docs/spec-v1.md §13)."
        ])

      {:error, reason} ->
        system(session_id, ["#{label} not changed: #{inspect(reason)}."])
    end
  end

  # -- /debug (docs/spec-v1.md §11, this build's addition — Requests/Tools/
  # Events/Costs/Logs) — the same data the Alt+d overlay shows, dumped to
  # the transcript, reusing `Sprat.Debug`/`Sprat.Store.Usage.totals/1`. ----

  defp debug(session_id, store) do
    case Missions.by_session(store, session_id) do
      [] ->
        system(session_id, [
          "No missions yet in this session — nothing to debug. Alt+d still shows Logs."
        ])

      missions ->
        lines = Enum.flat_map(missions, &mission_debug_lines(store, &1))
        system(session_id, ["Debug:" | lines])
    end
  end

  defp mission_debug_lines(store, mission) do
    tasks = Tasks.by_mission(store, mission.id)
    costs = Sprat.Debug.costs(store, mission.id, tasks)
    requests = Sprat.Debug.requests(store, mission.id)
    tools = Sprat.Debug.tool_calls(store, tasks)

    [
      "",
      "#{mission.objective}:",
      "  requests: #{length(requests)}  tool calls: #{length(tools)}",
      "  cost: #{cost_word(costs.mission_totals.cost)} (#{costs.unknown_or_estimated} estimated/unavailable, pricing #{costs.pricing_version || "unknown"})"
    ]
  end

  defp cost_word(nil), do: "unknown"
  defp cost_word(%Decimal{} = d), do: "$#{Decimal.round(d, 4)}"

  # `Sprat.Export` is the DB-touching bundle writer (README/brief/
  # validation-plan/research/sources/usage.csv+md/events.jsonl/
  # artifacts.json, docs/spec-v1.md §19); this command is just its TUI
  # entry point plus the transcript.md side-file `Export` doesn't own.
  defp export(session_id, store, arg) do
    base = if arg == "", do: "sprat-export", else: arg

    case Export.run(store, session_id, base) do
      {:ok, dir} ->
        File.write!(
          Path.join(dir, "transcript.md"),
          session_id |> Session.snapshot() |> Map.fetch!(:blocks) |> transcript_markdown()
        )

        system(session_id, ["Exported to #{dir}/ (README.md is the place to start)."])

      {:error, message} ->
        system(session_id, [message])
    end
  end

  defp transcript_markdown(blocks), do: blocks |> Enum.map(&block_markdown/1) |> Enum.join("\n\n")

  defp block_markdown(%{kind: :user_message, text: text}), do: "**User:** #{text}"

  defp block_markdown(%{kind: :agent_message, role: role, markdown: md}),
    do: "**#{role}:**\n\n#{md}"

  defp block_markdown(%{kind: :system, text: text}), do: "_#{text}_"
  defp block_markdown(%{kind: :tool_call, role: role, summary: s}), do: "**#{role}** `#{s}`"
  defp block_markdown(%{kind: :tool_result, text: text}), do: "> #{text}"

  defp block_markdown(%{kind: :stage_change, name: name} = b),
    do: "### Stage: #{name}#{reason_suffix(Map.get(b, :reason))}"

  defp block_markdown(%{kind: :artifact_written, role: role, artifact: a, version: v, path: p}),
    do: "**#{role}** wrote `#{a}` v#{v} (`#{p}`)"

  defp block_markdown(%{kind: :error, message: m} = b),
    do: "**Error:** #{m}#{reason_suffix(Map.get(b, :suggestion))}"

  defp block_markdown(%{kind: :gate_result} = b) do
    if Map.fetch!(b, :ok?),
      do: "Gate: passed",
      else: "Gate: failed — #{Map.get(b, :detail)}"
  end

  defp reason_suffix(nil), do: ""
  defp reason_suffix(text), do: " — #{text}"
end
