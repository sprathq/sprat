# Sprat V3 — Supervisor Specification

Version: 3.0-draft
Prepared: 30 October 2026
Parent documents: `spec-v1.md` (what exists), `spec-v2.md` (the build phase, partly built), `spec-full.md` (long-term target)
Status: proposal, not started. **Partly superseded by `spec-v4.md`** (23 Nov 2026): V4 builds the observer/PM first; V3's goals, checks and Stop gate become V4 Phase D (Verify)
Verified against: Claude Code 2.1.314 and its hooks, headless and Agent SDK references (links in §6)

## 1. What V3 is for

V1 answers *what should I build, and on what evidence*. V2 set out to build it. Both assume
Sprat is the agent doing the work.

V3 changes the subject. The work is already being done — in Claude Code sessions, one or
several at a time, in different projects, by a person who starts them, steers them for a
while and then looks away. What nobody is doing is holding each of those sessions to its
goal: checking that the tests were actually run, that the coverage did not quietly fall,
that the screen it changed was looked at, that the thing it says is done is done.

V3 makes Sprat that someone. **Sprat is the product manager for your coding agent.** It
knows the goal of every session, measures the distance to it with evidence the code
collected, and intervenes — a nudge, a steer, a refusal to let the session end — when the
session drifts or claims completion early. The person stays the CEO. Sprat reports to them.

And a CEO has more than one thing being built. The person Sprat serves runs several
projects at once, each with its own outcome, each moving through many Claude Code sessions
over days and weeks, and cannot be in all of them. So Sprat watches the **portfolio**: every
project, its goal, its backlog of session goals, which sessions are live, which project
needs a human now, and what it all cost today. One Sprat, one screen, the whole company.

Product promise: **Every project has a goal. Every session serves one. Sprat keeps them all
honest about how close they are.**

### The bet V3 tests

> A coding agent supervised by a separate process that holds the goal, runs the checks
> itself and refuses unverified completion produces better results, at a defensible cost,
> than the same agent given the same goal in a CLAUDE.md and left to its own judgement.

If that is false — if a well-written CLAUDE.md and a Stop hook that runs `mix test` get the
same outcome — V3 is a settings generator and nothing more. §16 makes that a real gate.

### What this resolves from V2

V2 §16 asked *native or delegated first?* and §14 allowed for the finding that "Sprat should
orchestrate and delegate rather than implement". V3 takes that answer without running the
eval: implementation is delegated to Claude Code, always. The native write and shell tools
stay, because Sprat still runs checks itself, but Sprat never writes application code.

## 2. What V3 is not

- **Not a coding agent.** It does not write the feature. It decides whether the feature is
  done, and says what is missing when it is not.
- **Not a prompt.** The value is in what the code enforces: checks it runs, evidence it
  stores, a stop it can refuse. Advice to the model is the weakest tool it has and is
  used last.
- **Not a nag.** An intervention is rationed, has a cost, and never repeats a reason
  without new evidence (§10). A supervisor the user switches off has failed.
- **Not a cloud control plane.** Local, one user, one machine. The sessions it watches are
  on that machine. V1's hard boundaries hold.
- **Not autonomous judgement over scope.** Sprat measures distance to the goal the user
  wrote. It proposes criteria; it never adds scope on its own.

## 3. What changes from V2

| Area | V2 | V3 |
|---|---|---|
| Who writes code | Sprat's SWE role, natively | Claude Code, always; Sprat delegates |
| Unit of work | a mission that builds an MVP | a **goal** attached to a Claude Code session |
| Roles | PM, Researcher, Analyst, SWE, Reviewer | PM, Reviewer, Analyst; SWE is gone; the **user is the CEO** |
| Gates | between build stages | **checks** against the goal's criteria, run continuously and at Stop |
| Tools | write_file, shell, git in a worktree | shell and read tools for running checks; `claude -p` as a tool; hooks as a sensor |
| Workspace | a worktree per task Sprat creates | in Observe mode, the user's own session and checkout; in Drive mode, a worktree per task as before |
| Scope | one mission at a time per project | a **portfolio**: many projects, each with a goal and a backlog, each with many sessions over time; one Sprat |
| Lifetime | a mission ends when its stages do | a project goal lives for weeks; session goals are its steps; Sprat runs all day as a daemon |
| What the user sees | a build mission's stages | a **scorecard** per session, a **project** view with its backlog, and a **portfolio board** with a daily brief |

Reused unchanged: the orchestrator, gates, artifacts, budget, evidence store, event log,
runs, steering, worktrees, the TUI zones. The v2-implement and v2-review branches become
Drive mode and the Reviewer check respectively (§17).

## 4. Vocabulary

| Term | Meaning |
|---|---|
| **Portfolio** | Every project Sprat watches for one user on one machine. The top of the hierarchy: portfolio → project → project goal → session goals → sessions. |
| **Project** | A repository Sprat is attached to, with one open **project goal** (the outcome the CEO wants, in weeks), a **backlog** of session goals ordered by priority, and a history of done ones. |
| **Goal** | The artifact that says what a session is for: objective, success criteria, boundaries, ceiling. A **session goal** is one step toward the project goal; one session serves one session goal at a time. |
| **Criterion** | One line of the goal that can be judged met, unmet, partial or unknown, each with a named **check** and the evidence it produced. |
| **Check** | Something Sprat runs itself to judge a criterion: a test command, a coverage threshold, a lint, a health check, a driven UI pass, a reviewer, a skill review, or a human. Produces a run record and findings. |
| **Scorecard** | The computed state of every criterion right now, with evidence age. Code computes it; a model judges only the items that need judgement, and only with evidence in hand. |
| **Session** | A Claude Code session Sprat is attached to, in Observe or Drive mode. |
| **Intervention** | Something Sprat does to the session: inform, steer, block or escalate (§10). Every one is recorded with its reason and what it cost. |
| **Ceiling** | Limits the session cannot raise: money, wall time, interventions, blocked stops, write scope, network. |

## 5. The goal

A goal is written once, at attach time, in a short conversation with the PM role, and
edited at will afterwards. It is an artifact like any other: versioned, schema-validated,
exportable, marked stale by steering.

```json
{
  "id": "g_01HZ…",
  "project": "/Users/owner/Projects/liftlog",
  "objective": "Members can book a class from the mobile web app and get a confirmation email.",
  "criteria": [
    {"id": "c1", "text": "Booking flow works end to end on a phone-width screen",
     "check": {"type": "driven_ui", "flow": "book-a-class", "viewport": "390x844"}},
    {"id": "c2", "text": "Unit and integration tests pass",
     "check": {"type": "test", "command": "mix test"}},
    {"id": "c3", "text": "Line coverage on lib/liftlog/bookings does not fall below 85%",
     "check": {"type": "coverage", "command": "mix test --cover", "path": "lib/liftlog/bookings", "min": 85}},
    {"id": "c4", "text": "No compiler warnings, formatted",
     "check": {"type": "lint", "commands": ["mix compile --warnings-as-errors", "mix format --check-formatted"]}},
    {"id": "c5", "text": "The booking screen passes a UX audit at phone width",
     "check": {"type": "skill_review", "skill": "impeccable", "command": "audit", "targets": ["lib/liftlog_web/live/booking_live.ex"]}},
    {"id": "c6", "text": "A reviewer who did not write it finds no blocker",
     "check": {"type": "reviewer", "severity_max": "major"}},
    {"id": "c7", "text": "Confirmation email copy reads well and names the class, time and venue",
     "check": {"type": "human"}}
  ],
  "out_of_scope": ["Payments", "Waitlists", "Native apps"],
  "constraints": ["Phoenix LiveView only; no new JS framework", "Postgres, not SQLite"],
  "ceiling": {"supervision_usd": 3.00, "wall_minutes": 180, "blocked_stops": 4, "interventions": 12},
  "checkpoints": {"on_block": "auto", "on_done": "ask"}
}
```

