# Sprat V4 — Observer Specification

Version: 4.0-draft
Prepared: 23 November 2026
Parent documents: `spec-v3.md` (supervisor, not started; partly superseded here), `spec-v1.md` (the engine), `fleet-layer.md` (the original direction)
Status: **built** (23 Nov 2026): Phases 0–D. Verify is the scoped V3 Stop gate (§9.6); V3 goal intake and reviewer/skill/UI checks remain unbuilt

## 1. What V4 is for

The owner runs many projects at once, each moved forward by Claude Code sessions: on a
typical afternoon, seventeen sessions across nine repositories, several of them worktrees of
the same project. Nobody watches all of them. A session asks a question and waits for two
hours. Another retries the same failing command for forty minutes. A third finished a plan
step yesterday and nothing has started the next one since. The cost is not compute; it is
the owner discovering these things late, one terminal at a time.

V4 makes Sprat the **product manager for every agent**: one process that watches every
Claude Code session on the machine, knows where each project stands on its roadmap, notices
when a project has stopped moving, and gets it moving again itself. It investigates the way
a PM would: it checks the roadmap and recorded decisions, looks in memory and in how the
same problem was solved in other projects, researches on the web, and then unblocks the
agent, answers its question from what was already decided, or gives it the next unblocked
item. The owner is pulled in only for what is genuinely theirs: credentials, money, scope
and judgement calls nobody has written down.

Product promise: **Every project has a position on its roadmap. Sprat keeps every agent
moving toward it, and brings you only what only you can decide.**

### The bet V4 tests

> A PM process that reads every session and every roadmap, detects stalls with plain rules,
> and unblocks agents itself with evidence (research, memory, fleet history, the roadmap)
> cuts the time projects spend stuck, and cuts how often the owner is interrupted, without
> the owner having to undo what it did.

If the owner keeps overriding Sprat, or turns projects down to `propose`, V4 has failed,
whatever it computes. §14 makes that measurable.

### What changed from V3, and why

V3 made Sprat a **quality gate**: a goal with criteria per session, checks Sprat runs
itself, and a Stop hook that refuses premature completion. That is still worth building, but
it is not the owner's first problem, and it needs an intake conversation and hooks in every
project before it does anything. V4 inverts the order:

| | V3 | V4 |
|---|---|---|
| Centre of gravity | is this session's work *correct*? | is this project *moving*? |
| Setup before value | goal intake + hooks per project | none: reads what is already on disk |
| Unit | session goal and its criteria | project roadmap and its position |
| Main intervention | block at Stop | investigate a stall and unblock, answer or reassign |
| Autonomy | blocks automatically | acts as PM within guardrails; escalates what is the owner's |

Carried over from V3 unchanged: the daemon (§6 there), the intervention ledger and its
rationing (§10 there), the daily brief (§13.4 there), the honesty rules (§18 there). V3's
goals, criteria, checks and Stop gate become V4's Phase D, **Verify** (§13), built on top of
the observer rather than before it.

## 2. What V4 is not

- **Not a coding agent.** It never edits a project's application code. The only file it
  writes inside a project is `.sprat/roadmap.md`, and only when the owner says so.
- **Not the owner.** Sprat acts as the owner's PM, never in their place: credentials, money,
  scope, irreversible actions and unrecorded judgement calls always go to the owner (§8.4).
  Autonomy is per project and the owner can turn it down at any time (§9.1).
- **Not a terminal multiplexer.** It does not host sessions. They stay in the owner's own
  terminals, tmux panes and IDEs.
- **Not a nag.** A finding is raised once per piece of evidence. Dismissed findings stay
  dismissed until the evidence changes.
- **Not a cloud service.** Local, one user, one machine. Transcripts never leave the machine
  except as the excerpt a PM run sends to Claude, which is the provider the session already
  used, plus the PM's web search queries (§9.5).

## 3. Vocabulary

| Term | Meaning |
|---|---|
| **Project** | A git repository. Worktrees resolve to the repository they belong to (`git rev-parse --git-common-dir`) and show as sessions under it. |
| **Session** | One Claude Code session: a live process in the session registry, or a transcript whose process has ended. |
| **Roadmap** | A project's ordered phases, each with ordered items, each `done`, `active`, `todo` or `blocked`. Read from the project's own docs, normalised into `.sprat/roadmap.md`. |
| **Position** | The active phase and item, done/total in that phase, and the time of the last progress. |
| **Progress** | Evidence the roadmap moved: a checkbox ticked in a source plan, a commit on a branch bound to an item, an item marked done in `.sprat/roadmap.md`. Activity is not progress: edits and test runs do not count until something lands. |
| **Finding** | A detector rule matched (§7): rule id, project, session, evidence references, first seen, state. |
| **PM run** | One investigation of a finding by Sprat's PM agent with its toolkit (§8.2), ending in one decision (§8.3). |
| **Nudge** | A `[sprat]` message delivered into a session: an unblock, an answer, a reassignment, or a resume prompt. |
| **Autonomy** | Per project: `watch`, `propose`, `act` or `act+resume` (§9.1). |
| **Yours** | A ticket only the owner can resolve (§8.4): a credential, money, scope, an irreversible action, or a question no recorded decision answers. |

## 4. What Sprat reads

Everything below is already on disk. Sprat installs nothing in a project to start working.

### 4.1 The session registry

Claude Code writes one file per live session process to `<config>/sessions/<pid>.json`:

```json
{"pid": 21108, "sessionId": "8a6497ff-…", "cwd": "/Users/…/cupful_backend",
 "name": "Lantern", "status": "idle", "statusUpdatedAt": 1795126858019,
 "startedAt": 1795107174116, "version": "2.1.328", "kind": "interactive",
 "messagingSocketPath": "/tmp/cc-socks/21108.sock", "peerProtocol": 1, …}
```

`status` takes `busy`, `idle` or `shell`. A file whose `pid` is not alive is a dead session
and is ignored, though its transcript is still read.

`<config>` is **every** Claude config directory on the machine, not only `~/.claude`: this
machine also has `~/.claude-work`. Sprat lists the candidates it found in `/settings` and
the owner can add others. It never merges two sessions with the same id from different
config directories.

Discovery (built): `~/.claude`, every `~/.claude-*` with `sessions/` or `projects/`, and the
`CLAUDE_CONFIG_DIR` of every running process wherever it points, re-checked every slow tick
and remembered in `<data>/v4/claude-dirs` after the process exits. `SPRAT_CLAUDE_DIRS`
replaces all of it. A folder whose `sessions/` symlinks into another is scanned once, and each
live session is attributed to the account its own process runs under (`ps -E`), so two
accounts sharing one `sessions/` folder keep separate usage limits, investigations and resumes.
An ended session keeps the account seen while it was live.

### 4.2 Transcripts

`<config>/projects/<slug>/<sessionId>.jsonl`, one JSON record per line. Sprat tails each
file from a stored byte offset, so a 50 MB transcript costs one read on first sight and a
few kilobytes per poll after. The records it uses:

