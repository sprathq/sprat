defmodule Sprat.WiringTest do
  @moduledoc """
  Guards against the defect class the `unwired-sweep` report was written
  for: a public function that is implemented and unit-tested, but has no
  caller anywhere in `lib/` — so a whole feature (a resumption path, a
  scoring rule, a state transition, a de-dup check, a doctor warning) is
  silently unreachable from anything a user does, and 700+ passing unit
  tests never notice because each one only proves the *unit* works, never
  that anything *calls* it.

  Runs Erlang's `:xref` `exports_not_used` analysis (the same tool the
  sweep used) against this build's compiled `.beam` files, then narrows
  its raw output down before failing on what's left:

    1. Drops compiler-generated code (`__info__/1`, `__struct__/0,1`),
       OTP behaviour callback names (`GenServer`/`Supervisor`), and
       anything defined under `test/support` (compiled into the `:test`
       env build alongside `lib/`, but not part of the shipped app) —
       all dispatched by the framework or by tests, never by a direct
       call `:xref` can see.
    2. Drops any candidate whose `{Module, function}` pair has *another*
       arity that *is* used elsewhere — the common case is a default
       argument (`def f(x, opts \\\\ [])`) generating two exports where
       only one is ever called explicitly. That's noise, not the bug
       this guard hunts for.
    3. Drops whole modules that dispatch dynamically by a stored module
       reference (`mod.render(...)`, `tool_mod.call(...)`) — `:xref`
       cannot follow a call through a variable, so every implementation
       of `Sprat.Agent.Tool`, `Sprat.Terminal.Zone` or `Sprat.Model`
       looks unused no matter how often the real code calls it.
    4. Drops `Sprat.Terminal.*` entirely — see "Why Terminal is out of
       scope" below.
    5. Drops an explicit, individually-commented allowlist for the
       remaining handful of real, judgment-call exceptions found during
       the sweep (a deliberately-unfinished feature, or a small leftover
       convenience function not worth its own deletion PR).

  Anything left after all five is either dead code that should be
  deleted, or — the case this guard exists for — real dead wiring: fix
  the caller, don't add it here.

  ## Why `Sprat.Terminal.*` is out of scope

  The sweep found ~150 more `exports_not_used` hits under
  `Sprat.Terminal.*`, and manually checking a sample showed most are
  false positives of a kind this guard's other rules don't fully catch:
  several rendering backends (`Renderer` for `--inline`, `ZonedRenderer`
  for the default zoned UI, `Plain` for `--plain`) define same-named
  client functions (`commit/2`, `content_width/1`, `snapshot/1`...) for
  the same GenServer message protocol, called through a module alias
  chosen at runtime — `:xref` sees each backend's copy as a separate,
  mostly-uncalled export. Untangling real dead wiring there from
  intentional per-backend duplication needs a dedicated pass (per the
  sweep report), not a guess baked into this guard. Excluding the
  subtree entirely is more honest than an allowlist long enough to hide
  a real regression in the noise. Follow-up: do that pass, then replace
  this exclusion with real triage.

  False negative this guard (all of it, not just the Terminal exclusion)
  cannot catch: a function called only through `apply/3`, a captured
  closure stored in state (like `budget_mod:`/`model_mod:` opts), a
  string-built module name, or only from a Mix task under
  `lib/mix/tasks/` calling into `lib/sprat/` (xref sees the call fine —
  Mix tasks compile into the same app — but a function called *only*
  from a Mix task, never from `lib/sprat/` itself, is legitimate and
  needs its own allowlist entry, not a blind spot; none found in the
  sweep). See the sweep report's "blind spots" section for the full list.
  """
  use ExUnit.Case, async: false

  # :xref isn't a compile-time dependency (it's on the `tools` app, added
  # to the code path at runtime by ensure_xref_available!/0 below) — this
  # just quiets the resulting "undefined module" compiler warnings.
  @compile {:no_warn_undefined, :xref}

  # Covers both layouts seen in the wild: `<root>/lib/tools-*/ebin`
  # (asdf/kerl-built Erlang) and `<root>/lib/erlang/lib/tools-*/ebin`
  # (some distro packages nest an extra `lib/erlang`).
  @tools_ebin_globs ["/lib/tools-*/ebin", "/lib/erlang/lib/tools-*/ebin"]

  # -- allowlist --------------------------------------------------------
  #
  # {Module, function, arity, reason}. Keep reasons specific enough that
  # a reviewer can tell, without re-running the sweep, whether an entry
  # is still true. Every one of these was individually read and
  # confirmed during the sweep, not assumed.
  @allowed [
    # -- framework entry points, not called by our own code -----------
    {Sprat.Application, :start, 2, "Application behaviour callback, invoked by the VM"},
    {Sprat.Application, :stop, 1, "Application behaviour callback, invoked by the VM"},
    {Sprat.CLI, :main, 1,
     "release/escript entry point, invoked as `bin/sprat eval \"Sprat.CLI.main(...)\"` (see mix.exs)"},
    {Sprat.LogHandler, :log, 2,
     ":logger handler callback, invoked by :logger after LogHandler.install/1 registers it"},
    {Sprat, :hello, 0, "mix new placeholder, harmless, not worth a separate deletion PR"},
    {Sprat.Activity, :subscribe, 0,
     "spec-v5 step 4: the board subscribes to the activity stream once it talks to the daemon over distribution"},

    # -- invoked only from a Mix task (lib/mix/tasks/), a legitimate
    #    entry point outside lib/sprat/ itself ------------------------
    {Sprat.Demo, :run_story, 0,
     "spawned from Demo.run/run_zones (both Mix.Tasks.Sprat.Demo entry points), not exported for outside use"},

    # -- ahead of its time: built, tested, correct, not yet reached ---
    # Multi-candidate weight-sensitivity (spec §6: "reports whether ±5-point
    # weight changes alter the top pick") needs several scored opportunity
    # candidates to compare; the current Opportunity workflow only ever
    # produces one opportunity_scorecard artifact per mission. Wiring this
    # in means deciding how multiple candidates get proposed and scored
    # first — out of scope for a wiring sweep. See report.
    {Sprat.Workflow.Scorecard, :sensitivity, 1, "ahead of its time — see sweep report"},
    {Sprat.Workflow.Scorecard, :sensitivity, 2, "ahead of its time — see sweep report"},

    # -- build-phase Inspector tabs (docs/spec-v2.md §11 Diff/Runs): the
    #    Inspector/Detail zones this task built render whatever a
    #    {runs:, diffs:} view model hands them, but composing that view
    #    model from a live mission — calling these after a worktree exists
    #    — is `Sprat.Orchestrator`'s job (`broadcast_inspector/3`), which
    #    is explicitly out of scope here: a concurrent task owns
    #    orchestrator.ex/workflow/ on the v2-stages branch. Exercised by
    #    the pure zone tests and the tmux check directly (both call these
    #    the same way the real wiring eventually will) — genuinely
    #    unwired, not untested.
    {Sprat.Workspace, :diff, 1,
     "not yet wired into Sprat.Orchestrator — see task boundary above"},
    {Sprat.Workspace, :diff, 2,
     "not yet wired into Sprat.Orchestrator — see task boundary above"},
    {Sprat.Workspace, :combine_diffs, 1,
     "not yet wired into Sprat.Orchestrator — see task boundary above"},
    {Sprat.Store.Runs, :by_mission_with_output, 1,
     "not yet wired into Sprat.Orchestrator — see task boundary above"},
    {Sprat.Store.Runs, :by_mission_with_output, 2,
     "not yet wired into Sprat.Orchestrator — see task boundary above"},

    # -- V4 observer store (docs/spec-v4.md §11): its typed API is built and
    #    tested on the v4-logic branch ahead of the daemon and TUI (Phase B),
    #    which are its callers and land on their own branches. Remove these
    #    entries as each call site is wired. ---------------------------------
    {Sprat.Observer.Store, :dismiss_reason, 2,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :get_offset, 2,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :list_events, 1,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :list_events, 2,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :list_nudges, 1,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :put_offset, 4,
     "V4 store API, caller lands with the Phase B daemon/TUI"},
    {Sprat.Observer.Store, :schema_version, 1,
     "V4 store API, caller lands with the Phase B daemon/TUI"},

    # -- test/replay-harness-only surface (Sprat.Model.Replay's job, not
    #    a production feature — see its own moduledoc) -----------------
    {Sprat.Model.Replay, :extend, 2, "offline replay harness helper, used only by tests"},
    {Sprat.Model.Replay, :search_result, 2, "offline replay harness helper, used only by tests"},
    {Sprat.Model.Replay, :fetch_result, 2, "offline replay harness helper, used only by tests"},

    # -- dispatched dynamically via a `template_mod:` opt (like
    #    `model_mod:`/`budget_mod:`) — Sprat.Orchestrator.start/5 takes
    #    Sprat.Workflow.Idea or Sprat.Workflow.Opportunity and calls
    #    `template_mod.template(depth)`, so :xref never sees the call ---
    {Sprat.Workflow.Idea, :template, 1, "dynamic dispatch via Orchestrator's template_mod: opt"},
    {Sprat.Workflow.Opportunity, :template, 1,
     "dynamic dispatch via Orchestrator's template_mod: opt"},
    {Sprat.Workflow.Build, :template, 1, "dynamic dispatch via Orchestrator's template_mod: opt"},

    # -- Exception behaviour callback, dispatched by Exception.message/1,
    #    not by our own code -------------------------------------------
    {Sprat.Store.Migrations.SchemaTooNewError, :message, 1,
     "Exception behaviour callback (Exception.message/1 dispatches to it)"},

    # -- dead wiring found by the sweep, flagged for follow-up rather than
    #    fixed here: each needs a real design decision (what UI surfaces
    #    it, or how/when it runs), not a one-line call-site fix. See the
    #    sweep report's "flagged, not fixed" section for the full case
    #    for each. Allowlisting them here means this guard won't cry wolf
    #    on unrelated work; it does not mean they're resolved. ----------
    {Sprat.Store.Artifacts, :versions, 1, "dead wiring, flagged not fixed — see sweep report"},
    {Sprat.Store.Artifacts, :versions, 2, "dead wiring, flagged not fixed — see sweep report"},
    {Sprat.Store.Blob, :gc_orphans, 1, "dead wiring, flagged not fixed — see sweep report"},
    {Sprat.Store.Blob, :gc_orphans, 2, "dead wiring, flagged not fixed — see sweep report"},
    {Sprat.Store.Projection, :task_usage_totals, 1,
     "dead wiring, flagged not fixed — see sweep report"},
    {Sprat.Store.Projection, :task_usage_totals, 2,
     "dead wiring, flagged not fixed — see sweep report"},

    # -- genuinely dead: small, harmless, not worth their own deletion PR
    {Sprat.Session.PubSub, :registry_name, 0,
     "genuinely dead — Sprat.Application hardcodes the same atom literal instead of calling this"},
    {Sprat.Session.Block, :kinds, 0,
     "genuinely dead — encode/1 checks its own @kinds attribute directly"},
    {Sprat.Store.Tasks, :running, 0, "genuinely dead — see running/1's own reason below"},
    {Sprat.Store.Tasks, :running, 1,
     "genuinely dead on purpose: Sprat.Store.Recovery deliberately uses running_for_session/2 " <>
       "instead, after this unscoped scan once interrupted a live task in a different session"},
    {Sprat.Terminal.Zone, :ignore_view_update, 2,
     "genuinely dead — every zone with an optional handle_view_update/2 implements its own " <>
       "clause instead of delegating here (Zones.Detail duplicates the same no-op by hand); " <>
       "listed explicitly since Sprat.Terminal.Zone itself is the behaviour, not a Zones.* impl"},
    {Sprat.Workflow.Template, :find_stage, 2,
     "genuinely dead — Template.stage_after/2 and first_stage/1 don't use it, and nothing else does"},
    {Sprat.Workflow.ArtifactSchema, :types, 0, "genuinely dead — no caller reads the type list"},
    {Sprat.Store.Sources, :find_by_canonical_url, 2, "public query API, exercised only by tests"},
    {Sprat.Store.Sources, :find_by_canonical_url, 3, "public query API, exercised only by tests"},
    {Sprat.Store.Missions, :get, 1, "public query API, exercised only by tests"},
    {Sprat.Store.Missions, :get, 2, "public query API, exercised only by tests"},
    {Sprat.Store.MissionState, :states, 0, "genuinely dead — no caller reads the state list"},
    {Sprat.Store.TaskState, :states, 0, "genuinely dead — no caller reads the state list"},
    {Sprat.Store.Events, :by_time_range, 2, "genuinely dead — no caller queries by time range"},
    {Sprat.Store.Events, :by_time_range, 3, "genuinely dead — no caller queries by time range"},
    {Sprat.Store.Events, :by_time_range, 4, "genuinely dead — no caller queries by time range"},
    {Sprat.Store.Grants, :approved?, 4,
     "genuinely dead — Orchestrator.granted_fetches/2 bulk-loads Grants.by_session/1 into " <>
       "MapSets instead of calling this per-check; same exact-match semantics, just inlined"},
    {Sprat.Store.Grants, :approved?, 5, "genuinely dead — see approved?/4's reason"},
    {Sprat.Store.Projection, :rerender_transcript, 1,
     "genuinely dead — superseded by Sprat.Session's own replay_blocks/2 + Sprat.Session.Render; " <>
       "resume/replay works fully without this, or the session_transcript/1,2 it delegates to"},
    {Sprat.Store.Projection, :rerender_transcript, 2,
     "genuinely dead — see rerender_transcript/1's reason"},
    {Sprat.Config, :color_mode_user, 0,
     "genuinely dead — Config.effective/1 reads load_user() as a raw map instead of calling this"},
    {Sprat.Config, :model_user, 0, "genuinely dead — see color_mode_user/0's reason"},
    {Sprat.Config, :permission_mode_user, 0, "genuinely dead — see color_mode_user/0's reason"},
    {Sprat.Config, :research_depth_user, 0, "genuinely dead — see color_mode_user/0's reason"},
    {Sprat.Config, :warn_percent_user, 0, "genuinely dead — see color_mode_user/0's reason"},
    {Sprat.Secrets, :login, 1,
     "implemented (writes to the OS credential store) but no `sprat auth login` CLI subcommand " <>
       "exists to call it yet, and it has no unit test either — see sweep report"},

    # -- V2 build-phase foundation (docs/spec-v2.md §7/§10): storage/query
    #    API and explicit-only operations with no orchestrator wired up
    #    yet — the orchestrator that runs build tasks end-to-end is later
    #    Phase A work, not this layer. Exercised directly by tests.
    {Sprat.Store.Runs, :by_mission, 1, "public query API, exercised only by tests"},
    {Sprat.Store.Runs, :by_mission, 2, "public query API, exercised only by tests"},
    {Sprat.Store.Runs, :by_task, 1, "public query API, exercised only by tests"},
    {Sprat.Store.Runs, :by_task, 2, "public query API, exercised only by tests"},
    {Sprat.Store.Runs, :sandbox_strengths, 0,
     "genuinely dead — record/2 checks its own @sandbox_strengths attribute directly"},
    {Sprat.Workspace, :cleanup, 1,
     "explicit-only by design (§7: cleanup is never automatic) — no caller until a build " <>
       "orchestrator decides a retention policy"},
    {Sprat.Workspace, :cleanup, 2, "explicit-only by design — see cleanup/1's reason"}
  ]

  # function-name patterns dispatched by OTP itself, never by our code
  @otp_callback_names ~w(child_spec code_change handle_call handle_cast handle_continue
                         handle_info init start_link terminate)a

  test "every Sprat.* public function has a non-test caller, a documented dynamic-dispatch reason, or an explicit allowlist entry" do
    ensure_xref_available!()

    {:ok, pid} = :xref.start(:sprat_wiring_xref)
    :xref.set_default(pid, warnings: false)
    :xref.add_directory(pid, String.to_charlist(Mix.Project.compile_path()))
    {:ok, unused} = :xref.analyze(pid, :exports_not_used)
    :xref.stop(pid)

    sprat_unused = Enum.filter(unused, &sprat_module?/1)
    sprat_exports = Enum.filter(all_beam_exports(), &sprat_module?/1)
    used_mod_funs = used_mod_fun_pairs(sprat_exports, sprat_unused)

    flagged =
      sprat_unused
      |> Enum.reject(&compiler_generated?/1)
      |> Enum.reject(&otp_callback?/1)
      |> Enum.reject(&test_support_module?/1)
      |> Enum.reject(&terminal_module?/1)
      |> Enum.reject(&dynamic_dispatch_module?/1)
      |> Enum.reject(&sibling_arity_used?(&1, used_mod_funs))
      |> Enum.reject(&called_locally_within_own_module?/1)
      |> Enum.reject(&allowlisted?/1)

    if flagged != [] do
      lines =
        flagged
        |> Enum.sort()
        |> Enum.map(fn {mod, fun, arity} -> "  #{inspect(mod)}.#{fun}/#{arity}" end)

      flunk("""
      Found #{length(flagged)} public function(s) with no caller anywhere in lib/:

      #{Enum.join(lines, "\n")}

      This is the "implemented, tested, never wired in" defect class (see the
      unwired-sweep report). For each one, either:

        * wire it into the real call path that should use it, or
        * delete it if nothing needs it, or
        * add it to @allowed in test/sprat/wiring_test.exs with a one-line
          reason, if it's a deliberate not-yet-wired feature or dynamic
          dispatch this guard can't see.
      """)
    end
  end

  defp sprat_module?({mod, _fun, _arity}),
    do: mod |> Atom.to_string() |> String.starts_with?("Elixir.Sprat")

  # Every `.beam` file's own export table, read directly (not via
  # `:code.all_loaded/0`, which only lists modules something has already
  # triggered the loading of — incomplete this early in a test run).
  defp all_beam_exports do
    Mix.Project.compile_path()
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn beam_path ->
      case :beam_lib.chunks(String.to_charlist(beam_path), [:exports]) do
        {:ok, {mod, [exports: exports]}} ->
          Enum.map(exports, fn {fun, arity} -> {mod, fun, arity} end)

        _ ->
          []
      end
    end)
  end

  # Every export xref calls "used" is just every export minus the unused
  # ones.
  defp used_mod_fun_pairs(sprat_exports, sprat_unused) do
    unused_set = MapSet.new(sprat_unused)

    for {mod, fun, _arity} = mfa <- sprat_exports,
        mfa not in unused_set,
        into: MapSet.new(),
        do: {mod, fun}
  end

  defp sibling_arity_used?({mod, fun, _arity}, used_mod_funs),
    do: {mod, fun} in used_mod_funs

  defp compiler_generated?({_mod, :__info__, 1}), do: true
  defp compiler_generated?({_mod, :__struct__, 0}), do: true
  defp compiler_generated?({_mod, :__struct__, 1}), do: true
  defp compiler_generated?(_), do: false

  defp otp_callback?({_mod, fun, _arity}), do: fun in @otp_callback_names

  # `MIX_ENV=test`'s elixirc_paths adds `test/support` alongside `lib` —
  # real support modules (Sprat.StubModel, test helpers) compile into
  # this same directory and show up in the same xref server, but they
  # are never part of the shipped app and are exercised only by tests by
  # design, not by a wiring bug.
  defp test_support_module?({mod, _fun, _arity}) do
    case mod.module_info(:compile)[:source] do
      nil -> false
      source -> source |> List.to_string() |> String.contains?("test/support")
    end
  end

  defp terminal_module?({mod, _fun, _arity}),
    do: mod |> Atom.to_string() |> String.starts_with?("Elixir.Sprat.Terminal.")

  # Behaviours dispatched by a stored module reference at runtime
  # (`mod.render(...)`, `tool_mod.call(...)`, `model_mod.stream(...)`) —
  # :xref only sees direct `Module.function(...)` calls, so every
  # implementation of these behaviours looks unused no matter how often
  # the real code calls it. See Sprat.Agent.Loop.find_tool/2 +
  # tool_specs/1, Sprat.Terminal.ZonedRenderer's `mod.render/handle_key`
  # (excluded wholesale above, but its Zones.* modules would hit this
  # rule too), and every `model_mod:` opt.
  @dynamic_dispatch_prefixes [
    "Elixir.Sprat.Agent.Tools.",
    "Elixir.Sprat.Model."
  ]

  defp dynamic_dispatch_module?({mod, _fun, _arity}) do
    name = Atom.to_string(mod)
    Enum.any?(@dynamic_dispatch_prefixes, &String.starts_with?(name, &1))
  end

  # `:exports_not_used` means exactly what it says — *exported* and not
  # called from *outside* its defining module — so a function called
  # only by a sibling function in the same module (the common
  # `record/2` calling `record_in_conn/2`, or `put_project/3`
  # dispatching to `put_search_provider/2`, pattern this codebase uses
  # throughout the Store layer and Config) still reads as "unused" to
  # xref even though it has a real, working caller. A plain grep of the
  # function's own source file for a call to itself (excluding its own
  # `def`/`defp` line and comments) catches exactly this case without
  # a per-function allowlist entry.
  defp called_locally_within_own_module?({mod, fun, _arity}) do
    with source when not is_nil(source) <- mod.module_info(:compile)[:source],
         path = List.to_string(source),
         true <- File.exists?(path) do
      fun_str = Atom.to_string(fun)
      def_pattern = ~r/^\s*def(p)?\s+#{Regex.escape(fun_str)}[\(\s]/

      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.any?(fn line ->
        String.contains?(line, fun_str <> "(") and
          not Regex.match?(def_pattern, line) and
          not (String.trim_leading(line) |> String.starts_with?("#"))
      end)
    else
      _ -> false
    end
  end

  defp allowlisted?({mod, fun, arity}) do
    Enum.any?(@allowed, fn {amod, afun, aarity, _reason} ->
      amod == mod and afun == fun and aarity == arity
    end)
  end

  defp ensure_xref_available!() do
    case :code.which(:xref) do
      :non_existing ->
        root = :code.root_dir() |> to_string()

        tools_ebin =
          @tools_ebin_globs
          |> Enum.flat_map(&Path.wildcard(root <> &1))
          |> List.first()

        if is_nil(tools_ebin) do
          flunk("""
          Erlang's `tools` application (which ships `:xref`) was not found under
          #{root}. This guard depends on it — install a standard Erlang/OTP
          distribution, or extend @tools_ebin_globs in this file for your layout.
          """)
        end

        true = :code.add_path(String.to_charlist(tools_ebin))

      _ ->
        :ok
    end
  end
end
