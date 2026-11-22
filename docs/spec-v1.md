# Sprat V1 — Build Specification

Version: 1.0-draft
Prepared: 17 September 2026
Parent document: `spec-full.md` (long-term target architecture)
Platforms: macOS (Apple Silicon, Intel), Linux x86-64
Interface: inline terminal UI, modelled on Claude Code
Core implementation: Elixir and OTP

## 1. Purpose of this document

`spec-full.md` describes where Sprat should end up. This document defines the smallest version worth shipping: one that proves the product's central bet and gives founders something useful from the first week.

**Central bet:** a small, disciplined team of research roles produces better-evidenced product decisions than a single general-purpose agent, at an acceptable extra cost.

V1 does not assume this bet is true. Phase 0 tests it before the full product is built (§14). If it fails, V1 ships as a single-agent research tool with the same UI, evidence store and cost accounting, and the role system is removed.

Everything in the parent spec that is not listed here is out of scope for V1 (§15).

## 2. Product definition

Sprat V1 is a terminal research and product-shaping agent for founders and independent developers. You give it an idea or a market question. It researches with real, cited sources, challenges the assumptions, and delivers a product brief and validation plan you can act on. It shows what every role did and what it cost.

Product promise: **Research the problem. Shape the product. Show the evidence.**

V1 does not write application code. Building comes in V2 (§15).

### Core jobs

1. “I have an idea. Help me decide who it is for and what to build first.”
2. “Research this market and find a worthwhile opportunity.”
3. “Here is my repository. Given what already exists, what should I build next?” (read-only)
4. “Show me the sources behind this recommendation.”
5. “Show me what this cost and where the time went.”
6. “Resume yesterday's session with its decisions and artifacts intact.”

### Hard boundaries

- Terminal only. No web UI, no account, no cloud control plane.
- Local only. All state lives on the user's machine. No telemetry.
- One user, one process, one session at a time per project.
- Sprat never claims product–market fit. The strongest conclusion research can reach is “promising hypothesis, validate with …”.
- Sprat never invents interviews, customer quotes, demand figures, revenue or willingness-to-pay data.
- Sprat never implies it researched live when search was unavailable.

## 3. Principles kept from the parent spec

| Principle | V1 behaviour |
|---|---|
| Evidence before conclusions | Every material external claim links to a stored source record. |
| Proportionate work | Research depth (quick, standard, deep) is chosen at intake and can be changed. |
| Code enforces, prompts advise | Tool access, budgets and phase transitions are checked by application code, never by instructions to the model. |
| Honest measurement | Unknown values stay null and are shown as unknown. Failed and cancelled calls are counted. |
| User stays in control | No role can raise a budget, widen file access or skip a gate. |
| Durable progress | Sessions survive crashes and restarts from persisted state. |
| Untrusted input stays data | Web pages and repository files cannot change instructions, budgets or policy. |

## 4. Roles

V1 uses three roles plus a deterministic Orchestrator. The CEO and SWE roles are deferred: in V1 the Analyst covers strategic recommendation, and read-only technical feasibility when a repository is attached.

| Role | Responsibility | Deliverables | Tools |
|---|---|---|---|
| PM | Frame the problem, ask the questions that change direction, propose product directions, write the brief and validation plan | Intake summary, product directions, product brief, validation plan | Read artifacts, ask user, request research task, write PM artifacts |
| Researcher | Gather current evidence on customers, workflows, competitors and alternatives, including counter-evidence | Research memo, source register, competitor matrix | Web search, web fetch, read artifacts, read repository (if attached), write research artifacts |
| Analyst | Challenge assumptions, score opportunities, assess feasibility, recommend go/revise/validate/stop | Assumption register, opportunity scorecard, recommendation memo | Read artifacts and sources, calculate, read repository (if attached), write analysis artifacts |

**Orchestrator** is Elixir code, not an LLM. It runs the workflow template, admits tasks, enforces limits and gates, assembles context and records events.

### Role rules

- A role can have several instances, e.g. two Researchers on different segments.
- Roles communicate only through artifacts and structured handoffs, never a shared chat.
- Each role instance receives a context package built for its task (§8), not the whole session history.
- A role can request extra work (e.g. PM requests a research task) through the `request_task` tool. The Orchestrator accepts or rejects it against limits. Delegation depth is 1: requested tasks cannot request further tasks.
- Disagreements are recorded in the decision log with the evidence on both sides.

### Solo mode

`sprat --solo` and `/solo` run the same workflows with one agent holding all tools. Solo mode exists for three reasons: it is the Phase 0 baseline, it is the fallback if the team fails its evaluation, and it is cheaper for quick questions. It uses the same UI, evidence store and ledger.

## 5. Workflows

V1 has two workflows. Both are fixed templates: a known task graph with a few points where roles can add tasks. There is no free-form agent-designed planning in V1.

### A. Shape an idea (`/idea`, or detected from natural language)