| Record | Used for |
|---|---|
| `user`, `assistant` (`message.content` with `text`, `tool_use`, `tool_result`) | what was asked, what ran, what failed, the last thing said |
| `assistant.isApiErrorMessage`, `apiErrorStatus` | API errors and quota stalls |
| `system` (`hookErrors`, `compactMetadata`) | hook failures, compactions |
| `ai-title` | the session's human title |
| `cost-state` (`totalCostUSD`, `totalLinesAdded`) | cost and size, where present |
| `worktree-state`, `gitBranch` on records | binding a session to a branch and a roadmap item |
| `pr-link` | a PR as progress evidence |

The transcript format is internal to Claude Code and undocumented. The parser **ignores
unknown record types and unknown fields**, records the Claude Code `version` it last parsed
successfully, and shows a session as `unreadable` rather than guessing when a record it
depends on changes shape. A golden-file test suite pins the shapes it reads (Phase 0, §13).

### 4.3 The project

- `git`: branches, worktrees, commits since a time, dirty state, ahead/behind.
- Roadmap sources (§5).
- `CLAUDE.md` and Claude's per-project auto-memory, so a PM run knows the project's own rules
  and past decisions; the owner's MemPalace through its MCP server.

## 5. The roadmap

### 5.1 Sources, in order of authority

1. **`.sprat/roadmap.md`**: the normalised roadmap. Lines the owner edited win over
   everything below.
2. **`docs/PAUSE.md`**: the handover `/pause` writes. Its ordered "what to continue" list is
   the current position when it exists, and its age is shown.
3. **Plan files**: `docs/superpowers/plans/*.md`, `docs/plans/*.md`, `PLAN.md`, `TODO.md`,
   `ROADMAP.md`: anything with `- [ ]` / `- [x]` items under headings. Each heading with
   checkboxes is a phase; each checkbox an item. Deterministic, no model.
4. **Specs**: numbered "Phase A/B/C" or "Build sequence" sections in `docs/spec*.md`.
   Deterministic where they follow that shape; model-assisted otherwise.
5. **Git history**: commit subjects, merged branches and PRs, used only as progress
   evidence against items, never to invent items.

Source discovery is a list of globs per project, editable in `/settings`; the defaults
above cover the owner's projects as they stand.

### 5.2 Normalisation

On first sight of a project, Sprat builds a **proposed** roadmap from the sources: the
parsers first, then one `claude -p` call with `--json-schema` over whatever the parsers
could not structure. The proposal is shown in the project view with its sources; `w`
writes it to `.sprat/roadmap.md`. Until then the project is tracked from the proposal in
Sprat's own store and the board marks it `unconfirmed`.

```markdown
# Roadmap: cupful
<!-- sprat: edit freely; lines you change are never overwritten -->

goal: Cafe networks share one loyalty balance across venues
due: 2026-12-15

## C · Cafe networks  [active]
source: docs/superpowers/plans/2026-11-14-cafe-networks.md

- [x] schema + migration
- [x] network admin CRUD
- [x] member join flow
- [ ] shared points ledger  <!-- branch: cafe-networks -->
- [ ] cross-cafe redemption
- [ ] network analytics

## D · TV signage
source: docs/cafe_tv_signage_research_and_roadmap.md

- [ ] venue leaderboard  <!-- branch: tv-venue-leaderboard -->
```

Rules:

- **Sync is one-way per line.** An item with a `source:` is re-synced from its source when
  the source changes, unless the owner edited that line in `.sprat/roadmap.md`; Sprat keeps
  a hash of each line as it last wrote it, to tell the two apart.