Rules:

- **Every criterion has a check, or is marked `human`.** A criterion nobody can check is a
  wish, and the schema rejects it. `human` criteria are shown as unknown until the user
  marks them, and a goal is never reported done while one is unknown.
- **The objective is one sentence in the user's words.** The PM may propose a sharper one
  and must show the diff.
- **Criteria are proposed, not imposed.** At intake the PM proposes criteria from the
  objective, the project's stack profile (§8) and the project's own conventions (CLAUDE.md,
  existing test and lint commands it found). The user accepts, edits or removes each one.
  Sprat may *suggest* a missing criterion later — "nothing here checks the screen you
  changed" — as an inform, never by adding it.
- **Out of scope is enforced the same way as in scope.** Work on an excluded item is a
  finding, reported at the next safe boundary.
- **The ceiling is the user's.** The session cannot raise it. The user can, from the TUI,
  and the change is an event.

Where it lives: in the project's Sprat store, as artifact type `goal`, with a readable
export at `.sprat/goals/<id>.md` that the user can open, diff and commit if they want to.

### The project goal and the backlog

A session goal is a step. The thing the CEO actually wants is the **project goal**: an
outcome measured in weeks, written once per project in the same intake conversation, with
the same shape and one difference — its criteria are mostly **session goals**, not checks.

```json
{
  "id": "p_01HZ…",
  "project": "/Users/owner/Projects/liftlog",
  "objective": "Independent gym owners can run class bookings on Liftlog without a spreadsheet by the end of November.",
  "criteria": [
    {"id": "p1", "text": "Members can book a class and get a confirmation", "check": {"type": "session_goal", "goal": "g_01HZ…"}},
    {"id": "p2", "text": "Owners can set a weekly class schedule",            "check": {"type": "session_goal", "goal": null}},
    {"id": "p3", "text": "Capacity and cancellations are enforced",            "check": {"type": "session_goal", "goal": null}},
    {"id": "p4", "text": "The suite stays green and coverage never falls",      "check": {"type": "standing", "goal": "g_std_…"}},
    {"id": "p5", "text": "Three real gym owners have booked a class in staging","check": {"type": "human"}}
  ],
  "backlog": ["p2", "p3"],
  "ceiling": {"supervision_usd_per_day": 10.00, "sessions_concurrent": 2},
  "due": "2026-11-30"
}
```

- A `session_goal` criterion is met when the session goal it points to is `done` (not
  `released`). A criterion with `goal: null` is **backlog**: written, prioritised, not yet
  started. The PM can draft the session goal for it on request, from the project goal, the
  stack profile and what the previous session goals established.
- A `standing` criterion names a session goal that applies to **every** session in the
  project: the suite is green, no warnings, coverage floor, the UX audit on any screen
  touched. It is attached automatically to each new session alongside the session's own
  goal, so a bug-fix session is held to the same floor as a feature session. This is where
  "always use best practice" lives: not as advice, as a standing goal with checks.
- The project goal's scorecard is computed the same way (§9): met, unmet, unknown, with the
  session goals as evidence and the human criteria as the CEO's own.
- The **backlog order is the CEO's.** Sprat may suggest reordering ("p3 depends on p2") as
  an inform. When a session starts in a project with no session goal bound, Sprat offers
  the top of the backlog first.
- Per-project ceilings add a daily supervision budget and a cap on concurrent sessions
  Sprat will drive (§6). Observe-mode sessions the user opens themselves are never capped;
  Sprat does not get to decide how many terminals the CEO opens.

Where it lives: the project store, as artifact type `project_goal`, exported to
`.sprat/project.md`. The portfolio index (§6) holds only pointers and the latest scorecard
per project, so the board can be drawn without opening every store.

## 6. Attaching to a session

Two modes, same goal, same checks, same scorecard.

### Observe mode — the user's own sessions

The user keeps working in Claude Code as they do today. Sprat sees the session through
Claude Code's hooks and acts through what hooks are allowed to return. This is the default
and the first thing built, because it attaches to how the user already works and costs
nothing to try.

`sprat attach` writes hook entries into the project's `.claude/settings.json` (never the
user-level file; never silently — it shows the exact JSON and asks). Each entry runs the
thin client `sprat hook <event>`, which reads the hook's JSON from stdin, forwards it to
the running Sprat over a Unix socket, waits for the answer within the hook's budget, and
prints it. If Sprat is not running, the client **exits 0 with no output** and appends the
event to a local spool so the next Sprat start can show what it missed. A supervisor that
breaks the session when it is down is worse than none.

| Hook | What Sprat does with it | What it may return |
|---|---|---|
| `SessionStart` | Binds the session (`session_id`, `cwd`, `transcript_path`) to a goal: the open goal for that project, or offers to write one. | `hookSpecificOutput.additionalContext`: the goal card (§13.8), under 600 tokens — objective, criteria with current state, out of scope, constraints. |
| `UserPromptSubmit` | Records the prompt as steering if it changes scope; re-checks whether the goal is stale. | `additionalContext` only when the scorecard changed since the last injection, or the prompt touches an out-of-scope item. Never blocks a prompt. |
| `PostToolUse` (`Edit\|Write\|MultiEdit\|NotebookEdit\|Bash`) | Records what changed. Edits to files under a criterion's path schedule that criterion's check, debounced; a `Bash` running the test command is noted but **never trusted as evidence** — Sprat runs its own. | `additionalContext` only for an out-of-scope write or a constraint violation, once. |
| `PreToolUse` (`Bash`) | Enforces the ceiling where a hook can: deny `git push`, deploy commands and network installs the goal did not grant. | `hookSpecificOutput.permissionDecision: "deny"` with `permissionDecisionReason`. Nothing else is ever denied. |
| `SubagentStop` | Same as Stop, scoped to what the subagent was asked to do, only when a criterion names it. Default: observe only. | `decision: "block"` with reason, rarely. |
| `Stop` | **The gate.** Waits up to `stop_wait` (default 120 s) for in-flight checks, then evaluates the scorecard against the goal. | See below. |
| `SessionEnd` | Records the outcome: goal state, cost known, interventions used. Cannot block. | nothing |
| `PreCompact` | Snapshots the scorecard so the post-compaction `SessionStart (source: compact)` re-injects the goal card. | nothing |

**The Stop decision**, in order:

1. If `stop_hook_active` is true and nothing changed since Sprat's last block: allow. Sprat
   never blocks twice on the same evidence.