```text
Intake (PM) → Research (Researcher ×1–2, parallel) → Analysis (Analyst)
   → Directions (PM) → [user picks or revises] → Recommendation (Analyst)
   → Brief + validation plan (PM) → Delivery
```

1. **Intake.** PM restates the idea and asks at most three questions that change direction: target customer, geography, constraints and intended outcome. Anything unanswered is recorded as an assumption, not a blocker.
2. **Research.** Researchers study existing workflows, competitors, alternatives, complaints and counter-evidence.
3. **Analysis.** Analyst separates recurring problems from anecdotes and ranks the riskiest assumptions.
4. **Directions.** PM proposes up to three distinct directions, each with customer, problem, value, smallest useful scope and a validation approach.
5. **User choice.** The user picks, combines, rejects or adds constraints. Rejected directions are kept but leave the active context.
6. **Recommendation.** Analyst recommends go, revise, validate first or stop, with tradeoffs. If a repository is attached, this includes a feasibility note grounded in files it read.
7. **Delivery.** PM writes the product brief, assumption register, MVP boundary and validation plan.

### B. Discover an opportunity (`/research`, or detected)

```text
Intake (PM) → Landscape research (Researcher ×2, parallel) → Hypotheses (Analyst: 5–10)
   → Scoring (Analyst: top 3) → Counter-evidence (Researcher) → Recommendation (Analyst)
   → Validation plan (PM) → Delivery
```

The user can stop after any stage and export what exists.

### Gates

Each gate is checked by code: the required artifacts exist, validate against their schema and reference existing sources. An LLM judges content quality; code judges completeness.

| Gate | Code-checked requirement |
|---|---|
| Intake → Research | Objective, depth and budget recorded; open questions listed or answered |
| Research → Analysis | Research memo exists; each material claim references ≥1 source record; limitations section present |
| Analysis → Directions / Scoring | Assumption register exists with at least one assumption ranked by risk |
| Recommendation → Delivery | Recommendation names one of `go`, `revise`, `validate_first`, `stop`, and cites evidence |
| Delivery | All required artifacts accepted, or explicitly marked incomplete with a reason |

A stage that lacks a material fact enters `needs_input`. Independent tasks continue.

### Research depth

| Depth | Researchers | Target sources | Default wall-time limit |
|---|---:|---:|---:|
| Quick | 1 | 5–10 | 5 min |
| Standard | 2 | 15–30 | 20 min |
| Deep | 3 | 40+ with counter-evidence pass | 60 min |

Source targets guide the agents; they are not quotas. Twelve duplicated articles count as one source.

## 6. Evidence and scoring

### Source record

Every fetched or search-result source that supports a claim is stored with:

- URL, title, publisher, publication date (or null), retrieval timestamp
- Source type: `first_party_marketing`, `independent_reporting`, `documentation`, `customer_testimony`, `forum_or_review`, `user_provided`
- Content hash and a stored text snapshot (for later re-checking)
- Canonical key for de-duplication (normalised URL, plus near-duplicate detection on title and content hash)

### Claim record

- Claim text, the artifact and section it appears in
- Supporting source IDs and contradicting source IDs
- Confidence: `high`, `medium` or `low`, with a one-sentence justification. No numeric probabilities.
- Scope: geography and customer segment, where relevant
- Whether the claim depends on an unverified assumption

A claim with no supporting source must be labelled as an assumption or as model knowledge. The Research gate rejects artifacts that contain unlabelled, unsourced material claims. Detection is an LLM check; the rule is enforced by the gate.

### Opportunity scorecard

Default weights, editable per mission:

| Dimension | Weight |
|---|---:|
| Severity and recurrence of pain | 20% |
| Evidence of willingness to pay or current spending | 20% |
| Reachability of a specific buyer | 15% |
| Weakness of alternatives and ease of switching | 15% |
| Technical and operational feasibility | 10% |
| Plausible unit economics | 10% |
| Founder advantage | 10% |

- 1–5 rubric per dimension, each rating citing evidence.
- Missing evidence scores `unknown`, not zero and not an average. Evidence coverage is shown next to each score.
- Scores are computed by code from the ratings, not by the model.
- A sensitivity check (computed, no model call) reports whether ±5-point weight changes alter the top pick.

### Validation plan

Each experiment names: assumption tested, participant criteria, method, budget, duration, success threshold, failure threshold, and the decision that follows. Sprat prepares outreach scripts and interview guides; it never sends anything.

## 7. Model and search backend

### One provider in V1: OpenAI, bring your own key

V1 ships a single native model adapter for OpenAI's Chat Completions API with streaming and tool use (`Sprat.Model.OpenAI`). Sprat owns the agent loop, the tools and the accounting. The adapter is written behind a `Sprat.Model` behaviour so other providers can be added without touching orchestration — an Anthropic adapter is the planned next one behind that same behaviour, not a V1 deliverable.