- **Sprat never adds an item on its own.** It may propose one ("PAUSE.md mentions a backfill
  that no plan has") as a suggestion in the project view.
- **Branch binding.** `<!-- branch: x -->` binds an item to a branch; sessions on that
  branch or its worktree are shown against the item and their commits count as its
  progress. Sprat proposes bindings from branch names and plan titles; the owner confirms.
- **The model is called only when a source's hash changes**, and the result is cached by
  that hash.
- Whether `.sprat/` is committed or ignored is the owner's choice per project, asked once
  when the file is first written.

### 5.3 Position and velocity

- **Position**: the first phase with an undone item, the first undone item in it, done/total.
- **Last progress**: the newest progress event (§3), with its kind: `tick`, `commit`, `pr`,
  `done`.
- **Velocity**: items done per active day over the last 14 days. Shown, never extrapolated
  into a date unless the roadmap has a `due`, and then only as "at this pace: N items short
  by due".

## 6. Architecture

The existing engine stays: `Sprat.Store` (SQLite, event log), `Sprat.Notify`, `Sprat.Budget`,
the terminal pieces (`Width`, `Sanitize`, `Keys`, `Input`, `Composer`, `Markdown`, `Glyphs`,
`Theme`, `Renderer`). V1's research workflows and V2's build workflow are parked behind
`SPRAT_LEGACY=1` and are not loaded otherwise. The OpenAI adapter stays for them; V4's
judgement goes through a new Claude adapter.

```text
            ┌──────────────────────────── sprat serve (daemon) ─────────────────────────────┐
 sessions/  │ Observer.Registry ──┐                                                          │
 *.json ───►│  (poll 2s)          │                                                          │
            │                     ▼                                                          │
 projects/  │ Observer.Transcript ─► Observer.SessionState ─┐                                │
 *.jsonl ──►│  (tail by offset)       (pure projection)     │                                │
            │                                               ▼                                │
 repo docs ►│ Roadmap.Sources ─► Roadmap.Parser ─► Roadmap ─► Observer.Detector ─► Findings  │
 + git      │  (watch hashes)     (+ Claude when needed)      (pure rules)          │        │
            │                                                                      ▼        │
            │                                             PM run (claude -p) ─► Decision       │
            │                                                                      │        │
            │  Store: projects, sessions, roadmap_items, progress, findings, nudges, events │
            └──────────────────────────────┬───────────────────────────────────────┼────────┘
                                           │ pub/sub (Registry)                    │ owner presses s
                                           ▼                                       ▼
                                      sprat (TUI)                          policy + delivery
```

| Module | Responsibility |
|---|---|
| `Sprat.Observer.Registry` | Poll every config dir's `sessions/`, check pids, emit `session_seen` / `session_status` / `session_gone`. |
| `Sprat.Observer.Transcript` | Tail JSONL by offset; parse the records in §4.2 into typed events; tolerate unknown shapes. |
| `Sprat.Observer.SessionState` | Pure fold of transcript events: last assistant text, pending tool use, recent tool results with error signatures, files touched, last activity. |
| `Sprat.Observer.Projects` | Resolve `cwd` → repository → project; worktree → branch. |
| `Sprat.Roadmap.*` | Sources, parsers, normaliser, `.sprat/roadmap.md` reader/writer with line hashes, position and velocity. |
| `Sprat.Observer.Detector` | Pure functions `(project, sessions, roadmap, now) → [finding]` (§7). Property-tested; no I/O. |
| `Sprat.PM` | One PM run per finding (§8): prompt assembly, a resumed `claude -p` session per project per day, the decision schema, follow-up. |
| `Sprat.PM.Tools` | A local MCP server Sprat exposes to its own PM runs: `roadmap_get`, `roadmap_unblocked`, `roadmap_mark` (blocked/done, policy-checked), `fleet_search`, `run_check` (throwaway worktree, allow-listed commands). |
| `Sprat.PM.Policy` | Pure checks over a decision (§8.4, §9.2): owner-only content, rations, budgets, autonomy level. Property-tested. |
| `Sprat.Nudge` | Delivery adapters (§9.3), the `propose`-mode fire flow, never-twice ledger. |
| `Sprat.Fleet.Index` | Error signatures and their resolutions across every project's transcripts, for `fleet_search`. |
| `Sprat.Model.ClaudeCLI` | Runs `claude -p` with `--output-format json`, `--json-schema`, read-only `--allowedTools`, a `--max-budget-usd`, in the project's directory. |

**Daemon or not.** Phase A runs the observer inside the TUI process, so there is something to
use in days. Phase B moves it into `sprat serve` (launchd agent, written with consent) so
detection and the brief continue with the window closed, and the TUI attaches over the
existing pub/sub. Only one observer may run per machine; the second exits with a message
naming the first.

**Polling, not file watching.** Seventeen sessions and nine repos poll in well under the
2-second interval; `FileSystem`-style watchers add a native dependency to the release for
nothing. Revisit only if the poll shows up in a profile.

## 7. Detecting a stall

Rules are code, not prompts. Each takes the projections and returns findings with evidence
references (transcript file + line, commit sha, file path + mtime). Thresholds live in
`/settings` and per project in `.sprat/roadmap.md`'s front matter.

| Id | Name | Fires when | Kind |
|---|---|---|---|
| **W1** | waiting on you | session `idle`, last assistant turn ends in a question to the user or a pending `AskUserQuestion`, for > 10 min | needs you |
| **W2** | permission prompt | a `tool_use` has no `tool_result`, session `idle`, > 5 min | needs you |
| **W3** | API errors | ≥ 2 `isApiErrorMessage` in the last 10 assistant records that are not a usage limit (auth, overload, billing) | needs you |
| **Q1** | usage limit | the session's last assistant record is a usage-limit message ("You've hit your 5-hour limit · resets 11:50am (Europe/London)") | scheduled (§7.1) |
| **L1** | error loop | the same normalised error signature (command + first error line, digits and paths stripped) in ≥ 3 tool results within 30 min, with no relevant file changed between them | stuck |
| **L2** | edit churn | one file edited ≥ 6 times in 20 min while the last test run is failing | stuck |
| **L3** | spinning | `busy` > 45 min with no file change, commit or tick | stuck |
| **P1** | roadmap stalled | project has an active item, no progress for 48 h, no live session on it | stalled |
| **P2** | left mid-step | a session ended with uncommitted changes or an unfinished plan step, and no `PAUSE.md` newer than its last activity | stalled |
| **P3** | claimed done, not done | last assistant turn says done/complete/finished, but the bound item is unticked or the last test run failed | stalled |
| **P4** | idle with work left | session `idle` > 30 min, its last turn is a summary not a question, its bound item is not done | stalled |

### 7.1 Usage limits

A usage limit is not a stall, and it is not the owner's problem. It is a wait with a known
end. Sprat handles it end to end:

1. **Parse the reset.** The time and zone come from the limit message itself
   (`resets 11:50am (Europe/London)`), converted to an absolute instant. If the message
   carries no time, Sprat probes nothing and shows `limit · reset unknown` until the next
   message from that account says more.
2. **The limit is per account, not per session.** Every live session under the same Claude
   config directory (§4.1) is on the same account and is paused by the same limit, even if
   it has not hit the message yet. Sprat marks all of them `limited until 11:50`, and
   pauses its own PM runs on that account too.
3. **Continue at the reset.** At the reset instant plus a minute, Sprat delivers a
   continue message to each limited session that was mid-task:
   `[sprat] Your usage limit has reset. Continue with <roadmap item> from where you
   stopped: <the last unfinished step from the transcript>.` Sessions that were idle with
   nothing pending are left alone.
4. **In roadmap order, not all at once.** Sessions are resumed one at a time, a few minutes
   apart, highest-priority roadmap item first (the project's backlog order, then the
   owner's most recently touched project), so a fresh window is not spent by five agents
   starting together. The order shows on the rail before the reset.
5. **If the session died meanwhile** (closed terminal, reboot), the continue becomes a
   `resume` decision (§8.3): under `act+resume` Sprat starts it, otherwise it is a yours
   ticket with the prompt ready.

On the board, a limited project's row shows `limited · resumes 11:50` in quiet text, not
as a problem. One sprat ticket per account sits on the rail with the countdown and the
resume order. In the brief: `liftlog, studio: hit the 5h limit at 09:12, resumed 11:51`.

This is on by default for every autonomy level except `watch`, because it only ever
continues work the session was already doing.

Rules about the rules:

- **One finding per rule per session per evidence set.** New evidence updates the finding;
  it does not create a second one.
- **Dismissed is remembered.** `x` dismisses with an optional reason; the finding does not
  return until its evidence set changes. Dismissal reasons are the input for tuning
  thresholds (§14).
- **Needs-you findings go to the PM before the owner.** A question asked of the owner is
  first checked against recorded decisions (§8.4); only if none answers it does it become a
  yours ticket, with Sprat's suggestion attached. Permission prompts and API errors go
  straight to the owner.
- **A session the owner is typing in is left alone.** A `user` record in the last 2 minutes
  suppresses every rule for that session.
- **Unknown stays unknown.** If the transcript is unreadable, the session shows
  `unreadable`, and no rule fires on guessed state.

## 8. Sprat as product manager

Detecting a stall is half the job. The other half is the job a product manager does for a
team: find out *why* someone is stuck, find what unblocks them, and if nothing can unblock
them today, give them something else useful to do. Sprat does that itself, for every agent,
without waiting for the owner. The owner hears about it in *served today* and the brief.
Only what genuinely needs the owner reaches the rail as theirs (§8.4).

### 8.1 The PM loop

```text
finding ─► investigate ─► decide ─► act ─► follow up ─► resolved
   │          (toolkit §8.2)  (§8.3)   (§9)    (30 min)     │
   │                                                       └─► unresolved: next rung, or the owner
   └─ W1 question for the owner ─► investigate first: can a recorded decision answer it? (§8.4)
```

One **PM run** per finding: a `claude -p` agent session started by Sprat in the project's
directory with the PM toolkit, a budget, and a structured output (§8.3). Sprat keeps one PM
session per project and resumes it (`--resume`) for that project's next finding, so the PM
remembers what it already tried there today. A new PM session starts each day, seeded with
yesterday's outcomes for that project.

### 8.2 The toolkit

What the PM may use to unstick an agent, roughly in the order it should reach for them:

| Tool | What it gives | How |
|---|---|---|
| **The evidence** | the finding, the condensed transcript tail, the failing lines | assembled by code into the prompt |
| **The roadmap** | the active item, its dependencies, what is unblocked, recorded decisions in specs and plans | Sprat MCP tools: `roadmap_get`, `roadmap_unblocked` |
| **Memory** | what the owner decided before, and how this was solved last time: the project's `CLAUDE.md` and Claude auto-memory (`<config>/projects/<slug>/memory/`), `docs/PAUSE.md`, the owner's MemPalace (`mempalace_search`, `mempalace_kg_query`) | read tools and the MemPalace MCP server |
| **Fleet history** | **the same error in any project's transcript, and what fixed it** (an error signature matched across all projects, with the turns that followed it) | Sprat MCP tool: `fleet_search(signature or text)` |
| **The code** | read-only look at the repo and its history | `Read`, `Glob`, `Grep`, `Bash(git log/show/diff/status *)` |
| **Research** | docs, issue trackers, changelogs, error messages on the web | `WebSearch`, `WebFetch` |
| **A check** | whether a claimed fix works: the project's test or build command, run in a throwaway worktree, never in the agent's checkout | Sprat MCP tool: `run_check(command)`, allow-listed per project |

The PM never gets `Edit`, `Write`, or a general `Bash`. It finds and decides; the agent does
the work. That keeps Sprat's promise of never touching application code, and it keeps one
writer per checkout.

### 8.3 What the PM decides

The PM run ends with one decision, as JSON against a schema. Code, not the model, applies
policy to it (§9.2):

| Action | When | What happens |
|---|---|---|
| `unblock` | the PM found the fix or the missing fact (a doc, a known workaround, the fix from fleet history) | a nudge with the finding, the fact, its source, and the next step |
| `answer` | the agent asked the owner a question that a recorded decision already answers | a nudge answering it **with the citation** (`docs/spec-v3.md §5: "Postgres, not SQLite"`). See §8.4 for the limits. |
| `reassign` | the item is blocked on something nobody can fix today | mark the item `blocked` in `.sprat/roadmap.md` with the reason, and give the agent the next unblocked item, with its plan context |
| `resume` | a project has an active item and no live session (P1, P2) | a resume prompt; in `act` mode, Sprat starts the session itself (§9.1) |
| `wait` | the agent is making real progress the rule misread (a long build, a deliberate loop) | no message; the finding is snoozed with the reason |
| `escalate` | needs the owner (§8.4) | a ticket on the rail marked **yours**, with what the PM already ruled out |

```json
{"action": "reassign",
 "obstacle": "Distribution certificate missing from the keychain; only the owner can add it.",
 "tried": ["fleet_search: same error in liftlog-ios 2026-10-02, fixed by the owner importing the cert",
           "WebSearch: no workaround for archive without a distribution identity"],
 "blocked_item": "B.7", "blocked_reason": "needs the iOS Distribution certificate",
 "next_item": "B.5",
 "message": "…≤ 150 words…",
 "owner_note": "Import the iOS Distribution cert to unblock B.7.",
 "confidence": "high",
 "evidence_used": ["transcript:1822", "transcript:2114", "fleet:liftlog-ios/3f1a:880", "roadmap:B.7"]}
```

`owner_note` is how a `reassign` still tells the owner the one thing only they can do,
without stopping the agent: it lands as a small **yours** ticket while the agent carries on
with B.5.

A decision that cites no evidence is discarded and retried once. If it is discarded again,
the finding escalates.

### 8.4 What stays the owner's

Sprat acts as the owner's PM, not as the owner. These always escalate, whatever the
autonomy setting:

- **Credentials, accounts, money**: keys, certificates, sign-ins, purchases, anything paid.
- **Scope**: adding, removing or reordering roadmap items, or anything outside the active
  phase. The PM may hand out the *next unblocked item in the same phase*. Anything else is
  a proposal.
- **Irreversible or outward-facing actions**: push, deploy, publish, send, delete data,
  migrations on shared databases. A nudge may never ask an agent to do one of these.
- **Questions with no recorded answer.** `answer` is allowed only when the PM cites an
  existing written decision (spec, plan, PAUSE.md, CLAUDE.md, memory) that covers the
  question. A judgement call is the owner's, even when the PM has an opinion. The opinion
  goes on the ticket as a suggestion.
- **Low confidence.** A `low` decision of any kind is shown to the owner, not acted on.

## 9. Acting

### 9.1 Autonomy per project

| Level | Sprat… | Default for |
|---|---|---|
| `watch` | detects and investigates; acts on nothing | projects the owner marks sensitive |
| `propose` | puts every decision on the rail for `f fire` | the first 24 hours of a newly discovered project |
| `act` | delivers `unblock`, `answer`, `reassign` and `wait` itself; puts `escalate` and `owner_note` on the rail | **every project after its first day** |
| `act+resume` | as `act`, and starts a session for `resume` itself (`claude` in a new worktree, headless, with the resume prompt, within the project's budget) | opt-in per project |

The level shows on each project's row in the line, and `/settings` and `A` on a project
change it. The owner turning a project down to `propose` is recorded, and Sprat does not
suggest raising it again for a week.

### 9.2 Guardrails code enforces

The model's decision is an input. These are checked in code before anything is delivered:

- **Rations:** at most one delivered message per session per 20 minutes; at most three PM
  runs per finding; then escalate.
- **Budget:** each PM run has `--max-budget-usd` (default 0.50) and `--max-turns` (default
  20). Each project has a daily PM budget (default $3) and the fleet a daily total (default
  $15). At the cap, Sprat drops to `propose` for the rest of the day and says so in the
  header.
- **Content:** a message is refused if it asks for anything in §8.4 (push, deploy, delete,
  credentials, a new item), matched by rule as well as by the PM's own declaration.
- **Roadmap writes:** only `blocked` marks with a reason, and `done` ticks backed by a commit
  or a passing `run_check`. Each write is a separate, reverted-by-`u` event.
- **Never twice:** the same message text to the same session is never sent twice; the same
  `answer` is never given twice for the same question.
- **The owner is typing:** a `user` record in the session in the last 2 minutes holds every
  delivery for that session until it is quiet.

### 9.3 Delivery

Decided in Phase 0 (`docs/phase-v4/00-spikes.md`). The registry's peer socket is internal
and undocumented, so Sprat does not use it.

| Adapter | How | When used |
|---|---|---|
| **cmux** | Map the session's pid to its surface (`cmux top --all --processes --format tsv`), read the pane (`cmux read-screen`), and only when the input prompt is empty and no dialog is open, `cmux send` the message and `cmux send-key enter`. | Default: the owner runs sessions in cmux. |
| **tmux** | `tmux send-keys -t <pane>` with the same empty-prompt check via `capture-pane`, when the registry records a `tmux` pane. | Sessions in tmux. |
| **Headless resume** | For a *dead* session only: `claude --bg --resume <id>` (or a fresh `claude --bg` in the project with the resume prompt) under the project's account. Never on a live session (two writers). | `resume` under `act+resume`, usage-limit resumes of dead sessions |
| **Clipboard** | Copy the message and name the session so the owner pastes it. | Fallback whenever the above are unavailable or the prompt is busy for too long. |

Every message starts with `[sprat]` so the agent and the owner reading the transcript can
tell who sent it, and ends with the roadmap item it serves.

### 9.4 Follow-up

Thirty minutes after delivery (configurable per rule), Sprat checks whether the finding
still matches and whether progress followed. **Resolved:** the ticket slides off and a
line goes into *served today*: `14:31 liftlog-ios unblocked: reassigned B.7 → B.5 (cert)`.
**Unresolved:** the next PM run starts with what was tried; after three, it escalates with
the whole history.

### 9.5 Cost and privacy

- PM runs use the owner's Claude subscription through `claude -p`. Today's spend and run
  count are on the board's header; `/stats` breaks them down per project.
- Transcript excerpts go to the same provider the session used. Web research sends only
  the PM's search queries, which the PM is told never to fill with code, secrets, customer
  data or project names that are not public; queries are logged and listed in `/stats`.

### 9.6 Verify (opt-in)

Built (Phase D, scoped down from spec-v3 §6's Stop gate). Verify lets Sprat refuse a
session's "done" when the project's own checks fail. It is off until the owner switches it
on per project, and it adds nothing to the board.

- **Switching it on.** `sprat attach [path]` shows the exact Stop hook JSON it will merge into
  `<path>/.claude/settings.json` (the project's file, never the user-level one), asks `y/N`
  (`--yes` skips), and merges it without touching any other key or hook, keeping key order.
  A second attach changes nothing; attaching from a moved release replaces Sprat's command in
  place. It also writes `.sprat/checks` when there is none: a commented template plus one
  detected default (`mix.exs` → `mix test`, `package.json` with a real `test` script →
  `npm test`, `pubspec.yaml` → `flutter test`, `Cargo.toml` → `cargo test`, `go.mod` →
  `go test ./...`, pytest config → `pytest`). `sprat detach [path]` removes exactly Sprat's
  hook and leaves `.sprat/checks` in place.
- **The hook.** An absolute command with a 600 s timeout: `<release>/bin/sprat_rt eval
  'Sprat.Verify.CLI.main(["stop"])'` from a release, `cd <source> && MIX_ENV=dev mix run
  --no-start --no-compile -e …` in dev. It never starts the Sprat application, answers in
  about half a second plus the checks, and on any error prints nothing and exits 0, so the
  stop goes through. `sprat hook stop` runs the same code.
- **The checks.** Every non-comment line of `.sprat/checks` (the session checkout's file,
  else the main repository's). They run one after another in the session's own checkout
  (its git top level; Stop fires after the agent's turn, so nothing is editing it), with no
  shell, 300 s each and 540 s in all; a check past its time has its process tree killed. The
  same lines widen the PM's `run_check` allow-list. No file, or no command lines, means
  Verify allows every stop.
- **The decision** (`Sprat.Verify.decide/2`, in order): no checks → allow. A repeat stop
  (`stop_hook_active`) whose working tree (HEAD, diff against HEAD, untracked files) is
  unchanged since Sprat's last refusal → allow; Sprat never blocks twice on the same
  evidence. Four refusals in a row → allow and escalate. Every check passed → allow.
  Otherwise block with a reason in spec-v3 §13.9's shape: each failing check with its exit
  code, the first failing lines (15 in all), what passed (so the agent does not re-run it)
  and one next action. A check that cannot start (command not found) is the owner's to fix
  and never blocks on its own. A new user turn starts a new chain of four.
- **What it records.** Per session, `<data>/v4/verify/<session_id>.json` (refusals in the
  current chain, the last refusal's fingerprint, what failed). Every decision is a line in
  `<data>/v4/verify.log` and a `verify` event in the observer store; a refusal is a
  served-today line ("refused a stop: mix test failed"), and an escalation is one too
  ("stopped refusing after 4 blocked stops: mix test still failing, needs you"). The store
  is opened directly; if it will not open, that part is skipped.
- **Known limits.** The agent can edit `.sprat/checks` itself; Verify does not notice. A
  non-git project has no fingerprint, so a repeat stop there is always allowed. A Stop
  hook's own block from another tool also sets `stop_hook_active`; Sprat only treats a
  stop as a repeat when it refused the previous one.

## 10. The TUI: The Pass

Design record: `PRODUCT.md` (product truth) and `.impeccable/surfaces/lib-sprat-terminal.md`
(direction contract). Chosen from four directions on 23 Nov 2026: Departures, The Pass,
Course and the category standard (htop/k9s style). The sketches are in
`.impeccable/mocks/decision/`.

### 10.1 Why it changes

The current design (`docs/design/tui-zones.md`) is six bordered zones with one in focus,
built for watching one mission's roles work. It fails the observer three ways:

- **It wants a big screen.** Sprat now lives in an **always-on pane** beside the sessions it
  watches, as often narrow and tall as wide. Six zones at 80 columns are six slivers.
- **It spends the screen on context.** Triage needs one answer first ("does anything need
  me?") and everything else one key away.
- **Panes compete.** Focus-jumping between bordered boxes is navigation the owner has to
  think about. A single column read top to bottom is not.

So V4 has **no panes**. One column of stacked bands, read top to bottom, each band a plain
rule and text. Detail opens **in place**, under the thing you selected, never in a side
split or a modal.

### 10.2 The metaphor, held to what it earns

The owner is the **chef**. Sprat is the **expediter** running the pass: it watches every
ticket, chases the cooks (agents) whose dishes are stuck, gets them what they need, and
calls the chef only for what the chef has to decide. The rail shows what is on the pass
right now; the line is the whole kitchen.

| Kitchen | Sprat |
|---|---|
| a ticket on the rail | a finding: something stuck, stalled, or asking |
| an expediter's ticket | **sprat**: a PM run in progress or a message delivered and being followed up (§8–9) |
| a ticket for the chef | **yours**: what only the owner can resolve (§8.4) |
| the ticket's age | how long the evidence has stood |
| firing | the owner sending something Sprat proposed (`f`): a suggested answer, a `propose`-mode decision |
| the line | every project, one row each, with its roadmap position and autonomy level |
| served | what Sprat resolved, and progress, today |

The world contributes **palette, density and one signature move**. It does not contribute
layout or controls: keys are standard, labels name their action, and no kitchen slang
appears on screen except **fire**, which is self-explanatory. (`x` is **dismiss**, not "86".)

### 10.3 The board

At 88 columns (an always-on side pane):

```text
 SPRAT <•<                                     mon 23 nov  14:02 · pm $2.40/15

 ON THE RAIL ───────────────────────────────────────── yours first, oldest left ─
 ┏━━━━━━━━━━━━━━━━━━━━━━━━━┓ ┌─────────────────────────┐ ┌──────────────────────┐
 ┃ 25M yours  liftlog-ios  ┃ │ 18M yours  cupful  │ │ 4M sprat dreamboard │
 ┃ import the iOS Distri-  ┃ │ asks: keep network_id?  │ │ researching Expo     │
 ┃ bution cert to unblock  ┃ │ no recorded decision    │ │ build error: web,    │
 ┃ B.7                     ┃ │ sprat suggests: keep    │ │ fleet history        │
 ┃ agent moved on to B.5   ┃ │                         │ │ ><>                  │
 ┃ ⏎ details               ┃ │ f fire answer  ⏎ edit   │ │ ⏎ watch              │
 ┗━━━━━━━━━━━━━━━━━━━━━━━━━┛ └─────────────────────────┘ └──────────────────────┘

 THE LINE ───────────────────────────────────────────────────────────────────────
 cupful   C 3/9   ▰▰▰▱▱▱▱▱▱▱  shared points ledger        ● ● ◌ ⏸   act
 liftlog-ios   B 5/10  ▰▰▰▰▰▱▱▱▱▱  onboarding screens (B.5)    ● ◌       act
 dreamboard   2 2/8   ▰▰▱▱▱▱▱▱▱▱  onboarding copy             ●         act
 liftlog       A 7/10  ▰▰▰▰▰▰▰▱▱▱  merch checkout              ● ●       act
 forge        3 2/7   ▰▰▰▱▱▱▱▱▱▱  admin MCP tools             ●         watch
 homescout   4 4/9   ▰▰▰▰▱▱▱▱▱▱  search API · inferred       ◌ ◌       propose
 tipjar       1 4/5   ▰▰▰▰▰▰▰▰▱▱  payouts · limited, resumes 15:10      act
 studio          no roadmap yet · r propose                      ●         propose
 fieldnotes      ✓ all phases done

 SERVED TODAY ─ by sprat unless marked ──────────────────────────────────────────
 13:44  liftlog-ios   reassigned B.7 → B.5 (cert missing), yours: import cert
 13:10  liftlog       unblocked: Stripe test clock fix from tipjar, 2 Oct
 12:02  cupful   answered "Postgres or SQLite?" from spec-v3 §5
 11:02  liftlog       ticked A.7 merch cart (commit 4e1c)
 10:40  dreamboard   resumed 2.3 from PAUSE.md (you, f)

 ←→ ticket  ↑↓ project  ⏎ open  f fire  x dismiss  b brief  / command  ? help
```

**Bands, top to bottom.**

1. **Header.** `SPRAT`, the fish, the time, today's PM spend against the fleet cap. The fish
   faces you (`<><` / `<•<`) while any **yours** ticket is on the rail, and swims (`><>`)
   while a PM run is in progress. It blinks for ten seconds when a new yours ticket lands,
   then holds still. With nothing yours and nothing running it is still, and idle animates
   nothing.
2. **On the rail.** Tickets side by side: **yours** first, then **sprat**, each group
   oldest left. Up to three at 88–119 columns, `+2 more →` beyond that. A ticket is a thin
   rule with four parts: **age chip, owner word, project**; **the obstacle or what Sprat is
   doing, in at most three lines**; for yours tickets, **what Sprat already did meanwhile**;
   and **the action and its key**. The selected ticket's rule is heavy and bright. A sprat
   ticket's owner word and text are quiet; it carries a small swimming `><>` while its PM
   run is live. When the rail is empty it collapses to one dim line, `rail clear`.
3. **The line.** One row per project: name, phase and done/total, a fixed-scale bar (one
   cell per item up to ten, so bars compare across projects), the current item, one glyph
   per session, and the project's **autonomy level** in quiet text. Sorted by the worst
   state, then by most recent change. A project with a yours ticket shows in bright text.
4. **Served today.** What Sprat resolved and what progressed, newest first, at most five
   lines, each naming the action and **its source** (the spec section, the other project's
   fix, the web page). This is where the owner sees Sprat working as their PM, and where a
   wrong call gets noticed: `⏎` on a line opens the PM run behind it, `u` reverts its
   roadmap writes.
5. **Footer.** Keys for the current selection only.

### 10.4 A ticket, opened

`⏎` on a ticket opens it **in place**, full width, directly under the rail. The rail stays
visible above it, and the line stays visible below it, dimmed. `esc` folds it back. There is
no modal and no side split. An opened ticket shows the whole PM run: what it found, what it
tried, what it did, and what is left for the owner.

```text
 ON THE RAIL ───────────────────────────────────────── yours first, oldest left ─
 ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
 ┃ 25M  yours · liftlog-ios · liftlog-ios-77                                     ┃
 ┃                                                                               ┃
 ┃ you        Import the iOS Distribution certificate into the login keychain;   ┃
 ┃            B.7 (App Store archive) is blocked until then.                     ┃
 ┃                                                                               ┃
 ┃ found      L1 error loop: 4× "No signing certificate 'iOS Distribution'       ┃
 ┃            found", 13:18–13:43, no file changed in between                    ┃
 ┃ tried      fleet history: same error in liftlog-ios on 2 Oct; you fixed it    ┃
 ┃              by importing the cert                                            ┃
 ┃            web: no way to archive for the store without a distribution        ┃
 ┃              identity (developer.apple.com, 2 sources)                        ┃
 ┃ did        13:44  marked B.7 blocked in .sprat/roadmap.md          u revert   ┃
 ┃            13:44  told the agent: stop retrying, switch Debug to automatic    ┃
 ┃                   signing, move on to B.5 onboarding screens       ⏎ message  ┃
 ┃            14:01  follow-up: agent on B.5, 3 files changed. resolved          ┃
 ┃                                                                               ┃
 ┃ pm run     $0.31 · 11 turns · confidence high                     ⏎ full run  ┃
 ┃ x done (I imported it)   c copy note   esc fold                               ┃
 ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
 THE LINE ─ dimmed ──────────────────────────────────────────────────────────────
```

On a **question** ticket (W1 with no recorded answer), the PM's suggested answer sits in the
`you` block, editable in place with `e` (the existing `Sprat.Terminal.Composer`), or in
`$EDITOR` with `E`. `f` fires it into the session as the owner's answer, marked
`[sprat, from the owner]`. Under `propose` autonomy, every decision arrives like this, with
`f fire` as its action.

When the owner clears a yours ticket (`x`), Sprat asks once whether the blocked item can be
unblocked, and if so hands it back to the next free session on that project.

### 10.5 Narrow and wide

The pane is often narrow. The layout responds to width; nothing ever scrolls horizontally.

| Width | Rail | Line |
|---|---|---|
| ≥ 120 | up to four tickets | as at 88, plus a "last progress" column |
| 84–119 | up to three tickets | as shown |
| 60–83 | **strips**: one line per ticket, stacked | the bar shortens to 6 cells; the session glyphs stay |
| < 60 | strips on two lines each | two lines per project: name and glyphs, then position |

At 56 columns:

```text
 SPRAT <•<                                  14:02

 ON THE RAIL ──────────────────────── yours first ─
 ▌25M yours liftlog-ios  import the cert     ⏎
  18M yours cupful  network_id? keep    f
   4M sprat dreamboard  researching ><>     ⏎

 THE LINE ─────────────────────────────────────────
 cupful  C 3/9   ▰▰▱▱▱▱  ● ● ◌ ⏸
 liftlog-ios  B 5/10  ▰▰▰▱▱▱  ● ◌
 liftlog      A 7/10  ▰▰▰▰▱▱  ● ●
 forge       3 2/7   ▰▰▱▱▱▱  ●
 dreamboard  2 2/8   ▰▱▱▱▱▱  ◌ stalled
 …4 more                         ↓

 ←→ ↑↓ move  f fire  ⏎ open  ? help
```

Height matters as much as width. In a short pane, *served today* goes first, then the line
truncates to `…N more`; the rail is never truncated, because it is the reason the pane is
open.

### 10.6 The project and the session

`⏎` on a line row turns the board into that project. Same column, same bands, scoped:

```text
 SPRAT <•<  › cupful                              C · 3/9 · 1.2 items/day

 ON THE RAIL ───────────────────────────────────────────────────────────────────
  18M yours  asks: keep the old network_id column? sprat suggests: keep   f fire

 ROADMAP ─ .sprat/roadmap.md ───────────────────────────────────────────────────
 ✓ A  Loyalty core                                           8/8
 ✓ B  Wallet passes                                          5/5
 ▸ C  Cafe networks                                          3/9
      ✓ schema + migration
      ✓ network admin CRUD
      ✓ member join flow
      ▸ shared points ledger            cafe-networks-4b ⏸
      ○ cross-cafe redemption
      ○ network analytics   …3 more
 ○ D  TV signage                                             0/6

 SESSIONS ──────────────────────────────────────────────────────────────────────
 ⏸ cafe-networks-4b     waiting on you 18m
 ● cafe-networks-7d     editing network_live.ex · 2m
 ● tv-venue-leaderboard mix test · 30s
 ◌ Lantern            idle since 11:40

 SERVED ─ last 7 days ──────────────────────────────────────────────────────────
 13:12  commit  "Add network member join"          C.3
 yest   pr      #212 network admin                 C.2

 sources  plans/2026-11-14-cafe-networks.md · PAUSE.md (3d) · git 41 commits/14d
 ↑↓ move  ⏎ open  e edit roadmap  w write roadmap  esc back  ? help
```

At 140 columns and wider, ROADMAP and SESSIONS sit side by side as two text columns
separated by space, not by a border. Below that they stack.

`⏎` on a session shows its condensed transcript in the same column: one line per tool call
or assistant turn, failures in red, the owner's own prompts bright, `⏎` to expand a line.
It is a reader, not a terminal. Typing into the session happens in the session's own
window.

### 10.7 Palette and type

**Sprat never paints the background.** It lives in the owner's terminal beside their other
panes, so it uses the terminal's default ground. The palette is foreground roles only,
chosen to hold on a dark ground (the owner's setup) and stay legible on a light one.

| Role | Truecolor | 256 | 16 / NO_COLOR |
|---|---|---|---|
| text | `#efe8da` warm paper | 255 | default fg |
| bright (selected, needs-you rows) | `#fffaf0` + bold | 231 + bold | bold |
| quiet | `#7c7468` warm grey | 244 | faint (SGR 2) |
| rule (ticket outline, band rules) | `#4a443c` | 239 | faint |
| **you** (needs you, the fish facing you, ⏸) | `#e0a93b` amber | 179 | yellow · `⏸`/`||` |
| **stuck** (⚠, red chip) | `#c8432f` | 167 | red · `⚠`/`!` |
| progress (bar fill) | `#a7c27a` | 150 | green · `▰`/`#` |

- **The age chip is the only filled shape on screen**: reverse-video text in its colour.
  It steps by age at the finding rule's thresholds: quiet (fresh), amber (worth your
  attention now), red (past twice the threshold or an unresolved nudge). That stepping is
  **the signature move**. The only animation besides the fish is a ticket sliding onto or
  off the rail (150 ms; skipped under `SPRAT_REDUCED_MOTION=1`).
- **No light fills, no tinted panels.** Hierarchy comes from brightness (bright, normal,
  quiet) and position.
- **Type** is the owner's terminal font. Bold for the selection and for projects on the
  rail; nothing else is bold.
- **ASCII mode** (`--ascii` or a non-UTF-8 locale): rules become `-` `|` `+`, the heavy
  selected rule becomes `=`, `▰▱` become `#.`, glyphs become `* o || ! v`, and the fish is
  already ASCII. Every state is still a word or a glyph, never only a colour.

### 10.8 Glyphs

| Glyph | ASCII | Meaning |
|---|---|---|
| `●` | `*` | session working |
| `◌` | `o` | session idle |
| `⏸` | `\|\|` | waiting on you |
| `⚠` | `!` | stuck |
| `·` | `.` | session ended with work left |
| `▸` | `>` | current phase or item |
| `✓` | `v` | done |
| `○` | `-` | to do |

### 10.9 Keys

| Key | Board | Ticket open | Project | Session |
|---|---|---|---|---|
| `←→` / `hl` | move along the rail | | | |
| `↑↓` / `jk` | move down the line | | move | scroll |
| `⏎` | open ticket / project | open session | open item / session | expand line |
| `esc` | | fold | back | back |
| `f` | fire the selected ticket's proposal | fire | fire (project rail) | |
| `u` | | revert the PM run's roadmap writes | | |
| `A` | | | cycle autonomy: watch → propose → act → act+resume | |
| `e` / `E` | | edit nudge inline / in `$EDITOR` | edit roadmap in `$EDITOR` | |
| `c` | | copy nudge | | |
| `x` | dismiss, or mark a yours ticket done | same (asks reason) | | |
| `m` | | mute this rule for this session | | |
| `w` / `r` | | | write / re-read roadmap | |
| `b` | brief | | project brief | |
| `/` | command: `/settings` `/brief` `/findings` `/nudges` `/add <path>` `/stats` | | | |

### 10.10 The brief

`b`, `/brief` or `sprat brief`, and once a day as a desktop notification. Same shape and
style as V3 §13.4 (one lowercase line per project: what moved, what is stuck, what needs a
decision), with positions from the roadmap:

```text
brief · mon 23 nov · 9 projects · 4 items done yesterday · 6 nudges, 5 resolved

cupful: C 3/9; cafe-networks-4b waiting on you 18m (network_id column)
liftlog-ios: B 5/10; signing cert missing, sprat moved the agent to B.5; you: import the cert
liftlog: A 7/10, merch checkout done yesterday, on course
dreamboard: stalled 2 days at 2.3 (onboarding copy); resume prompt ready
fieldnotes: done 9 days ago; archive or add a roadmap

net: 2 decisions for you, 1 resume, 5 moving
```

Every fact traces to an event; the brief never contains a number the store does not hold.

### 10.11 What carries over from the current renderer

Kept: `Width`, `Sanitize`, `Keys`, `Input`, `Composer`, `Markdown`, `Glyphs`, `Mascot`,
`Theme` (new roles), the alternate screen, `--plain`, and mouse off by default so native
text selection works. Replaced: `Zone`, `ZoneFrame`, `ZonedRenderer`, `Focus`, `Layout`'s zone
map. These are superseded by one `Sprat.Terminal.Board` that lays out bands in a single
column and owns the in-place expansion.

`docs/design/tui-zones.md` is marked superseded by this section.

## 11. Store additions

New tables in the existing SQLite store, all event-sourced from the existing events table:

`projects` (root, name, config dirs seen, roadmap path, archived), `sessions` (session id,
config dir, pid, project, branch, status, last offset, last activity, readable version),
`roadmap_items` (project, phase, item, state, source, line hash, branch binding),
`progress` (project, item, kind, ref, at), `findings` (rule, project, session, evidence ids,
state, first/last seen, dismissal reason), `nudges` (finding, text, adapter, state,
delivered at, outcome), `pm_runs` (finding, decision, tools used, sources, cost, turns),
`accounts` (config dir, limited until, resume queue), `autonomy` (project, level, changed
by, at), `roadmap_writes` (item, change, PM run, reverted).

## 12. Honesty rules

V1, V2 and V3 rules carry over. Added:

- **Activity is not progress.** The board's "last progress" never counts an edit or a test
  run, only something that landed.
- **Unconfirmed roadmaps say so.** Until the owner writes or confirms it, a roadmap is shown
  as `unconfirmed`, and its position is labelled inferred.
- **A finding always cites evidence.** No finding without a transcript line, commit or file
  reference behind it.
- **Sprat reports what it could not read.** Unreadable transcripts, unknown config dirs,
  sources that failed to parse: listed in `/settings`, counted on the board's header.
- **Every PM action names its source.** An unblock cites the doc, fix or page it came
  from; an answer cites the written decision; a reassignment cites what blocked the item.
- **Sprat never answers as the owner without a written decision behind it.** A suggestion
  is labelled as Sprat's, every time.
- **Everything Sprat did is visible and its roadmap writes are revertible.** Served today,
  the opened ticket and `/stats` show every action; `u` reverts any roadmap write.

## 13. Build sequence

**Phase 0: spikes (days).**
1. Transcript shapes: golden files from the owner's real transcripts across the two Claude
   Code versions on the machine; a parser that extracts §4.2 and fails loudly.
2. Peer delivery: can Sprat deliver a message to a live session's socket, does it arrive at
   the next tool round or wake an idle session, and what does the session show. Decide
   whether to depend on it (§15.1).
3. W1/W2 detection: confirm "idle with a pending question" and "idle on a permission
   prompt" are distinguishable from the transcript alone.
Exit: a decision record per spike in `docs/phase-v4/`.

**Phase A: the board, read-only.** Registry, transcript tail, projects and worktrees,
roadmap parsers (PAUSE.md, plan checkboxes, spec phases), `.sprat/roadmap.md` read and write,
position and last progress, the Pass TUI (§10): board, opened ticket, project and session views, narrow layouts, `sprat status`.
No model calls. Exit: the owner's nine projects appear correctly on one screen, each with a
position the owner agrees with, and the owner uses it instead of switching terminals for a
day.

**Phase B: findings and the PM in `propose`.** The detector rules (§7), usage-limit
handling (§7.1), `Sprat.Model.ClaudeCLI`, PM runs with the full toolkit (§8.2: roadmap,
memory, MemPalace, fleet history, web research, `run_check`), decisions on yours tickets,
desktop notifications, budgets, the brief, the daemon. Every decision waits for `f fire`.
Exit: a week of real use in which the owner fires most decisions unedited, and every stall
the owner found on their own had already been raised.

**Phase C: the PM acts.** `act` as the default after a project's first day, `Sprat.PM.Policy`,
delivery adapters, follow-up and resolved/unresolved, roadmap writes with revert,
`reassign`, `answer` from recorded decisions, the served-today audit trail. Exit: two weeks
where Sprat resolved most stalls without the owner, the owner reverted fewer than one in
ten of its actions, and no project was turned down to `propose`.

**Phase D: resume and verify.** `act+resume` (headless sessions in worktrees for dead
sessions), V3's goals, criteria, checks and Stop gate as an opt-in **Verify** layer, so the
PM can also refuse "done" when it isn't. Switched on per project, by evidence.

Built for Verify (§9.6): `sprat attach`/`detach`, the Stop hook (`sprat hook stop`), the
project's `.sprat/checks` run in the session's checkout, the Stop decision (never twice on
the same evidence, four refusals then escalate, a §13.9-shaped reason), the per-session
state, `verify.log`, `verify` events and served-today lines. Not built: V3's goals and
criteria and their intake, the scorecard, checks running continuously on change, the
`reviewer`, `skill_review`, `driven_ui`, `coverage`, `acceptance` and `human` check types,
the other hooks (SessionStart goal card, PreToolUse ceiling, SubagentStop), the socket to
a running Sprat and its spool, and a board view of Verify decisions.

## 14. How we will know it worked

Measured from the event log, shown in `/stats`:

- **Time to notice:** minutes from a finding's evidence first existing to the owner acting
  on it (send, dismiss, answer). Baseline: Phase A's board with no findings, one week.
  Target: halved in Phase B.
- **Dismissal rate** per rule. Above 50% for a rule over a week means the rule is wrong:
  tighten it or delete it.
- **Resolved without the owner:** share of findings Sprat closed itself, per action
  (`unblock`, `answer`, `reassign`, `wait`, limit resumes).
- **Owner overrides:** reverted roadmap writes, corrected answers, projects turned down to
  `propose`. Target: under one in ten actions. This is the number that says whether Sprat
  can be trusted as a PM.
- **Interruptions:** yours tickets per day. Target: falling while stalled days fall too.
- **Limit time recovered:** minutes from a usage-limit reset to the session working again.
- **Stalled days:** project-days with no progress while an item was active, before and
  after.
- **Is it open:** hours per day the TUI or daemon ran. If the owner stops opening it, nothing
  else on this list matters.

## 15. Open questions

1. **Resolved: delivery.** cmux and tmux, never the internal peer socket (§9.3, Phase 0).
2. **Many Claude config directories.** Sessions under `~/.claude-work` belong to a
   different account. They are shown together on one board by default; whether the owner
   wants a per-account filter is a question for the first week of use.
3. **Roadmaps that disagree.** A PAUSE.md that says "next: C.5" while the plan says C.4 is
   undone. This draft takes PAUSE.md's view, shows the disagreement as a suggestion, and
   never resolves it silently.
4. **Cross-project patterns.** `fleet_search` already uses another project's fix to unblock
   this one. Going further (noticing a convention one project has and another lacks, and
   proposing it) is a scope change, so it stays a proposal on a yours ticket.
6. **Answering for the owner.** `answer` needs a written decision behind it (§8.4). How
   strict "covers the question" is will only be known from real cases; the first two weeks
   of Phase C log every answer for the owner to grade.
7. **Spending a fresh window.** Resuming limited sessions one at a time protects the new
   window, but the right spacing depends on how fast each agent burns it. Start at five
   minutes apart; tune from the event log.
8. **Which account runs the PM.** PM runs use the account of the project's config
   directory, and pause with it at its limit. Running them on a different account the
   owner has is possible but is a choice about the owner's subscriptions, so it is the
   owner's setting, off by default.
5. **What happens to `sprat_web`.** The site's milestones and copy describe the research
   product. They need rewriting once Phase A is real, not before.