2. If the session was interrupted by the user: the hook does not run (Claude Code's rule).
3. If the ceiling on blocked stops is spent: allow, and escalate to the user (§10).
4. If every non-human criterion is met and no human criterion is unknown-and-required: allow,
   and mark the goal `done` pending the user's `on_done` checkpoint.
5. Otherwise block: `{"decision": "block", "reason": <the shortfall, §13.9>}`. The reason
   names each unmet criterion, the evidence (command, exit code, the failing line), and
   the single next action — never "try harder".

Claude Code ends the turn anyway after eight consecutive blocks; that is a floor Sprat
respects and reports, not something it works around. Sprat's own default is four (the
goal's `blocked_stops`), because a session that has been refused four times with specific
reasons and is still short is a session a human needs to look at.

**What Observe mode cannot know**, stated as unknown everywhere it is shown: the session's
token cost (hooks do not carry it), and the model's reasoning. It knows what tools ran,
what files changed, what the last assistant message said, and everything in the transcript
at `transcript_path`.

### Drive mode — sessions Sprat starts

For work the user hands over entirely, Sprat runs Claude Code headless, one task at a time,
in a worktree pinned to a base revision — the Implement stage from v2-implement with the
model turn replaced by a subprocess:

```text
claude -p "<task from the goal or task graph>" \
  --output-format stream-json \
  --permission-mode auto --permission-prompts none \
  --max-turns 40 --max-budget-usd 2.00 \
  --allowedTools "Read,Edit,Write,Glob,Grep,Bash(mix *),Bash(git add *),Bash(git commit *)" \
  --append-system-prompt-file <goal card> \
  --settings <sprat-generated settings with the same hooks as Observe mode>
```

Sprat consumes the event stream (`system/init` for the session id; `assistant` and `user`
for the transcript; `result` for `subtype`, `num_turns`, `total_cost_usd`,
`permission_denials`) and records it as events. A result of `success` is an **input, not
evidence**: the checks run after it, exactly as in Observe mode. `--resume <session_id>`
carries a task's follow-up into the same session so the fix has the context of the attempt.

Drive mode is Phase C (§15). Observe mode is the product's spine and ships first.

### Many projects, all day

One Sprat per machine supervises every attached project. Because projects run for weeks and
sessions come and go, Sprat is **a daemon, not a window**: `sprat serve` starts on login
(a launchd agent on macOS, a systemd user unit on Linux, written by `sprat attach` with
consent), owns the Unix socket the hook client talks to, runs the check scheduler, and
holds the portfolio index. The TUI (`sprat`) attaches to the daemon and can be closed
without anything stopping. This resolves V3's first open question (§19) in favour of the
daemon, because a supervisor that only works while its window is open cannot watch a
portfolio.

Binding, in order, on every `SessionStart`:

1. The project is the hook's `cwd` resolved to its repository root; a worktree resolves to
   the repository it belongs to, with the branch recorded.
2. A session goal already bound to this branch and still open rebinds (this is `--resume`,
   `/clear`, a crash, or tomorrow morning).
3. Otherwise, if the project has a backlog, Sprat's goal card offers the top item and the
   TUI asks the user to confirm or pick another; until they do, only the project's
   `standing` goal applies and the session is shown as **unassigned**.
4. Otherwise, only the standing goal applies, and the project row shows `no backlog`.

Two sessions in one checkout on the same branch share one session goal and one scorecard;
checks still never run concurrently in the same checkout, and the rail shows both
sessions under the goal. Parallel work on different goals uses worktrees, which bind
separately by branch.

Sprat's per-project stores stay exactly as they are. A small user-level index at
`~/.local/state/sprat/portfolio.sqlite` lists projects, their latest project scorecard,
open session goals, live sessions, today's supervision spend and the last time a human
touched each project — everything the board (§13.3) and the brief (§13.4) need.

## 7. Roles

| Role | In V3 | Independence |
|---|---|---|
| **PM** | Writes the goal with the user. Proposes criteria. Judges `acceptance`-type criteria in the user's terms. Writes every intervention's text. | Own context; sees evidence and the goal, never the worker's conversation except `last_assistant_message`. |
| **Reviewer** | Reads the diff and the goal; produces findings with severities. Never fixes anything. | Separate process, separate context, **a different model by default** (V2 §16 question 2, answered: Sprat's OpenAI backend reviewing Claude's work, or the reverse, is independent in a way the same model with a fresh context is not). |
| **Analyst** | Runs only when a criterion needs research or judgement outside the code — a pricing claim, a GTM assumption, a market figure — using V1's research stages and sources. | As in V1. |
| **Orchestrator** | Deterministic. Schedules checks, computes the scorecard, applies the intervention ladder, enforces the ceiling. | Not a model. |
| **The user** | The CEO. Sets the goal, answers escalations, marks human criteria, raises ceilings. | — |

There is no SWE role. The worker is Claude Code.

## 8. Checks

Every check is run by Sprat, in the project's checkout (Observe) or the task's worktree
(Drive), through the existing `Shell` tool: explicit argument array, timeout, killed
process tree, output captured to the blob store, recorded in `Runs` with command, exit
code, duration, output hash and purpose. **A check the worker ran is not a check.**

| Type | What runs | Verdict |
|---|---|---|
| `test` | the profile's test command, or the goal's | met on exit 0; the failing test names go into the reason |
| `coverage` | test command with coverage, parsed per profile | met when the named path meets `min`; the number is shown either way |
| `lint` | each listed command | met when all exit 0 |
| `build` | compile or typecheck command | met on exit 0 |
| `health` | run command, then the health check, then kill | met when the check returns within its timeout |
| `driven_ui` | the project's `test-ui` discipline: a scripted pass over the named flow at the named viewport, screenshots stored as evidence | met when the script passes; the screenshot is shown either way |
| `skill_review` | a **separate** `claude -p` in read-only mode running the named skill and command (`/impeccable audit`, `/impeccable critique`, `/seo-audit`, `/copywriting` review, `/cro`) with `--json-schema` for findings | met when no finding is at or above the goal's severity threshold; findings go to the worker as the block reason, with file and line |
| `reviewer` | the Reviewer role over the diff since the goal's base revision | met when nothing is at `blocker`, or above `severity_max` |
| `acceptance` | PM judges one criterion from the evidence of the others, in the user's terms | met / unmet / partial, with the sentence of reasoning |
| `human` | nothing | unknown until the user marks it in the TUI |
| `session_goal` | nothing runs; reads the named session goal's state | met when that goal is `done`; `released` is unmet with a reason; `null` is backlog |
| `standing` | the named standing goal's checks, in every session of the project | as the checks say; reported on the project row as "floor held" or the criterion that broke it |

Scheduling:

- Checks run **continuously, not only at Stop**: an edit under a criterion's path schedules
  that check after a debounce (default 20 s of no edits), so by the time the session wants
  to stop the evidence is usually fresh and the Stop hook has little to wait for.
- Expensive checks (`reviewer`, `skill_review`, `driven_ui`) run at Stop and on demand, and
  count against the goal's supervision budget. Cheap ones (`test`, `lint`, `build`) run on
  change.
- Two checks never run concurrently in the same checkout. A check that would run while the
  worker is mid-edit waits for the next PostToolUse quiet period.
- Evidence has an **age**. The scorecard shows it. A criterion met on evidence older than
  the last edit under its path is shown as `stale`, which is a kind of unknown.

Stack profiles from V2 §4 supply the default commands and parsers (`elixir-phoenix`,
`node-next`). A project without a profile gets whatever `sprat attach` could find —
`mix.exs`, `package.json` scripts, a Makefile — shown to the user to confirm.

## 9. The scorecard

Pure, computed by code from the latest evidence per criterion:

```text
criterion → {state: met | unmet | partial | unknown | stale | checking,
             evidence: run id or finding ids, age, last change}
goal      → {met: n, total: m, unknown: k, blocking: [criteria], done?: bool}
```

- **No percentage.** "4 of 7 met, 1 unknown" is honest; "63%" implies criteria weigh the
  same, and a skipped reviewer is not the same as a missing comma. The bar in the TUI is
  drawn from the count and labelled with it.
- **Distance is the ordered list of unmet criteria**, blocking ones first (anything the
  objective cannot be true without), then the rest in goal order.
- **Trend** is the scorecard's history: a sparkline of met-count over the session's
  lifetime, so a session going backwards is visible. A project's trend is the same over
  days, which is how the board shows a project that has stalled.
- **Needs-you** is a derived flag, per project: an escalation is open, a human criterion is
  the only thing left, a ceiling is spent, a check cannot run, or the backlog is empty with
  the project goal unmet. It is the one bit the portfolio board sorts by.
- A model judges only `acceptance` and `human`-adjacent questions, with the evidence, and
  its sentence is stored alongside the verdict. Everything else is a comparison the code
  does.

## 10. Interventions

A ladder. Each rung costs more attention and is rationed harder.

| Rung | Mechanism | When | Ration |
|---|---|---|---|
| **Inform** | `additionalContext` on SessionStart, UserPromptSubmit or PostToolUse | the scorecard changed; an out-of-scope file was touched; a constraint was crossed | once per scorecard state; never twice for the same reason without new evidence |
| **Steer** | a steering message delivered at the next safe boundary (V1 §10), in Drive mode via `--resume`; in Observe mode as `additionalContext` on the next prompt | the session is drifting: three consecutive edits outside every criterion's path; a check went from met to unmet | at most one per ten minutes per session |
| **Block** | Stop hook `decision: block` | the session is stopping short of the goal | `blocked_stops` from the ceiling, default 4; hard floor of 8 from Claude Code |
| **Escalate** | desktop notification (`Sprat.Notify`), a `?` card in the TUI, and the session is left alone | the ceiling is spent; a human criterion is the only thing left; a check cannot run; the worker's last message contradicts the evidence | always allowed; never silent |

Rules that keep it from nagging:

- **Every intervention is an event** with its rung, reason, the evidence ids it cited, and
  the model cost of writing it. `/interventions` lists them; the Inspector tab shows them.
- **Silence is the default.** A session that is on course gets nothing from Sprat between
  the goal card at start and the allow at Stop.
- **The user can release a block** with `/sprat release` in the Claude session or `r` on the
  session in the TUI. The release is recorded, the goal is marked `released`, not `done`,
  and the handover (§11) says so.
- **The user can mute a criterion** for the session (`m` on the criterion). Muted is shown,
  not hidden.
- **No intervention is ever written by the worker's own model.** PM writes it in its own
  context from the evidence.

## 11. What gets produced

| Artifact | Contents |
|---|---|
| `goal` | §5 |
| `scorecard` | §9, versioned on every change; the history is the trend |
| `run_evidence` | every check: command, exit code, duration, output hash, screenshot (V2 §8, unchanged) |
| `review_findings` | per finding: severity, file, line, what would go wrong, suggested fix, resolution (V2 §8, unchanged) |
| `skill_findings` | the parsed output of a `skill_review` check, same shape as review findings, with the skill and command that produced it |
| `interventions` | §10 |
| `handover` | written when a goal reaches `done` or `released`: what was asked, what is met with evidence, what is not and why, what was released or muted, what the user still has to check by hand, cost of supervision, cost of the session where known |

`handover.md` is the one a human reads first, exactly as in V2. Its "not verified" list is
expected to be non-empty; an empty one is a smell.

## 12. Permissions, budgets and the ceiling

- **Supervision has its own budget**, per goal, in dollars, shown separately from the
  session's own cost. Sprat's spend is the PM, the Reviewer, skill reviews and research;
  the worker's spend is Claude Code's and is shown as known (Drive) or unknown (Observe).
- **Sprat never raises a ceiling.** Only the user, in the TUI, and it is an event.
- **Sprat's deny list is short and declared**: push, publish, deploy, and network installs
  outside the goal's grants. It never denies a read, an edit inside the checkout, or a test.
- **Sprat writes nothing into the user's checkout** except `.claude/settings.json` hook
  entries (with consent, shown first) and `.sprat/goals/*.md` exports. Checks run in the
  checkout but create nothing there; coverage and screenshot output goes to Sprat's data dir.
- **Uncommitted user changes are never touched.** V2 §7's rule, restated because a check
  that runs `git stash` to get a clean tree is the kind of helpfulness that loses work.
- **Secrets** are redacted on every path: hook payloads, transcripts read for evidence,
  check output. The existing redaction module covers them.

## 13. What the user sees

Design mode: **Operate**. The user is in a task — often several — and comes to Sprat to
answer one question fast: *how far is this session from done, and is anything wrong?* The
tool should disappear into that question. Brand lives in precise details: the honest
glyphs, the evidence age, the refusal that names a line number.

### 13.1 The scene

The primary usage scene is not a full screen. It is **a narrow pane beside Claude Code** —
a tmux or cmux split, 40 to 70 columns wide, open all day, glanced at between prompts. The
full-screen portfolio board exists for the moment the user steps back to look at everything,
but the pane is where Sprat earns its keep. Every layout decision below starts from the
pane.

Consequences:

- The **rail** (< 80 cols) is a first-class breakpoint with its own composition, not the
  single-zone fallback V1 used below 80 columns.
- The goal, not the agent list, organises every screen. Criteria are the rows. Agents,
  runs and findings hang off criteria.
- Nothing animates unless state changed. A pane that flickers in the corner of the eye
  gets closed.

### 13.2 The rail

```text
╭─ liftlog · book-a-class ─────────────────────────╮
│ Members can book a class from the mobile web app │
│ and get a confirmation email.                    │
│                                                  │
│ 4 of 7 met · 1 unknown        ▰▰▰▰▱▱▱  ▁▂▃▃▅▅▅   │
│                                                  │
│ ✓ c2 tests pass              12s ago  mix test   │
│ ✓ c4 no warnings, formatted  12s ago             │
│ ✓ c3 coverage ≥85% bookings  12s ago  88.1%      │
│ ✓ c6 reviewer: no blocker     4m ago  2 minor    │
│ ✗ c1 booking flow on phone   stale    edit 2m ago│
│ ✗ c5 UX audit passes          —       not yet run│
│ ? c7 email copy reads well    —       yours      │
│                                                  │
│ ── now ──────────────────────────────────────── │
│ ⠙ Claude  editing booking_live.ex        1m 40s  │
│   ⎿ 3 edits · 1 test run (not evidence)          │
│ ⟳ Sprat   re-running c2 c3 c4 in 14s             │
│                                                  │
│ ── last ─────────────────────────────────────── │
│ ⛔ 14:02 blocked stop #1 · c1 c5 unmet           │
│    "flow fails at step 3: confirm button is      │
│     below the fold at 390px" · evidence r_41     │
│                                                  │
│ ❯ ask, /goal, /release, ? keys                   │
╰──────────────────────────────────────────────────╯
 liftlog · supervision $0.42/$3.00 · session cost: n/a
```

Reading order, top to bottom: *what* (the objective, in the user's words), *how close*
(count, bar, trend), *what exactly* (criteria, met first, then unmet in blocking order,
then unknown), *what is happening now* (worker and Sprat), *what Sprat last did* (one
card), the composer, the footer with the two costs.

Rules the rail follows:

- Each criterion row is **glyph, id, text, evidence age, one evidence token**. The token
  is the most useful number or word the check produced: a coverage figure, a count of
  findings, the test command, "yours" for a human criterion. Nothing else fits, and
  nothing else is needed at a glance.
- `Enter` on a criterion opens its evidence in a drawer that pushes the "now" and "last"
  sections down: the run's command and exit code, the failing lines, the screenshot path,
  the findings with file and line. `Esc` closes it.
- Keys on a criterion: `c` run its check now, `m` mute for this session, `y`/`n` mark a
  human criterion met or unmet, `o` open the evidence in `$PAGER`.
- Keys on the session: `r` release the current block, `s` steer (opens the composer with a
  steering prefix), `g` edit the goal.
- The "now" section is fed by PostToolUse: the file being edited, the count of edits since
  the last check, and the worker's test runs labelled plainly as *not evidence*. This is
  the line that teaches the user what Sprat is and is not trusting.
- The "last" card shows the most recent intervention. A block is red with its number of
  the ceiling (`#1` of 4). An inform is dim. Nothing shown when there has been none —
  the section reads `— no interventions · on course` in dim text, which is the state a
  good session spends most of its life in.

Widths: the rail composes from 40 columns (text wraps, evidence tokens drop first, ages
drop second) to 79. Below 40 it becomes the status strip from §13.5.

### 13.3 The portfolio board

The screen the CEO opens in the morning and between meetings. At 120 columns and above,
the six zones from `docs/design/tui-zones.md` carry it. ❶ is the portfolio; selecting a
project turns ❸ ❹ ❺ into that project's view; selecting a session under it narrows them to
the session (the session view, §13.5).

```text
╭─ ❶ Portfolio ─────────────────╮╭─ ❸ liftlog · class bookings without a spreadsheet · due 30 Nov ─╮╭─ ❹ Inspector ──────────╮
│ ⚑ cupful     2/6 · 1 live ││ 2 of 5 met · 1 unknown · floor held      ▰▰▱▱▱  ▁▁▂▂▃▃▃ 14d     ││ [Backlog] Criteria     │
│   i18n checkout blocked #4     ││                                                                  ││ Sessions Runs Usage    │
│                                ││ ✓ p1 book a class + confirmation   done 29 Oct  g_01HZ           ││                        │
│ ● liftlog         2/5 · 1 live ││ ✓ p4 suite green, coverage ≥85%    floor held  standing          ││ 1 p2 weekly schedule   │
│   book-a-class 4/7 ⠙           ││ ⠙ p2 owners set weekly schedule    4/7 live    g_01J2 · 1h 12m   ││   est. 1 session       │
│                                ││ ○ p3 capacity and cancellations    backlog     after p2          ││ 2 p3 capacity + cancel │
│ ● sprat           1/6 · 1 live ││ ? p5 three real owners booked      yours                         ││   depends on p2        │
│   v3-observe   1/6 ⠙           ││                                                                  ││                        │
│                                ││ ── today ─────────────────────────────────────────────────────── ││ + add from brief       │
│ ○ fieldnotes        4/4 ✓        ││ 09:12  session bound to p2 (book-a-class → weekly-schedule)      ││                        │
│   idle 3d · backlog empty      ││ 10:40  ✓ c2 c3 c4 met · 88.1%                                    ││                        │
│                                ││ 10:58  ⛔ blocked stop #1 · c1 c5 unmet                          ││                        │
│ 4 projects · 3 live · 1 needs  ││ 11:02  ◉ Claude editing schedule_live.ex                         ││                        │
│ you · $2.14 today / $30        ││                                                                  ││                        │
╰───────────────────────────────╯│                                                                  │╰────────────────────────╯
╭─ ❷ Roles ─────────────────────╮│                                                                  │╭─ ❺ Detail ─────────────╮
│ ◆ PM        ⠙ brief 08:55     ││                                                                  ││ p2 · g_01J2             │
│ ✓ Reviewer  ✓ 10:58 liftlog   ││                                                                  ││ rail view of the live   │
│ ▲ Analyst   ○ none            ││                                                                  ││ session (§13.2)         │
│ ⌁ Checks    ⟳ 2 queued        ││                                                                  ││                         │
╰───────────────────────────────╯╰──────────────────────────────────────────────────────────────────╯╰────────────────────────╯
╭─ ❻ ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮
│ >                                                                                                                           │
╰─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯
 NAV · 4 projects · 3 live · 1 needs you · $2.14 today · tab zones · b brief · ? help
```

Rules the board follows:

- **Sort is needs-you first, then live, then idle.** Within a group, most recently changed
  first. The CEO's question is "where am I needed", and the answer is the top row.
- **Each project row is two lines**: name, project met/total, live count, state glyph; then
  the one session or condition that explains the glyph (`i18n checkout blocked #4`,
  `idle 3d · backlog empty`). Nothing else.
- **A done project stays** until the user archives it (`a`), shown with `✓` and dimmed, so
  the board also says what was finished this month.
- The project view in ❸ is the project goal's scorecard above a timeline of today's events
  across all its sessions. ❹'s **Backlog** tab is the ordered list with `J`/`K` to reorder,
  `Enter` to draft the session goal, `+` to add one from the brief.
- ❺ shows the selected live session as its rail (§13.2), so the detail of a session is the
  same picture whether the user is in the pane or on the board.
- Keys on a project: `Enter` open, `b` brief for this project, `g` edit the project goal,
  `a` archive, `d` drive the top of the backlog (Phase C).

### 13.4 The brief

`b` on the board, `/brief`, or `sprat brief` from any shell, and once a day at a time the
user sets (default 08:55) as a desktop notification whose body is the first three lines.
It is the standup the CEO would get from a human PM, in the user's own standup style:
short, lowercase, one line per project, what moved, what is stuck, what needs a decision.

```text
brief · thu 30 oct · 4 projects · $9.80 yesterday

cupful: i18n checkout blocked 4 times on the same criterion (c3 currency
  rounding test); needs you — release it or look at the test
liftlog: book-a-class done yesterday with 7/7; weekly schedule started 09:12, 4/7,
  on course; p5 (three real owners) still yours
sprat: v3-observe 1/6, reviewer found 2 major in hooks client, worker fixing; nothing
  needed
fieldnotes: done, idle 3 days, backlog empty — archive or add the next goal

net: 1 decision, 1 goal finished, 2 moving, 1 idle
```

Every line is derived from events and scorecards. The PM writes the prose; the facts in it
are each traceable to an event id, and `Enter` on a line opens the project. A brief never
contains a number the store does not hold.

### 13.5 The session view

Selecting a session on the board narrows ❸ ❹ ❺ to it: ❸ becomes that session's timeline,
❹'s tabs become the session's Criteria, Checks, Interventions, Runs, Diff, Usage, Events,
and ❺ the selected evidence. Zone contents:

```text
╭─ ❶ Sessions ───────────╮╭─ ❸ Timeline · liftlog · book-a-class ─────────────╮╭─ ❹ Inspector ───────────╮
│ liftlog                ││ 13:41  goal attached · 7 criteria · ceiling $3     ││ [Criteria] Checks       │
│ ▸ book-a-class   4/7 ⠙ ││ 13:41  ℹ goal card injected at SessionStart        ││ Interventions Runs      │
│   onboarding     7/7 ✓ ││ 13:52  ✓ c2 c3 c4 met · mix test 0 · 88.1%         ││ Diff Usage Events       │
│ cupful            ││ 13:58  ✓ c6 reviewer: 2 minor, 0 blocker  $0.31    ││                         │
│ ▸ i18n-checkout  2/5 ⛔ ││ 14:02  ⛔ blocked stop #1 · c1 c5 unmet            ││ ✓ c2 tests pass         │
│ sprat                  ││        flow fails at step 3: confirm button is     ││ ✓ c4 no warnings        │
│   v3-observe     1/6 ⠙ ││        below the fold at 390px → r_41              ││ ✓ c3 coverage 88.1%     │
│                        ││ 14:03  ◉ Claude editing booking_live.ex            ││ ✓ c6 reviewer 2 minor   │
│ 3 live · 1 blocked     ││ 14:05  ⟳ c2 c3 c4 scheduled (edit under path)      ││ ✗ c1 flow on phone      │
│                        ││                                                     ││ ✗ c5 UX audit           │
╰────────────────────────╯│                                                     ││ ? c7 email copy  yours  │
╭─ ❷ Roles ──────────────╮│                                                     │╰─────────────────────────╯
│ ◆ PM        ⏸ idle     ││                                                     │╭─ ❺ Detail ──────────────╮
│ ✓ Reviewer  ✓ 13:58    ││                                                     ││ r_41 driven_ui c1       │
│ ▲ Analyst   ○ none     ││                                                     ││ flow book-a-class       │
│ ⌁ Checks    ⟳ 3 queued ││                                                     ││ 390×844 · step 3 failed │
│                        ││                                                     ││ screenshot: r_41-3.png  │
╰────────────────────────╯╰────────────────────────────────────────────────────╯╰─────────────────────────╯
╭─ ❻ ───────────────────────────────────────────────────────────────────────────────────────────────────╮
│ >                                                                                                      │
╰────────────────────────────────────────────────────────────────────────────────────────────────────────╯
 NAV · 3 sessions · supervision $0.89 today · 1 needs you · tab zones · ? help
```

| # | Zone | V3 holds |
|---|---|---|
| ❶ | Portfolio (was Mission) | Every project, then its live sessions beneath it: name, met/total, state glyph. Needs-you sorts to the top. Selecting one drives ❸ ❹ ❺. |
| ❷ | Roles (was Agents) | PM, Reviewer, Analyst, and the check runner, with the same card and flow-gutter behaviour; Drive-mode workers appear here too. |
| ❸ | Timeline (was Conversation) | The session's event stream in plain language: checks, verdicts, interventions, what the worker is doing. The composer's messages go here too — the user talks to the PM about this session. |
| ❹ | Inspector | Tabs: **Criteria** (the scorecard), **Checks** (queue and schedule), **Interventions**, Runs, Diff, Usage, Events. |
| ❺ | Detail | The selected criterion's evidence, a run's output, a finding, or a screenshot path. |
| ❻ | Composer | Unchanged. `/goal`, `/project`, `/backlog`, `/brief`, `/release`, `/mute`, `/check`, `/attach`, `/sessions` added. |

Between 80 and 119 columns: ❶ ❸ ❹ in two columns with ❷ ❺ as overlays, as the zone design
already specifies. Below 80: the rail, showing the session bound to the pane's project, with
`p` to flip to a one-column portfolio list and back.

### 13.6 Intake — writing a goal

`sprat attach` from the project, or `/goal` in the TUI. The first attach in a project writes
the project goal and the standing goal; every later `/goal` writes a session goal, offered
from the top of the backlog. The PM asks at most three questions, in the style V1's intake
already uses, then proposes:

```text
◆ PM  I read the project. Phoenix 1.8, LiveView, `mix test` with 212 tests, no coverage
      threshold set, `test-ui` skill present. Three things change the goal:

      1. Is "book a class" complete when the email is sent, or when it arrives?
      2. Phone-width only, or desktop too?
      3. Anything out of scope you want me to refuse work on?

> sent is fine; phone first, desktop can be ugly; no payments, no waitlists

◆ PM  Proposed goal — edit any line, `a` accepts, `e` opens it in $EDITOR:

      Members can book a class from the mobile web app and get a confirmation email.

      ✓ c1  booking flow works end to end at 390×844        driven_ui · flow book-a-class
      ✓ c2  tests pass                                       test · mix test
      ✓ c3  coverage on lib/liftlog/bookings ≥ 85%           coverage · currently 71% ⚠
      ✓ c4  no compiler warnings, formatted                  lint
      ✓ c5  booking screen passes a UX audit at phone width  skill_review · impeccable audit
      ✓ c6  a reviewer who did not write it finds no blocker reviewer · gpt-5.6-terra
      ? c7  confirmation email copy names class, time, venue human · you mark it

      out of scope: payments, waitlists, native apps
      ceiling: $3.00 supervision · 3 h · 4 blocked stops

      c3's threshold is above today's number. Keep it as the bar, or set it to "does not
      fall below 71%"?
```

What this gets right: the PM shows what it found before asking, asks only what changes
the goal, proposes criteria with their checks visible, and flags the one that is already
failing. The user never fills in a form.

### 13.7 States

| State | What the user sees |
|---|---|
| **No goal, session attached** | Rail shows the objective line as `no goal · press g to write one`, the "now" section still live, no criteria. Only the standing goal, if any, is injected. |
| **Unassigned session** | The project has a backlog but the session has not picked an item: the rail's objective line reads `unassigned · 1 weekly schedule · 2 capacity · g to choose`, and the board row shows `unassigned`. |
| **Project idle** | No session for N days (default 2) with the project goal unmet: the row shows `idle 3d` and the brief says so. Not an escalation; the CEO decides what idle means. |
| **Backlog empty, goal unmet** | Row shows `needs you · backlog empty`; the brief asks for the next goal. |
| **Daily ceiling spent** | The project's supervision stops for the day: checks still run (they are free), judgement checks and the PM's prose do not, and the row says `ceiling $10 spent · checks only`. |
| **Sprat not running** | Nothing; hooks exit 0. On next start, the rail's "last" card reads `missed 14 events while off · catch up?` and a key replays them into the timeline. |
| **Check cannot run** | The criterion shows `!` with the reason (`mix not found`, `timeout 120s`), and Sprat escalates once. It never reports unmet on a check that did not run. |
| **Ceiling spent** | The session's row shows `⚑`, the rail's "last" card says what was spent and that stops are now allowed, and a desktop notification fires once. |
| **Goal done** | The row turns `✓`, the handover is written, the rail offers `h` to read it. With `on_done: ask`, a question card asks the user to confirm before the goal closes. |
| **Released** | The row shows `⇢ released` in amber, not green. It is never shown as done. |
| **Narrow strip** (< 40 cols or < 12 rows) | One line: `liftlog 4/7 ⛔#1 · ⠙ editing` — enough to know whether to look. |
| **Board, nothing attached** | ❶ reads: `No projects. In a project: sprat attach`, and the three commands it needs, nothing else. |

### 13.8 What Claude sees — the goal card

The context Sprat injects is a product surface too. Under 600 tokens, stable in shape so
the model learns to read it, and always ending with what is unmet:

```text
[Sprat · goal for this session]
Objective: Members can book a class from the mobile web app and get a confirmation email.
Out of scope: payments, waitlists, native apps. Constraints: LiveView only; Postgres.
Criteria (Sprat runs every check itself; your own test runs are not evidence):
  met   c2 tests pass · c3 coverage 88.1% ≥ 85% on lib/liftlog/bookings · c4 lint · c6 reviewer
  unmet c1 booking flow at 390×844 — last run failed at step 3: confirm button below the fold
  unmet c5 UX audit — not yet run; run `/impeccable audit lib/liftlog_web/live/booking_live.ex`
        and fix findings at or above major before finishing
  yours c7 email copy — the user will mark this
Sprat will not let the session end while c1 or c5 is unmet. /sprat release asks the user to override.
```

### 13.9 The refusal — what Claude reads on a blocked stop

The block reason is the most important piece of copy in the product. It is read by a model
mid-task, so it is a checklist with evidence and one next action per item, never a
judgement:

```text
Sprat: not done yet — 2 of 7 criteria unmet (blocked stop 1 of 4).

c1 booking flow at 390×844: FAILED at step 3 (run r_41, exit 1).
   "confirm button not visible in viewport" — lib/liftlog_web/live/booking_live.html.heex:48
   Next: make the confirm action reachable without scrolling at 390px, then say "done".
c5 UX audit: NOT RUN.
   Next: run /impeccable audit lib/liftlog_web/live/booking_live.ex and fix findings ≥ major.

Everything else is met on fresh evidence. Do not re-run the test suite to prove c2; Sprat
already did (r_40, exit 0, 12s ago).
```

The same block, as the user sees it in the rail's "last" card, is one line plus the
evidence id. Clicking through shows this text.

### 13.10 Visual language

Everything from the zone design carries over: role colours and glyphs, ASCII and
`NO_COLOR` fallbacks, colour never alone. Added:

| Thing | Glyph | Colour | ASCII |
|---|---|---|---|
| criterion met | ✓ | green | `[x]` |
| criterion unmet | ✗ | red | `[ ]` |
| partial | ◐ | amber | `[-]` |
| unknown / human | ? | cyan | `[?]` |
| stale | ✓ dimmed, age in amber | — | `[x]*` |
| checking | ⟳ | role colour | `[~]` |
| cannot run | ! | red | `(!)` |
| inform | ℹ | dim | `i` |
| steer | ⇢ | blue | `->` |
| block | ⛔ | red | `[X]` |
| escalate / needs you | ⚑ | cyan, bright | `(?)` |
| released | ⇢ released | amber | `->rel` |

Motion, added to the zone design's table and under its rules: a criterion that flips state
pulses its row once for 200 ms; the met-count bar fills on change; the trend sparkline
appends a cell on change; a blocked stop flashes the "last" card once. Nothing moves while
nothing changes, and an idle Sprat uses no CPU.

### 13.11 Why it looks like this

- **Needs-you at the top** because the CEO's first question across projects is where they
  are needed, and the second is what moved; the board answers them in that order.
- **Criteria as rows** because the question is always "which ones", never "how many".
- **Evidence age in every row** because stale evidence is how a supervisor lies by accident.
- **"Not evidence" written out** on the worker's own test runs, because the single idea the
  product has to teach is that the checker and the worker are different.
- **The refusal as a checklist** because its reader is a model that will act on the first
  concrete instruction it finds.
- **No percentage, no score** because a number that is not a count invites gaming by both
  the worker and the user.
- **Nothing decorative moves** because the pane is in peripheral vision all day.

## 14. Positioning

Kept here so the product and the marketing say the same thing, and because the honesty
rules apply to the website too. Written from the owner's own words in the conversation
that produced this spec; the customer-language lines are assumptions to be replaced by
interviews, and are marked.

**One line:** Sprat is the product manager for your coding agent.

**What it does:** You give each Claude Code session a goal. Sprat runs the checks itself —
tests, coverage, lint, a UX audit, an independent review — and refuses to let the session
call itself done until the evidence says so. It shows how far every session is from its
goal, on one screen, with the evidence one keystroke away.

**Category:** supervision for coding agents. Not an agent, not a prompt library, not CI.

**Who it is for:** founders and independent developers who run Claude Code for real work,
across several projects and several sessions at once, and have been burned by "done" that
was not. The person who is CEO, PM and engineering manager of three products at the same
time, and wants to keep being CEO. Not for
teams that want a hosted control plane, and not for people who want an agent to also do the
product thinking for them — that is Sprat V1, a different job.

**Jobs it is hired for:**

1. "Don't let it tell me it's done when it isn't."
2. "Keep every session pointed at the goal while I'm not looking."
3. "Apply the practice I would forget to ask for — the tests, the coverage, the UX
   review, the SEO check — without me prompting it every time."
4. "Tell me each morning which of my projects needs me, and which just moved."

**Why not the alternatives:**

| Alternative | Where it falls short |
|---|---|
| A good CLAUDE.md | Advice. The model reads it, agrees, and then does what the context pressures it to do. Nothing checks. |
| A hand-written Stop hook that runs the tests | One check, no goal, no scorecard, no reviewer, no evidence store, and it blocks forever or never. Sprat is what that hook grows into. |
| Claude Code's own subagents or `/loop` | Same model, same session, no independent evidence, and a schedule is not a judgement. |
| CI | Runs after the fact, on a push, with no idea what the session was trying to do. |
| Watching every session yourself | The thing the person is paying to stop doing. |

**Differentiation, in one sentence each:**

- The checker and the worker are separate processes, and by default separate models.
- Every verdict has evidence with an age, and the UI shows the age.
- It refuses a stop with a line number and a next action, not an opinion.
- It knows the goal, so it can say "that file is out of scope" and "nothing here checks
  the screen you changed".
- It is honest about what it cannot see: a session's cost in Observe mode is shown as
  unknown, not estimated.

**Objections, and the answer the product has to be true for:**

| Objection | Answer |
|---|---|
| "It will nag me." | The ladder (§10): silence by default, one inform per state change, four blocks per goal, a release key. If users release more than they accept, the product is wrong, and the eval measures it. |
| "Another thing to keep running." | Hooks fail open. Sprat down means Claude Code as before, and a catch-up when it is back. |
| "It costs more." | Supervision has its own budget, shown separately, per goal. The eval reports cost alongside outcome. |
| "Why can't Claude Code do this itself?" | It can run tests. It cannot be independent of itself, and it has no reason to refuse its own completion. |

**Customer language (assumed, to be replaced by interviews):**

- "it said it was done and the tests weren't even run"
- "I came back and it had rewritten half the thing I didn't ask about"
- "I have four terminals open and I don't know which one needs me"

**Words to use:** goal, criteria, evidence, check, refuse, release, honest, unknown.
**Words to avoid:** autonomous, AI-powered, intelligent, guarantee, zero-defect, any score
or percentage the product does not actually compute.

**Voice:** the specs' own. Specific, plain, counts not adjectives, states what it cannot do
in the same breath as what it can.

**Proof points:** none yet. The eval in §16 produces the first ones, and the site may not
claim a number the eval did not produce.

## 15. Build sequence

**Phase A — Observe.** The daemon and socket, the hook client, session goal artifact and
intake, the `test`, `lint`, `build` and `coverage` checks for `elixir-phoenix`, the
scorecard, the Stop gate with the ladder's inform and block rungs, the rail. Exit: Sprat
refuses a real session's premature stop in this repository with a reason that names the
failing test, and allows it once the test passes, with every step visible in the rail.

**Phase B — Portfolio.** The project goal, the standing goal, the backlog, binding by
branch on `SessionStart`, the portfolio index, the board, the brief, `needs-you`, the
daily ceiling, desktop notifications, steer and escalate rungs. Exit: three of the owner's
real projects attached at once, each with a project goal and a backlog, the board sorted
correctly on a morning when one of them is blocked, and the brief's every line traceable
to an event.

**Phase C — Judgement.** The Reviewer check on a different model (from v2-review), the
`skill_review` check via a read-only `claude -p` with `--json-schema`, the `driven_ui`
check via the `test-ui` discipline, `acceptance` and `human` criteria, the handover.
Exit: a goal with a UX criterion and a reviewer criterion reaches `done` on a real
session, and the handover's "not verified" list is right.

**Phase D — Drive.** The headless runner over `claude -p` with stream-json, worktrees per
task from v2-implement, `--resume` for follow-ups, the same hooks via `--settings`, cost
known, `d` on a project to drive the top of its backlog within the concurrency ceiling.
Exit: a backlog item handed to Drive mode reaches its criteria without the user touching
the session, and the board shows it beside Observe sessions.

**Phase E — The eval, then trust.** §16. Then, and only then, `on_block: auto` and
`on_done: auto` defaults per project, by evidence.

Second stack profile (`node-next`) lands when the first project that needs it appears,
not before. Estimates omitted for V2's reason: sequence is the commitment.

## 16. How we will know it worked

**The eval set:** eight goals, real ones, in the owner's own projects, each with criteria
written before the run. A feature, a bug fix with a regression test, a UI change at phone
width, a refactor with a coverage floor, a copy change with an SEO criterion, a data
migration, a dependency upgrade, an integration with a mocked external service.

Each goal runs in two configurations, same model, same prompt:

1. **Claude Code with the goal in CLAUDE.md** and no supervisor.
2. **Claude Code with Sprat attached** in Observe mode, same goal.

Judged on: criteria met at the moment the session first said "done" (the number that
matters most); criteria met at the end; defects found by a reviewer who saw neither
configuration; evidence that would have been false if trusted (worker said tests pass,
tests did not); user interventions needed; releases used; supervision cost; wall time.

**Pass:** configuration 2 beats 1 on criteria-met-at-first-done and on false evidence, with
releases used in fewer than a quarter of goals, at a supervision cost under a dollar per
goal on the standard depth.

**Fail:** if the CLAUDE.md configuration is within noise on the first two measures, V3 is a
settings generator — `sprat attach` writes a good Stop hook and a goal card, and the rest
is not built. That is a legitimate, smaller product, and the spec says so now rather than
after Phase B.

## 17. What happens to V2

| V2 piece | Disposition |
|---|---|
| `Sprat.Workspace`, `Runs`, write and shell tools, Diff and Runs tabs (merged) | Kept. Checks run through `Shell`; Drive mode uses worktrees. |
| Technical design and scaffold stages (merged) | Kept as optional stages a goal can start from (`/build` still works); no longer the spine. |
| v2-implement (unmerged) | Merge first. `Sprat.Build.Implement`'s model turn becomes the Drive-mode subprocess in Phase C; `TaskGraph` and `Integrate` carry over unchanged. |
| v2-review (unmerged) | Rebase on v2-implement, resolve the seven conflicts, merge. Becomes the `reviewer` check in Phase B, with the different-model default added. |
| SWE role | Removed. |
| `node-next` profile, Phase C/D of V2, the three-configuration eval | Dropped in favour of §15/§16. |
| V2 §7 safety rules, §9 permissions, §12 honesty | Carried forward verbatim; §12 of this document adds to them. |

## 18. Honesty rules, extended

V1 and V2 rules carry over unchanged. Added:

- **A check the worker ran is not evidence.** Only Sprat's own runs count, and the UI says
  so where the worker's runs are shown.
- **Unknown is shown as unknown.** A session's cost in Observe mode, a human criterion
  nobody marked, a check that could not run: never estimated, never defaulted to met.
- **Stale is not met.** Evidence older than the last relevant edit is shown as stale and
  counts as unknown in the Stop decision.
- **Released is not done.** A goal the user overrode is reported as released, in the
  handover and on the board, for as long as the goal exists.
- **A block always names evidence.** No refusal without a run id or a finding id in it.
- **Sprat reports its own cost** per goal, separately, before the user asks.
- **Sprat never adds a criterion.** It may say one is missing; the user adds it.

## 19. Open questions

1. **Resolved: a daemon.** `sprat serve` runs on login and the TUI attaches (§6). The open
   part is what the daemon does when the user is away for days: it keeps checking, it never
   drives a session on its own (Drive is always started by a key or a command), and it
   stops spending on judgement at each project's daily ceiling. Whether it should drive the
   backlog unattended is a Phase E question with the same answer as every autonomy question
   here: by evidence, per project, never by default.
2. **Transcript reading.** Hooks hand Sprat `transcript_path`. Reading the whole JSONL for
   evidence (what the worker claimed, which files it says it changed) is cheap and useful,
   and also the most privacy-sensitive thing Sprat would do. Inclination: read it only for
   the `last_assistant_message` contradiction check, and say so in `/settings`.
3. **Where the reviewer's model comes from.** Sprat's backend is OpenAI today. Reviewing
   Claude's work with an OpenAI model is independence for free; requiring a second key is
   a real adoption cost. Inclination: default to a different model when a second key is
   present, say plainly in the scorecard when the reviewer shares the worker's model.
4. **Stop-hook timing.** A full test suite can take longer than the `stop_wait` budget.
   Continuous checks on edit make this rare; when it happens, the choice is between
   blocking on "still checking" (annoying) and allowing on stale evidence (dishonest).
   This draft blocks, once, and the eval counts how often.
5. **Resolved: goals outlive sessions.** Binding is by project and branch on every
   `SessionStart` (§6); two sessions on one branch share a goal; parallel goals use
   worktrees. What is still open is the **project goal's own intake**: it needs the CEO's
   answer to "what does done look like in a month" in a form the PM can turn into session
   goals, and V1's research stages may be the right tool to write a good one from a brief.
7. **Cross-project judgement.** A CEO wants Sprat to notice the same mistake made in two
   projects, or a convention one project has that another should. The portfolio index has
   the data. This draft does nothing with it beyond the brief, and names it as the first
   thing worth adding once the board is real.
6. **Marketing criteria.** The owner wants best practice in marketing and GTM applied too.
   The `skill_review` check covers the skills that produce findings over files
   (`seo-audit`, `copywriting` review, `cro`). Checks over things that are not files — a
   positioning decision, a pricing page's logic — need the Analyst and a `human` criterion,
   and this draft does not pretend otherwise.