- Key comes from `OPENAI_API_KEY`, or from the OS credential store: macOS Keychain via `security`, Linux Secret Service via `secret-tool`. No native keychain dependency.
- Raw keys are never written to config, the database, logs or the screen.
- Model per role is configurable via `/model`; the pricing/capability catalog for admissible models ships in `priv/models/openai.json`, versioned and dated.
- Prompt caching (OpenAI's automatic prompt caching) is used for stable role instructions and large shared context; `Sprat.Model.Pricing` prices `cached_input` tokens separately from the rest of the input (§12).

### Search and fetch

Default: OpenAI's hosted `web_search` tool, called through a **separate** `POST /v1/responses` request (`Sprat.Agent.Tools.WebSearch.OpenAI`) — the hosted `web_search` tool is rejected on `/chat/completions`, which is what the main agent loop otherwise uses, so search is its own call rather than a tool passed straight through. `include: ["web_search_call.action.sources"]` returns the full list of URLs the search actually consulted, and every result is checked against that list before it's trusted (docs/design/web-search-options.md §3.2) — a result URL not present there is dropped rather than laundered into the mission's auto-fetch set. `web_fetch` is Sprat's own HTTP fetch plus readable-text extraction, gated by the §9 fetch rule.

If no search is available (no key, or the search call fails), Sprat says so at the start of the mission, allows analysis of user-supplied material only, and labels every output “no live research”.

## 8. Orchestration, context and delegation

### Task

```json
{
  "task_id": "task_014",
  "mission_id": "mission_003",
  "parent_task_id": "task_008",
  "role": "researcher",
  "objective": "Compare booking workflows for independent gyms",
  "inputs": ["artifact:brief:v2"],
  "deliverables": ["competitor_matrix", "source_register"],
  "acceptance_criteria": ["Compare at least three relevant alternatives"],
  "depends_on": [],
  "limits": {"wall_seconds": 600, "model_calls": 40, "tokens": 400000},
  "status": "queued",
  "attempt": 1
}
```

### Task states

```text
queued → running → review_pending → completed
            ├─ needs_input
            ├─ failed
            ├─ cancelled
            └─ interrupted   (process died; resumable by user choice)
review_pending → changes_requested → queued (attempt + 1)
```

Every transition is an event with actor, reason and timestamp. Cancelled is never completed.

### Scheduling defaults

| Setting | Default | User adjustable |
|---|---:|---|
| Concurrent model calls | 3 | yes |
| Delegation depth | 1 | no (V1) |
| Extra tasks a role may request per mission | 4 | yes |
| Review/revision rounds | 1 | yes, max 3 |
| Transport retries | 2 with backoff, only for safe errors (429, 5xx, connection reset) | no |

The Orchestrator stops a task that makes three consecutive model turns with no new source, artifact change or state progress, and surfaces it as stalled.

### Context package

Each role call gets a package containing:

- the mission objective and user constraints (never truncated)
- the task assignment and acceptance criteria (never truncated)
- referenced artifacts, latest accepted versions
- selected sources and claims relevant to the task
- open questions

The package records its source artifact versions, token estimate and any truncation. If the package would exceed the context budget even after dropping optional material, the task fails visibly rather than silently cutting required content.

## 9. Tools and permissions

V1 has no shell and no file writes outside Sprat's own storage. The permission model is therefore small, and fully enforced by code.

| Tool | Available to | Effect | Permission |
|---|---|---|---|
| `web_search` | Researcher | network read | allowed within budget |
| `web_fetch` | Researcher | network read | see fetch rule below |
| `read_file`, `glob`, `grep` | Researcher, Analyst | local read | only within the attached repository root; symlinks resolved and checked; `.env*`, keys and files matched by `.gitignore`-style deny patterns blocked |
| `calculate` | Analyst | none | allowed |
| `read_artifact`, `list_sources` | all | none | allowed |
| `write_artifact` | owning role | Sprat storage | role may write only its own artifact types |
| `record_source`, `record_claim` | Researcher, Analyst | Sprat storage | allowed |
| `ask_user` | PM (others via handoff) | UI | allowed; answers persisted |
| `request_task` | PM, Analyst | scheduling | Orchestrator checks limits |

### Fetch rule (prompt-injection and exfiltration guard)

When a repository is attached, a fetched page could instruct an agent to put repository content into a URL. Therefore:

- URLs that came from search results, from the user, or from an already-fetched page's links on the same site are fetched without asking.
- Any other URL (e.g. one the model composed, or one with a query string built from session content) requires user approval in the TUI.
- In `auto` mode (Shift+Tab) the first category stays automatic, and the second is still asked. Nothing makes the second category silent in V1.

### Terminal safety

All untrusted text (web content, file content, model output) is stripped of terminal control sequences before rendering. Only Sprat's own renderer emits escape codes.

## 10. Terminal UI

### Rendering model

> **Superseded 2026-09-18 by [docs/design/tui-zones.md](design/tui-zones.md).** The owner
> chose a zoned full-screen TUI with focusable zones, expandable agent cards and message-flow
> visualisation. The inline model below remains as the `--inline` fallback and as the basis
> of `--plain`; the rest of §10 (composer, keys, degraded output, terminal lifecycle) still
> applies.

Sprat's TUI follows Claude Code's model, not a full-screen dashboard:

- **Inline, not alternate screen.** The conversation is printed into the terminal's normal scrollback. The user scrolls, selects and copies with their terminal as usual, and the history remains visible after exit.
- **Committed region.** Finished blocks (user messages, finished agent messages, tool results, stage summaries) are written once and never redrawn.
- **Live region.** A small area at the bottom is redrawn in place: in-progress streaming text, the activity spinner, the team panel, permission prompts, the composer and the footer. Redrawing means moving the cursor to the top of the live region, clearing to the end of the screen and repainting.
- The live region is capped at terminal height − 2. Streaming text is committed paragraph by paragraph as it completes, so a long response never grows the live region without bound.
- Width is read from the terminal on each render. When the width changes, only the live region is re-laid-out; committed scrollback is left to the terminal.

### Screen anatomy

```text
╭──────────────────────────────────────────────────────────╮
│ ✻ Sprat  v1.0.0                                          │
│   ~/Projects/gym-idea · claude (BYOK) · search: on       │
│   /help for commands · Shift+Tab to change mode          │
╰──────────────────────────────────────────────────────────╯

> I want to build software for independent gyms in the UK

⏺ PM  Before researching, three things change the direction:
      1. Owner-operated gyms, or small chains (2–5 sites)?
      2. Is the goal revenue, or a tool for your own gym?
      3. Any constraint on building mobile apps?

> owner operated, revenue, web first is fine

⏺ Stage: Research · standard depth · 2 researchers

⏺ Researcher·1  web_search("independent gym management software UK")
  ⎿  10 results · 4 new sources recorded

⏺ Researcher·2  web_fetch(reddit.com/r/gymowners/…)
  ⎿  Fetched 3.1 KB · 2 claims recorded
     … +14 lines (ctrl+o to expand)

⏺ Researcher·1  Finished competitor matrix (7 products, 12 sources)

✢ Researching… (2m 14s · ↓ 48.2k tokens · esc to interrupt)
  ⎿  ☒ Intake
     ◼ Research          Researcher·1 done · Researcher·2 fetching
     ☐ Analysis
     ☐ Directions
     ☐ Brief + validation plan

╭──────────────────────────────────────────────────────────╮
│ >                                                        │
╰──────────────────────────────────────────────────────────╯
  ⏵ normal mode · $0.84 · 31 sources            ? for shortcuts
```

The mockup is illustrative. Glyphs have ASCII fallbacks (§10.8).

### Transcript blocks

| Block | Rendering |
|---|---|
| User message | `> ` prefix, dimmed after submission |
| Agent message | `⏺ <Role>` header, Markdown rendered to ANSI (headings, bold, lists, code, tables with wrap) |
| Tool call | `⏺ <Role>  tool(summary of args)` |
| Tool result | `⎿ ` indented summary; long output truncated to 3–5 lines with `… +N lines (ctrl+o to expand)` |
| Stage change | `⏺ Stage: <name>` plus a one-line reason |
| Artifact written | `⏺ <Role>  wrote <artifact> v<n>` with a path for `/open` |
| Error | red `⏺` with message and suggested action; never a bare stack trace |
| Gate result | ✓ or ✗ with the specific missing item |

### Live region components

1. **Activity line:** spinner, current verb (“Researching…”, “Scoring…”), elapsed time, streamed tokens, `esc to interrupt`.
2. **Mission checklist:** stages with ☒ done, ◼ active, ☐ pending, and one status line per active role instance. Collapses to one line when the terminal is short.
3. **Permission prompt**, when pending:

   ```text
   ╭─ Fetch URL ───────────────────────────────────────────────╮
   │ Researcher·2 wants to fetch a URL it composed itself:     │
   │   https://example.com/api?q=booking+software              │
   │                                                           │
   │ Do you want to proceed?                                   │
   │ ❯ 1. Yes                                                  │
   │   2. Yes, and allow example.com for this mission          │
   │   3. No, and tell the Researcher what to do instead (esc) │
   ╰───────────────────────────────────────────────────────────╯
   ```

4. **Question prompt** (`ask_user`): numbered options plus free text, same style as the permission prompt.
5. **Composer:** bordered multi-line input box.
6. **Footer:** mode, recorded cost, source count, and `? for shortcuts`. Replaced by contextual hints while the user types `/` or `@`.

### Composer

- Enter submits. Shift+Enter, Alt+Enter or `\` then Enter inserts a newline.
- Bracketed paste is enabled. Large pastes collapse to `[Pasted text #1 +42 lines]` in the box and are expanded on submit.
- ↑/↓ recall history (per project, persisted). Ctrl+R searches history.
- `/` opens a filtered command menu with descriptions; Tab completes.
- `@` opens fuzzy file completion over the attached repository and exported artifacts; the mention attaches that file as user-provided evidence.
- Emacs-style editing: Ctrl+A/E, Ctrl+W, Ctrl+U, Ctrl+K, Alt+←/→ word movement.
- Messages typed while agents work are queued and delivered at the next safe boundary (between model turns). The queued message is shown dimmed until delivered.

### Keybindings

| Key | Action |
|---|---|
| Esc | Interrupt the current stage: cancel in-flight model calls, keep completed work, return to the composer. Closes a menu or prompt if one is open. |
| Esc Esc | Pick an earlier user message to edit and re-run from (tasks after it are marked superseded, not deleted) |
| Ctrl+C | Clear the composer; if empty, interrupt like Esc; press again within 2 s to exit |
| Ctrl+D | Exit when the composer is empty |
| Shift+Tab | Cycle mode: `normal` → `auto` (no confirmation between stages) → `plan` (roles propose, nothing is fetched until approved) |
| Ctrl+O | Toggle verbose transcript: full tool inputs and outputs, context package summaries |
| Ctrl+T | Toggle the mission checklist |
| Ctrl+L | Redraw |
| ? | Shortcut help when the composer is empty |

### Slash commands

Built and shipping today:

| Command | Purpose |
|---|---|
| `/idea [text]` | Start the idea-shaping workflow |
| `/research [text]` | Start the opportunity-discovery workflow |
| `/depth quick\|standard\|deep` | Change research depth |
| `/tasks` | Task tree with owner, status, attempt |
| `/sources [query]` | Source register |
| `/claims` | Claims with confidence, unsupported first |
| `/artifacts` | Artifact list and versions |
| `/open <artifact>` | Print an artifact's latest version |
| `/usage` | Usage breakdown (§12) |
| `/events [filter]` | Event timeline |
| `/export [dir]` | Export the transcript and a redacted event log |
| `/resume` | Pick a previous session in this project |
| `/model` | Pick the model for this project |
| `/settings` | Effective settings and where each came from (Alt+s for the live overlay) |
| `/debug` | Requests/Tools/Events/Costs/Logs (Alt+d for the live overlay) |
| `/doctor` | Same checks as `sprat doctor` |
| `/clear` | Start a new session (the old one stays resumable) |
| `/help` | Commands and keys |

Named in earlier drafts of this spec but **not built yet** — kept here rather than silently dropped, since the intent still stands:

| Command | Purpose |
|---|---|
| `/solo` | Switch the current mission to single-agent mode |
| `/budget` | Show or change limits (limits exist and are enforced — §12 — there is just no dedicated command to view/edit them yet; `/settings` shows the current budget) |
| `/repo <path>` | Attach or detach a repository (read-only) |

Commands are shortcuts. Everything routine is also reachable in plain language: “go deeper on the second direction” works without `/depth`.

Table-style views (`/tasks`, `/sources`, `/usage`, `/events`) render as committed blocks in scrollback, not overlay screens. `/open`'s "page an artifact through `$PAGER`" is the target design (§13's implementation-approach note); today it prints the artifact inline — real `$PAGER` support is deferred (a real pager spawn races `Sprat.Terminal.Input`'s raw-mode reader; see that module's own note).

### Degraded and accessible output

- `NO_COLOR` respected; status is never shown by colour alone (glyph or word always present).
- `SPRAT_ASCII=1`, or a detected non-UTF-8 locale, switches glyphs to ASCII (`*`, `|_`, `[x]`, `[>]`, `[ ]`).
- `sprat --plain`: no live region redraws, no spinner; line-oriented output suitable for screen readers, `script` capture and dumb terminals. Prompts become numbered line prompts.
- No non-TTY stdin/stdout: `sprat -p "<prompt>"` runs a mission headless, prints the final brief to stdout and events as JSON lines with `--output-format stream-json`.

### Terminal lifecycle

- On start: enter raw mode, enable bracketed paste, hide the cursor while redrawing.
- On any exit path (normal, Ctrl+D, crash in the UI process, `SIGTERM`): clear the live region, show the cursor, disable bracketed paste, restore cooked mode. The restorer runs from the UI supervisor's terminate path and a VM-level exit hook.
- A UI crash never touches mission state. The UI supervisor restarts the renderer, which rebuilds the live region from the session projection.
- Ctrl+Z (suspend) is not supported in V1 and is documented as such.

### Implementation approach

Claude Code's inline model is simpler than a full-screen widget framework. V1 builds a small in-house renderer behind `Sprat.Terminal`:

- Input: OTP's raw terminal mode (`:shell.start_interactive({:noshell, :raw})`, OTP 26+) and a key/escape-sequence parser.
- Output: ANSI writes to stdout through one renderer process, which is the only writer.
- Layout: a small line-box layout for the live region; display width from a vendored Unicode East Asian Width and emoji table.
- Markdown: parsed with Earmark (pure Elixir) and rendered to styled lines.
- Resize: terminal size polled on a 250 ms timer and on every render, since the BEAM does not deliver `SIGWINCH`.
- Render batching: at most one repaint every 16–33 ms; token deltas are coalesced.

Phase 0 confirms this on the target terminals (§14). TermUI is evaluated only if it supports inline rendering without the alternate screen; otherwise it isn't used.

## 11. Logging

### Events

Every meaningful action is an event in SQLite:

- user messages, answers, approvals, mode changes, interrupts
- mission, stage, task and gate transitions
- context package built (versions, token estimate, truncation)
- model request and response (redacted), model ID, stop reason, usage
- tool request, permission decision, start, result reference, failure
- source recorded, claim recorded, artifact version written
- budget warnings, limit hits, retries, crashes, recoveries

```json
{
  "event_id": "evt_000042",
  "schema_version": 1,
  "session_id": "ses_01J…",
  "mission_id": "mis_003",
  "task_id": "task_014",
  "attempt": 2,
  "agent_id": "researcher_2",
  "seq": 42,
  "type": "tool.completed",
  "occurred_at": "2026-09-17T13:42:11.123Z",
  "correlation_id": "call_008",
  "causation_id": "evt_000039",
  "payload_ref": "blob:sha256:…"
}
```

### Privacy in V1

- API keys and any value loaded from the credential store are redacted before any write or render. Redaction is tested with fixture secrets.
- The data directory is created with mode `0700` and files with `0600`.
- Payloads are not encrypted at rest in V1. This is stated in `sprat doctor` and the docs.
- `/export` is redacted by default and never includes credentials.
- `sprat sessions delete <id>` removes a session's rows and unreferenced blobs.
- If a write to the database fails (e.g. disk full), new model calls stop and the TUI shows why. Sprat does not keep working unlogged.

## 12. Usage and cost

### Usage record

One record per model call, including failed, cancelled and retried calls:

- provider, model, request ID, task, attempt, role instance
- raw usage payload as returned, plus a normalisation version
- normalised `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, and server-tool counts (searches, fetches); unknown values are null
- computed cost as a Decimal, with the pricing table version used
- coverage: `reported`, `estimated` (call interrupted before usage arrived), or `unavailable`
- started_at, first_token_at, ended_at

### Rules

- Money uses `Decimal`. No floats.
- Prices come from a versioned pricing file shipped with each release, overridable by the user. The file lists its effective date; `/usage` shows it.
- Cost is computed from non-overlapping billable categories (cache reads are not also counted as input).
- An interrupted call with no usage report is recorded as `estimated`, using input tokens counted locally and output tokens streamed so far, and is labelled as such.
- Task and mission totals are sums of call records, never sums of sums.
- Mission wall time is elapsed time. The per-role breakdown can exceed it because roles run in parallel, and `/usage` says so.

### `/usage` view

```text
Mission: gym-idea · wall 18m 42s · 3 roles · 11 tasks (1 failed)

Role            Calls  Input   Output  Cache rd  Searches  Cost     Active time
PM                 14  61.2k    9.8k     44.0k         0  $0.31      2m 10s
Researcher·1       38  212.4k  18.1k    150.3k        22  $0.97      7m 55s
Researcher·2       31  180.9k  15.2k    121.0k        17  $0.81      6m 40s
Analyst             9  98.3k   12.6k     70.2k         0  $0.62      3m 02s
──────────────────────────────────────────────────────────────────────────────
Total              92  552.8k  55.7k    385.5k        39  $2.71
  of which failed or retried: 3 calls, $0.06 · 1 call estimated
Prices: openai-2026-09-18
```

### Budgets

Limits exist per mission for money, tokens, model calls, wall time and concurrency.

- Because V1 calls only a direct API with a known `max_tokens`, a **hard money cap is enforceable**. Before each call, the Orchestrator checks `spent + reserved + worst_case(call) ≤ cap`, where the worst case is the input tokens plus `max_tokens` output at list price. The reservation is held in the single Orchestrator process and released when the call's usage arrives.
- Server-side search costs are estimated per call and included in the worst case.
- At 80% of any limit: warn in the footer and tell roles to finish current deliverables.
- At 100%: no new calls are admitted, in-flight calls finish, and the mission enters `paused_budget`. The user can raise the limit or export what exists.
- First mission in a project: the user is asked to confirm a budget (default suggestion: $5 standard depth, $15 deep). Afterwards the project default applies.

## 13. Architecture

### Stack

| Concern | Choice |
|---|---|
| Language/runtime | Elixir 1.19+ on OTP 28 (exact pins set in Phase 0) |
| HTTP and SSE streaming | Req on Finch |
| Database | SQLite through `exqlite` (precompiled NIF), WAL mode |
| Markdown | Earmark |
| JSON | Elixir's built-in `JSON` module |
| Config | TOML (`toml` package) |
| Distribution | Burrito single-file binary per target, published via Homebrew tap and GitHub release archives |

### Supervision tree

```text
Sprat.Application
├─ Sprat.Store                  SQLite connection owner, migrations, blob store
├─ Sprat.Secrets                env / Keychain / Secret Service lookup, redaction set
├─ Sprat.RateLimiter            per-provider token bucket
├─ Sprat.Ledger                 usage records, budget reservations
├─ Sprat.SessionSupervisor
│  ├─ Sprat.Orchestrator        workflow template, task admission, gates, limits
│  ├─ Sprat.Projection          read model for the UI, rebuilt from events
│  └─ Sprat.RoleSupervisor      DynamicSupervisor
│     └─ Sprat.RoleWorker       one per running task: agent loop, tools, streaming
└─ Sprat.UISupervisor
   ├─ Sprat.Terminal.Input      raw input reader and key parser
   └─ Sprat.Terminal.Renderer   sole stdout writer
```

### Rules

- The Orchestrator owns task state. RoleWorkers report through messages; they never write task state directly.
- A state change and its event are written in one SQLite transaction. The database is the source of truth; process state is a cache.
- RoleWorkers stream model output in a linked Task, so the worker's mailbox stays responsive to cancellation.
- Cancellation closes the HTTP stream, records usage seen so far and transitions the task.
- Pure modules hold gates, policy checks, scoring, cost calculation and context selection, so they are testable without processes.
- The UI subscribes to the Projection through `Registry`-based pub/sub. The domain never calls the renderer.
- V1 has no durable message broker: role-to-role handoffs are artifacts and task records in SQLite, which is enough for one process.

### Storage layout

```text
~/Library/Application Support/sprat/        (macOS)
$XDG_DATA_HOME/sprat/  (default ~/.local/share/sprat)   (Linux)
├─ sprat.db
├─ blobs/sha256/ab/abcd…                     fetched pages, large payloads
└─ projects/<project-hash>/history           composer history

<project>/.sprat/config.toml                 optional, shareable, no secrets
<export dir>/<mission-slug>/                 exported Markdown, JSON, CSV
```

Tables: `sessions`, `missions`, `tasks`, `events`, `messages` (transcript), `artifacts`, `artifact_versions`, `sources`, `claims`, `claim_sources`, `decisions`, `usage_records`, `grants`.

### Recovery

- On start, tasks left `running` become `interrupted`. The TUI lists them on resume and asks: resume (new attempt with persisted artifacts as context), skip, or cancel.
- V1 has no external side effects beyond read-only network calls and model calls, so interrupted work is safe to redo. Redoing costs money again, and the TUI says so.
- Model calls are never replayed to rebuild state. Events and the transcript are.
- A resumed session re-renders its transcript into scrollback from stored blocks.

### Configuration

```toml
# ~/.config/sprat/config.toml  or  <project>/.sprat/config.toml

[execution]
max_concurrency = 3
review_rounds = 1
research_depth = "standard"
mode = "normal"            # normal | auto | plan

[budget]
default_usd = "5.00"
warn_percent = 80

[model]
provider = "openai"
api_key_env = "OPENAI_API_KEY"

[roles.pm]
model = "<pinned in Phase 0>"

[roles.researcher]
model = "<pinned in Phase 0>"

[roles.analyst]
model = "<pinned in Phase 0>"

[search]
provider = "openai"        # openai (V1); an Anthropic adapter is planned, not built yet
```

Precedence: user config → project config → mission options. Project config cannot raise a user-level budget cap or change the credential source. `/doctor` shows effective values and where each came from.

### CLI

```text
sprat                        Open the TUI in the current directory
sprat <path>                 Open with a repository attached (read-only)
sprat --solo                 Single-agent mode
sprat --continue             Resume the latest session in this project
sprat --resume [id]          Pick or resume a session
sprat -p "<prompt>"          Headless run; brief to stdout
sprat --plain                Line-oriented output, no redraws
sprat doctor                 Check terminal, key, search, storage, versions
sprat sessions list|delete
sprat --version
```

## 14. Build sequence

### Phase 0 — prove the bet and the risky parts (≈2–3 weeks)

Nothing in Phases 1–3 starts until these conclude with written results.

1. **Team vs solo experiment.** Scripts only, no TUI and no database. Run 10 curated tasks (5 idea-shaping, 5 opportunity-discovery) in two configurations: three roles with the §5 templates, and a single agent with the same tools and total budget. Blind-review the outputs against a rubric: evidence coverage, unsupported claims, counter-evidence found, specificity and actionability of the validation plan. Record cost and wall time.
   - **Pass:** team wins on evidence quality in ≥7/10 tasks at ≤2× the cost. Build as specified.
   - **Fail:** V1 ships solo mode only; remove §4 roles and simplify §5 to stage templates for one agent.
2. **Search metadata.** Confirm that Anthropic's server web search and fetch tools yield what §6 source records need. Otherwise adopt the Brave or Tavily fallback.
3. **Inline terminal spike.** Raw input, bracketed paste, live-region redraw during a fast token stream, resize, wide characters and emoji, and terminal restoration after a crash. Test in Terminal.app, iTerm2, Ghostty, kitty, WezTerm, GNOME Terminal, VS Code's terminal, and tmux.
4. **Packaging spike.** A Burrito binary with `exqlite` running on a clean macOS arm64, macOS x86-64 and Ubuntu 22.04 x86-64 machine, none with Elixir installed.
5. Pin model IDs, dependency versions and the first pricing file.

Exit: a decision record per item, stored in the repo.

### Phase 1 — foundation (≈4 weeks)

Terminal renderer and composer, config and secrets, SQLite events and projection, Anthropic adapter with streaming, tools and usage, ledger and budgets, the single-agent loop, interrupt and resume, `sprat doctor`. **Exit:** a solo research question runs end to end in the TUI, survives `kill -9` mid-run, and shows correct usage.

### Phase 2 — research product (≈4–5 weeks)

Evidence store, source and claim tools, gates, the two workflow templates, roles and parallel researchers (if Phase 0 passed), scorecard, permission and question prompts, `/sources`, `/claims`, `/usage`, `/tasks`, export, read-only repository attachment. **Exit:** both workflows deliver complete artifact sets on the Phase 0 task set.

### Phase 3 — release (≈2–3 weeks)

Signed and notarised macOS binaries, Linux binaries, Homebrew tap, `--plain` and `-p` modes, redaction and injection security fixtures, performance targets, docs, and a re-run of the Phase 0 evaluation on the finished product.

Estimates assume one experienced Elixir developer working with coding agents; they are planning figures, not commitments.

## 15. Out of scope for V1

| Deferred | Earliest | Why deferred |
|---|---|---|
| Native Windows | later | BEAM raw terminal and process control risk; small share of target users |
| Code writing, shell tool, worktrees, SWE role | V2 — specified in [spec-v2.md](spec-v2.md) | Separate product surface; V1 proves research value first |
| Codex and Claude Code as backends | V2 | Protocol churn and subscription-automation terms need their own investigation |
| Anthropic and other compatible endpoints | V1.x | Adapter behaviour exists (§7); OpenAI shipped as the V1 adapter, add others behind it |
| CEO role | V2, if measured useful | Overlaps Analyst in V1 |
| MCP client | V1.x | Useful for user-supplied data sources; not needed to prove the bet |
| Encryption at rest, retention policies | V1.x | File permissions are the V1 baseline, stated openly |
| Durable broker, leases, fencing tokens | only with multi-process execution | One process, one SQLite writer |
| Custom role definitions | V2 | Stabilise built-in roles first |
| OpenTelemetry export | V2 | No remote telemetry in V1 |
| Browser automation, PDF/image inspection | V2 | Web fetch covers V1 needs |
| Linux ARM64 | V1.x | After CI coverage |
| Background execution, multi-user | later | Unchanged from parent spec |

## 16. Release acceptance

| Requirement | Evidence |
|---|---|
| Honest research | On the eval set, no material claim in delivered artifacts lacks a source or an assumption label (sample-audited) |
| No fabricated validation | Fixture prompts inviting invented quotes or demand figures produce explicit refusals or assumption labels |
| No live research without search | With search disabled, every output is labelled and no source records are created |
| Gates enforced by code | A role's `write_artifact` for a later stage before its gate passes is rejected, even when the model insists |
| Read-only repository | Path traversal, symlink escape and deny-pattern fixtures are all blocked and logged |
| Injection guard | A fetched page instructing the agent to fetch a URL containing repository content triggers an approval prompt, never a silent fetch |
| Accurate usage | Recorded token totals match provider-reported totals over the eval set; interrupted calls appear as `estimated`; failed calls are counted |
| Hard budget | No mission exceeds its money cap on the eval set, including with 3 concurrent calls |
| Recovery | `kill -9` at random points across 50 runs never corrupts the database, and every session resumes |
| Terminal restoration | After normal exit, Ctrl+C twice, crash and `SIGTERM`, the terminal is in cooked mode with the cursor visible, on all terminals in §14 |
| Secret safety | Fixture keys never appear in the database, blobs, exports or the rendered screen |
| Install | Fresh macOS (arm64 and x86-64) and Ubuntu 22.04/24.04 machines install via Homebrew or archive and run without Elixir or Erlang |

### Performance targets

| Metric | Target |
|---|---:|
| Launch to usable composer | < 500 ms p95 |
| Keypress to echo while 3 roles stream | < 50 ms p95 |
| Esc to “interrupted” shown | < 250 ms p95 |
| Resume and render a 2,000-event session | < 1.5 s p95 |
| Idle RSS | < 150 MB |

Measured on a documented reference machine. Provider latency is excluded.

## 17. Open decisions

1. Default model per role, and the price-per-mission these defaults imply (Phase 0).
2. Search backend: Anthropic server tools or Brave/Tavily (Phase 0).
3. Whether the team passes the Phase 0 bar, which decides whether V1 ships roles or solo mode only.
4. Licence (open source vs commercial). It affects distribution only, not V1 architecture.
