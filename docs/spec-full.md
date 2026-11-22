# Sprat — Product and Technical Specification

Version: 0.1 — proposed build specification  
Prepared: 17 September 2026  
Product: Sprat  
Intended domain: sprat.dev  
Interface: terminal user interface only  
Core implementation: Elixir and OTP

## 1. Product definition

Sprat is a terminal-based product and software development agent. It takes an idea, a business question, or a repository task; researches the problem; delegates bounded work to specialist roles; shapes a plan; and, when implementation is within the user's requested scope, builds and verifies the result.

The user works with one product, Sprat, while seeing the work of a small agent team. The team includes Product Manager (PM), Software Engineer (SWE), CEO, Researcher, and Analyst. Roles have different responsibilities, context, tools, deliverables, and decision rights. They are not five personas taking turns in a shared chat.

Sprat can run its own agent loop using the user's API keys, delegate execution to locally installed coding agents, or combine both. Its orchestration, memory, logging, measurement, and TUI remain consistent across these execution methods.

Product promise: **Research the problem. Shape the product. Build with evidence.**

This document is a design proposal, not a description of an implemented product. Proposed commands, package identifiers, defaults, performance targets, and release gates must be validated during development. No application implementation is included.

## 2. Target users and scope

### Primary users

- Solo founders moving from an idea to a validated product direction and a working MVP.
- Independent developers who already pay for coding agents and want coordinated research, planning, implementation, and review.
- Small technical teams that need traceable decisions and visibility into AI usage.

### Core jobs

1. “I have an idea. Help me decide who it is for and what to build.”
2. “Research this industry and find a worthwhile product opportunity.”
3. “Implement this feature in my repository after understanding the code and constraints.”
4. “Compare possible approaches and explain the evidence behind your recommendation.”
5. “Show what every agent did, how long it took, and what it cost.”
6. “Resume yesterday's work without losing decisions, artifacts, or task ownership.”

### Product boundaries

- All Sprat interactions occur in the terminal. No web dashboard, desktop shell, hosted UI, or browser-based onboarding.
- Browser automation may be a tool used by agents. A provider's external login page is an authentication dependency, not Sprat's product UI; device-code authentication is preferred where available.
- The first release runs locally for one user. It does not require an account with Sprat or a cloud control plane.
- Local persistence is mandatory. Remote telemetry export is optional and disabled by default.
- Market research can identify hypotheses and validation opportunities. It cannot establish product–market fit from internet research alone.
- Distributed BEAM clustering, multi-user collaboration, and an agent marketplace are outside the first release.

## 3. Design principles

| Principle | Required behavior |
|---|---|
| Research before action | Inspect relevant evidence before proposing implementation. Code-writing capabilities remain unavailable until the research and planning gates pass. |
| Proportionate work | A typo fix needs a repository inspection, not a market report. A new product needs discovery before code. |
| Explicit delegation | Every assignment names its owner, inputs, deliverable, constraints, deadline, and budget. |
| User remains in control | Roles cannot enlarge the user's scope, spending authority, or permissions. |
| Backend independence | Role identity is independent of model, provider, and installed agent. |
| Observable execution | Every meaningful action has a durable event and an attributable outcome. |
| Honest measurement | Report missing data as unknown; never equate missing usage or subscription billing with zero cost. |
| Durable progress | Recover persisted workflow state without blindly replaying external actions. |
| Bounded autonomy | Limit active agents, delegation depth, review loops, retries, and spending. |
| Local by default | Store project knowledge and execution history on the user's machine. |

## 4. Role system and decision rights

The deterministic Orchestrator owns scheduling and enforcement. It is application code, not an LLM persona. The CEO role makes strategic recommendations; it does not control operating-system permissions or act as an unrestricted root agent.

| Role | Responsibility | Typical deliverables | Default capability boundary |
|---|---|---|---|
| PM | Frame the problem, understand the user, shape requirements, prioritize scope, check product acceptance | Product brief, PRD, user journeys, acceptance criteria, task proposals | Read repository and evidence; write planning artifacts; propose delegations |
| Researcher | Gather current evidence, inspect documentation, study competitors and customer workflows | Source register, research memo, competitor matrix, unresolved questions | Search, fetch, read files, read-only connectors; write research artifacts |
| Analyst | Challenge assumptions, compare options, assess evidence and economics, interpret results | Evidence assessment, opportunity scorecard, scenario model, tradeoff analysis | Read evidence; controlled calculations; write analysis artifacts |
| CEO | Decide strategic focus within user constraints; compare opportunity cost and recommend go, revise, validate, or stop | Decision memo, strategic recommendation, priority resolution | Read team artifacts; propose scope changes; no authority to grant permissions or increase budgets |
| SWE | Investigate feasibility, design changes, implement, test, and review | Technical design, patch, test evidence, review findings | Read-only during discovery; scoped repository tools during implementation |

### Role instances

- A role can have multiple instances, such as two Researchers studying different segments.
- A SWE reviewer is a distinct instance with a separate task and context from the author. It may use the same model, but that is not independent evidence by itself.
- Each instance has a role specification version, backend session, context manifest, task assignment, and lifecycle.
- Agents submit handoffs and delegation requests through a structured tool. Only the Orchestrator admits and schedules them.
- A role may disagree. The disagreement, evidence, and final decision remain in the decision log.
- Roles should provide concise decision rationales, not fabricated private reasoning transcripts.

### Default participation

Product discovery uses PM, Researcher, Analyst, and CEO, with SWE for feasibility. Feature work uses PM, SWE, and a reviewer; Researcher is added when external facts or unfamiliar technology matter. CEO participation is reserved for meaningful strategic tradeoffs.

An explicitly requested simple fix can use an investigating SWE and a reviewing SWE. Research still occurs, but unnecessary role ceremonies do not.

## 5. Workflows and phase gates

### Shared lifecycle

```text
Intake → Research → Analysis → Product shaping → Plan → Implementation → Verification → Delivery
            ↑          │              │           │          │                │
            └──────────┴──────────────┘           └──────────┴── bounded revision
```

Research-only requests end with a research delivery. Idea shaping ends with a product direction and validation plan. “Build this” may proceed through all stages within the original authorization. Missing material facts can put a stage into `needs_input`; independent work continues.

Each gate has machine-checkable required artifacts and a recorded decision. LLMs assess content; application code checks schema, references, permissions, budget, and state transitions.

| Gate | Required evidence | Outcome |
|---|---|---|
| Intake | Objective, request type, constraints, repository if relevant, budget policy | Choose workflow and research depth |
| Research | Research questions, inspected evidence, source register or repository references, limitations | Enough evidence to analyze, or identify the exact gap |
| Product | Target user, problem, alternatives, assumptions, proposed scope | Selected direction or a validation experiment |
| Implementation | Versioned plan, acceptance criteria, feasibility, task dependencies, authorized write scope | Issue scoped execution capabilities |
| Delivery | Acceptance results, reviewed diff or report, limitations, usage summary | Deliver, revise, or explicitly mark incomplete |

### A. Shape an idea

Example: “I want to build software for independent gyms.”

1. PM extracts the idea and asks only questions that materially change direction: customer, geography, constraints, and intended outcome.
2. Researcher studies existing workflows, competing products, user complaints, alternatives, and available evidence.
3. Analyst separates recurring problems from anecdotes and identifies the riskiest assumptions.
4. PM proposes three distinct product directions with target customer, problem, value, smallest useful scope, and validation approach.
5. SWE assesses technical feasibility and dependencies without writing application code.
6. CEO recommends a direction or additional validation and records tradeoffs.
7. PM delivers a product brief, assumption register, MVP boundary, and experiment backlog.

Brainstorming is iterative. The user can reject directions, combine ideas, or add constraints. New evidence produces new artifact versions; rejected alternatives remain available without polluting active context.

### B. Discover an industry opportunity

Example: “Find an underserved product opportunity in UK property maintenance.”

1. Establish industry, geography, likely buyer, founder advantages, distribution constraints, and research budget.
2. Research customer segments, workflows, existing spending, substitutes, switching barriers, and incumbent offerings.
3. Form five to ten initial opportunity hypotheses.
4. Analyst narrows these to three using explicit scoring and evidence quality.
5. Researcher tests the strongest assumptions and searches for contradictory evidence.
6. SWE evaluates the feasibility and dependencies of the finalists.
7. CEO recommends one opportunity, a different research direction, or no-go.
8. PM delivers a validation plan with interview questions, prototype scope, willingness-to-pay tests, and success/failure thresholds.

Do not manufacture interviews, customer quotes, demand, revenue estimates, or willingness to pay. Internet sources are not substitutes for observed customer behavior. Research output must say “promising hypothesis” when that is the strongest supported conclusion.

### C. Build or change software

1. Inspect repository instructions, working-tree state, architecture, tests, dependencies, and relevant implementation.
2. Investigate the problem and reproduce it when possible.
3. PM or the investigating SWE records acceptance criteria and scope.
4. SWE compares implementation approaches; conduct external documentation research when needed.
5. Orchestrator creates a dependency graph and assigns bounded implementation tasks.
6. SWE workers implement in isolated workspaces or under an exclusive write lease.
7. A reviewer checks the change against the plan, test evidence, and repository context.
8. PM verifies product acceptance when user behavior changed.
9. Deliver a diff, validation report, unresolved concerns, and usage summary. Commit, push, publication, and deployment follow the user's action permissions.

### Research depth

| Depth | Use | Expected artifact |
|---|---|---|
| Quick | Small local change or known problem | Inspected files, observations, concise approach |
| Standard | New feature or product shaping | Research memo, alternatives, risks, plan |
| Deep | Industry discovery or consequential architecture | Multiple workstreams, source register, counter-evidence, synthesis |

Depth is selected at intake and can be changed by the user. Prior evidence can satisfy a gate if the Orchestrator records its relevance and freshness. A stale report cannot silently authorize a materially different implementation.

## 6. Research quality and product validation

Every material external claim must link to an evidence record containing:

- Source URL and title, publisher, publication date if known, retrieval timestamp, and source type.
- A permitted excerpt or concise summary, plus content hash when a snapshot is retained.
- Supported claim, limitations, geography, and relevant customer segment.
- Whether the source is first-party marketing, independent reporting, documentation, customer testimony, or user-provided evidence.
- Confidence label with a short justification; no invented statistical confidence.
- Contradictory evidence and any dependency on an unverified assumption.

Fetched content is untrusted data. It cannot modify agent instructions, budgets, tool policy, or workflow state. Deduplicate syndicated stories and copied claims; ten repetitions of one assertion are not ten independent sources.

If search access is unavailable, show the missing capability, allow analysis of supplied evidence, and label the result accordingly. Never imply a live industry investigation occurred when the agent used model memory alone.

### Opportunity scorecard

Proposed weights, editable per mission:

| Dimension | Weight |
|---|---:|
| Severity and recurrence of pain | 20% |
| Evidence of willingness to pay or current spending | 20% |
| Reachability of a specific buyer | 15% |
| Weakness of alternatives and switching feasibility | 15% |
| Technical and operational feasibility | 10% |
| Plausible unit economics | 10% |
| Founder advantage | 10% |

Use a 1–5 rubric and cite evidence for each rating. Missing evidence is “unknown,” not zero and not an average guess. Show evidence coverage separately. Scores support comparison; they do not represent probability of product–market fit. Test whether modest changes in weights alter the recommendation.

Validation experiments specify the assumption, participant criteria, method, budget, duration, success threshold, failure threshold, and decision that follows. Outreach, paid advertising, purchases, and publication require applicable user authorization. Preparing those artifacts does not imply permission to send them.

## 7. Execution backends

### Two distinct contracts

**Model adapter:** Sprat owns the conversation loop, context assembly, tool calls, and role execution. The adapter supplies model inference through BYOK or a supported local endpoint.

**Agent adapter:** An installed agent owns its internal loop. Sprat supplies a task, workspace, context, permissions, and limits; consumes structured events; and reconciles the result.

These contracts must not be collapsed into a generic text completion function. An installed coding agent has its own tools, session state, approvals, and accounting behavior.

### Backend options

| Backend | Proposed integration | Important constraint |
|---|---|---|
| OpenAI BYOK | Native Elixir HTTP/streaming adapter to a supported API | Sprat owns tools and accounting normalization |
| Anthropic BYOK | Native Elixir HTTP/streaming adapter to a supported API | Provider-specific content, tool, cache, and usage semantics |
| Compatible API endpoint | Explicit capability profile plus conformance tests | “Compatible” does not guarantee tool or usage parity |
| Installed Codex | App Server over local stdio | Negotiate protocol and capabilities; preserve agent approvals |
| Installed Claude Code | Documented programmatic structured streams; version-tested permission bridge | Unsupported approval behavior must become a visible limitation, not a bypass |
| Other installed agents | ACP where supported, otherwise a documented adapter | No promise that arbitrary interactive CLIs can be safely automated |

Codex documents a structured App Server protocol with stdio transport, sessions, lifecycle events, approval flows, and token usage notifications. This makes it the preferred Codex integration boundary. [S1]

Claude Code documents programmatic execution, JSON streaming, session continuation, and permission controls. Sprat should integrate these documented interfaces and test the installed version; parsing its interactive screen is not the foundation. [S2]

ACP is an agent-client integration option; MCP is the tool/resource integration layer. They serve different purposes. [S3][S4]

### Authentication

- BYOK keys come from environment variables or an OS credential-store reference.
- Project configuration never contains raw API keys.
- Installed agents retain ownership of their supported login state. Sprat invokes supported interfaces rather than extracting credentials from private files or converting subscription credentials into API keys.
- Existing installed-agent access does not imply unlimited capacity, guaranteed automation eligibility, or identical billing across providers.
- A provider change that sends project data to a new service must be within the user's configured provider policy.

### Capability discovery

Each adapter reports supported versions and capabilities: streaming, resume, cancellation, mid-turn input, tool visibility, permission mediation, workspace restrictions, network restrictions, model selection, usage categories, cost reporting, output schema, nested-agent visibility, and platform support.

For each capability record `supported`, `unsupported`, or `unknown`, with a source and probe timestamp. Sprat's TUI shows the effective limitations before assigning a task.

Strict missions require enforceable restrictions and adequate event coverage. If an adapter cannot enforce a mission's read-only boundary, it is ineligible for that stage unless an independently tested sandbox supplies the boundary. A prompt saying “do not write” is not enforcement.

### Routing and fallback

- Select by role requirements, user preference, observed reliability, capability, context size, latency, and budget.
- Freeze the initial routing plan in the mission record; log all changes and reasons.
- Rate-limit per provider/account as well as globally. Multiple processes do not create more provider quota.
- Never silently fall back from subscription execution to billable API execution.
- On a backend switch, transfer an explicit context package and artifacts. Do not claim to migrate hidden internal state.
- Backend-native delegation is disabled where possible. If enabled, descendants count toward mission limits; opaque descendants are displayed as unobserved activity and are ineligible for strict per-agent accounting.

## 8. Delegation contract and scheduling

A delegation is a persisted task, not just a chat message.

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
  "scope": {"workspace": "research", "write": "artifacts_only"},
  "budget": {"usd_limit": "3.00", "wall_seconds": 600},
  "depth": 1,
  "status": "queued"
}
```

Values above are examples, not prescribed market-research quotas.

### Task state machine

```text
proposed → queued → running → review_pending → completed
                    │               │
                    ├─ waiting_input│
                    ├─ waiting_tool │
                    ├─ paused_budget│
                    ├─ failed       └─ changes_requested → queued (new attempt)
                    └─ cancelled
```

State transitions carry actor, reason, timestamps, attempt number, and event reference. Completed work must have accepted deliverables. Cancellation is not completion. Mission completion requires all required tasks accepted or explicitly removed from scope with a reason.

### Proposed scheduling defaults

- Maximum three concurrent inference/external-agent executions; cheaply idle BEAM processes are not counted as active model calls.
- Maximum delegation depth two below the coordinator.
- Maximum two review/revision rounds before surfacing the unresolved issue.
- One transient transport retry when safe; semantic rework is a separate attempt and budget item.
- One active owner per task, enforced using leases and fencing tokens.
- Parallelize independent research and disjoint engineering work. Execute dependencies sequentially.
- Detect cycles and refuse cyclic task graphs.
- Stop repetitive conversations that produce no new evidence, artifact change, or state progress.

The user can adjust defaults. Agents cannot raise them themselves.

## 9. Context, messages, and memory

Separate four information stores:

1. **Conversation:** user instructions, clarifications, visible agent responses.
2. **Project knowledge:** accepted facts, architecture notes, constraints, and decisions.
3. **Artifacts:** versioned reports, PRDs, plans, patches, and validation results.
4. **Execution history:** events, calls, tool activity, usage, retries, and failures.

Do not send the entire mission history to every agent. Assemble a role-specific context package containing the objective, relevant user constraints, assignment, selected evidence, artifact references, and unresolved questions.

Each package records source versions, token estimate, truncation/compaction decisions, and a hash. Compacted summaries reference their source events. Critical instructions and acceptance criteria cannot be silently dropped to fit a context window.

Internal messages have a versioned envelope with message ID, mission/task IDs, sender, recipient, type, payload reference, correlation ID, causation ID, creation time, expiry if applicable, and acknowledgment status.

Supported message types include `assignment`, `clarification`, `evidence`, `handoff`, `review`, `decision`, `status`, `cancel`, and `error`.

Cross-role communication uses the durable broker. Local process messaging delivers notifications, but the database holds authoritative state. Semantic delivery is at-least-once with deduplication; exactly-once external side effects are not promised.

Project knowledge is promoted from evidence or accepted decisions, never from an unverified agent claim. Cross-project memory is off by default.

## 10. Tools and execution permissions

“Tools like Claude Code” means comparable capability categories, not a guarantee of identical proprietary tools or behavior.

| Category | Required capability | Initial scope |
|---|---|---|
| Files | List, glob, read, search, apply patch, write within granted roots | V1 |
| Shell | Run bounded processes, stream stdout/stderr, timeout, cancel process tree | V1 |
| Repository | Status, diff, history, worktrees, tests, authorized commit operations | V1 |
| Research | Search provider, HTTP fetch, extract readable content, citations | V1 |
| Reasoning support | Controlled calculations, structured tables, comparison artifacts | V1 |
| Delegation | Assign, message, wait, cancel, review results | V1 |
| User interaction | Questions, permissions, choices, task steering | V1 |
| MCP | Tool discovery/calls and resource reads over supported transports | V1 |
| Browser | Headless browsing and page interaction through a tested adapter | Follow-up |
| Rich files | PDF/image inspection through capable providers or tool adapters | Follow-up |
| External services | Issue trackers, source hosting, documents, other MCP connectors | Installed explicitly |

Every tool has a stable identifier, schema version, input/output schema, timeout, effect classification, required permissions, cancellation behavior, idempotency behavior, and result-size limit.

### Permission model

Effective authority is the intersection of user policy, mission scope, phase policy, role policy, adapter capability, and tool policy. No role can expand that intersection.

- Research can write its own artifacts and bounded scratch data, but not application source.
- SWE write access is scoped to an assigned worktree or explicit workspace roots.
- Arbitrary shell commands are not classified as read-only by name alone. Shell evaluation, redirects, scripts, subprocesses, and network effects require enforcement at the appropriate boundary.
- User grants specify action, resources, lifetime, and applicable mission. Reuse valid grants without repetitive prompts.
- Permissions pending in an installed backend must surface in the TUI or fail visibly. Do not send blanket bypass flags to make an integration work.
- External messages, deployments, purchases, destructive repository actions, and writes outside the granted workspace require explicit applicable authority.
- Untrusted repository instructions and web content cannot override user policy.

For direct tools, use workspace validation plus a platform-specific process isolation backend. Record sandbox strength: `enforced`, `partial`, or `none`. File checks alone do not sandbox a general-purpose shell. A strict mission refuses execution when required isolation is unavailable.

Tool outputs are bounded in model context but retained according to log policy. Strip terminal control sequences before rendering untrusted output; do not let tool text execute terminal escape commands.

## 11. Elixir and OTP architecture

Elixir is chosen for concurrent coordination, message passing, process isolation, and supervision. Cheap BEAM processes make orchestration practical; they do not make model inference cheaper or accelerate CPU-intensive work automatically.

Use a modular Mix application initially. Avoid microservices and distributed Erlang in V1. Domain logic should remain usable independently of the terminal renderer.

```text
Sprat.Application
└─ RootSupervisor
   ├─ SettingsAndSecrets
   ├─ LocalStore
   ├─ DurableMessageBroker
   ├─ UsageLedger
   ├─ BudgetManager
   ├─ AgentRegistry
   ├─ ProviderRateLimiters
   ├─ ToolSupervisor
   ├─ SessionDynamicSupervisor
   │  └─ SessionSupervisor (one per open session)
   │     ├─ MissionCoordinator
   │     ├─ WorkspaceManager
   │     ├─ RoleDynamicSupervisor
   │     │  └─ RoleWorker (one per active assignment)
   │     └─ SessionProjection
   └─ TUISupervisor
      ├─ InputReader
      └─ Renderer
```

### Responsibilities

| Component | Responsibility |
|---|---|
| MissionCoordinator | Validate phase transitions, task dependencies, delegation and completion |
| RoleWorker | Manage one assignment's backend lifecycle; do not block on long work in callbacks |
| DurableMessageBroker | Persist message intents, acknowledgments, and delivery state |
| BudgetManager | Atomically reserve and settle budgets across concurrent tasks |
| UsageLedger | Normalize immutable usage records and maintain auditable totals |
| WorkspaceManager | Worktrees, write leases, base revisions, patches and reconciliation |
| LocalStore | SQLite events, materialized state and artifact metadata |
| ToolSupervisor | Isolated tool processes and controlled cancellation |
| SessionProjection | Read models for the TUI; rebuildable from durable state |
| Renderer | Terminal rendering only; no inference or repository mutation |

DynamicSupervisor is suitable for dynamically admitted workers. Its role is supervision, not durable job semantics; recovery must consult persisted task state. [S5]

### Process rules

- Use `GenServer` for stateful coordination, `Registry` for local lookup, and supervised tasks for bounded asynchronous work.
- Pure functions implement reducers, policy checks, validation, and cost calculations.
- Stream HTTP responses and child-process events through dedicated workers.
- Use bounded queues and admission control. BEAM mailboxes are not automatically bounded.
- Batch token deltas for rendering and persistence; retain every meaningful final event without blocking input on high-volume streams.
- Tool subprocesses use explicit argument arrays and controlled environments. Avoid shell interpolation of model output.
- Track operating-system process trees. BEAM worker termination alone is not a portable guarantee that all grandchildren stop.
- Core orchestration is Elixir. Minimal native helpers or runtime-specific adapters are allowed only when needed for terminal, process, sandbox, or provider interoperability, and must ship as explicit dependencies.

## 12. Terminal UI

### Layout

```text
 SPRAT  gym-idea     Research     2 active     $1.42 recorded + unknown usage
 ┌──────────────────────┬────────────────────────────────────────────────────┐
 │ Mission              │ Conversation / selected task                       │
 │ > Research           │ PM: Comparing three customer segments.             │
 │   Analysis           │ Researcher: Reviewing booking workflows.           │
 │   Shape              │ Analyst: Waiting for the competitor matrix.        │
 │   Plan               │                                                     │
 │   Build [locked]     │ Evidence: 8 sources, 2 unresolved claims            │
 │                      │                                                     │
 │ Roles                │                                                     │
 │ PM          active   │                                                     │
 │ Researcher  active   │                                                     │
 │ Analyst     waiting  │                                                     │
 ├──────────────────────┴────────────────────────────────────────────────────┤
 │ > Add context, steer the task, or enter /help                              │
 └───────────────────────────────────────────────────────────────────────────┘
 Tasks   Evidence   Artifacts   Diff   Usage   Events   Settings
```

This wireframe is illustrative. The implementation must adapt to terminal size rather than assume a fixed grid.

### Required views

- **Mission:** objective, phase, plan, active work, blockers, remaining budget.
- **Conversation:** user input and concise team updates; detailed activity expands on demand.
- **Tasks:** dependency tree, owner, backend, attempt, status, elapsed time, deliverable.
- **Evidence:** sources, claims, contradictions, freshness and gaps.
- **Artifacts:** versioned Markdown documents and structured reports, with export.
- **Diff:** per-task and combined changes, base revision, review status and test evidence.
- **Usage:** measured and estimated cost, unknown coverage, tokens, wall time, per-role/per-backend breakdown.
- **Events:** searchable timeline with filters and drill-down to tool requests and results.
- **Permissions:** concrete pending action, scope, reason, and allowed decision duration.
- **Settings:** backends, credentials references, role mappings, tools, budgets, storage and retention.

### Interaction

- Keyboard-first; mouse optional. Focus order and shortcuts are discoverable in `/help`.
- Multi-line composer, paste handling, searchable history, scrolling, and accessible non-color status indicators.
- `Ctrl+C` requests cancellation of active work and shows status; forced exit is a distinct second action. Pending OS processes must be reconciled on the next launch.
- User steering is persisted immediately, marks relevant artifacts stale when scope changes, and reaches agents at supported safe boundaries.
- Pause stops new scheduling. Already-running provider requests are cancelled where supported, otherwise drained with visible status.
- Escape closes overlays without accidentally cancelling a mission.
- Below 80×24, use a compact single-pane layout. Support plain output for screen readers and terminals without advanced capabilities.
- No required images, sixel support, Nerd Fonts, animation, or browser UI.

### Proposed commands

```text
sprat                         Open the TUI
sprat /path/to/repository      Open the TUI with a repository
sprat resume <session-id>      Resume a saved session
sprat doctor                  Check terminal, backends, tools and storage
sprat --version               Print installed version
```

Inside the TUI: `/idea`, `/research`, `/plan`, `/build`, `/roles`, `/tasks`, `/tools`, `/models`, `/budget`, `/usage`, `/sources`, `/diff`, `/pause`, `/resume`, `/cancel`, `/export`, `/settings`, and `/help`.

These are navigation conveniences, not a substitute for natural-language requests. Routine work should not require memorizing commands.

### Renderer decision

Evaluate TermUI behind `Sprat.Terminal` as the initial candidate. Its documentation describes an Elixir TUI framework with OTP integration and Windows terminal support. Treat that as a candidate capability, not validated Sprat compatibility. [S6]

Before committing, run a compatibility spike on macOS, Linux, and native Windows covering Unicode width, resize, paste, input latency, terminal restoration, long streams, and subprocess coexistence. Pin a tested release; do not select an untested release candidate solely because it is newest. If the framework fails, replace the renderer behind the boundary without rewriting orchestration.

## 13. Logging: what “everything” means

Log every observable, meaningful application event and all execution evidence available through supported interfaces. This does not mean capturing unavailable model internals, logging passwords, or promising visibility into opaque backend activity.

### Required events

- User submissions, steering, decisions and grants.
- Mission/task/role lifecycle transitions and assignments.
- Cross-role messages, context packages and artifact versions.
- Model requests and responses after redaction, model identity and provider metadata.
- Tool request, authorization, start, output references, completion and failure.
- Research source retrieval and claim attribution.
- Backend startup, version, capability negotiation, disconnect and resume.
- Usage reports, estimates, budget reservations, settlements and exhaustion.
- Retries, timeouts, crashes, recovery decisions and cancellation.
- Workspace bases, diffs, commits if authorized, and integration results.

### Event envelope

```json
{
  "event_id": "evt_000042",
  "schema_version": 1,
  "session_id": "session_001",
  "mission_id": "mission_003",
  "task_id": "task_014",
  "attempt_id": "attempt_002",
  "agent_id": "researcher_02",
  "sequence": 42,
  "type": "tool.completed",
  "occurred_at": "2026-09-17T13:42:11.123Z",
  "recorded_at": "2026-09-17T13:42:11.127Z",
  "correlation_id": "call_008",
  "causation_id": "evt_000039",
  "payload_ref": "artifact:tool-output:sha256-example",
  "redaction_applied": true
}
```

Persist action intent before executing a side effect, then record the result. If completion is uncertain after a crash, mark it `outcome_unknown` and reconcile before retrying.

### Privacy and retention

- Redact secrets before any persistent sink, debug logger, telemetry exporter, or TUI stream. Preserve the fact of redaction.
- Store sensitive payloads encrypted using an OS-backed or user-unlocked key. If unavailable, use a clearly identified metadata-only mode rather than silently storing sensitive bodies in plaintext.
- Allow project-specific exclusions and retention periods. Metadata is retained until session deletion; a proposed default for large payload retention is 30 days.
- Retention deletion leaves a tombstone with timestamps and reason. After deletion, full payload replay is unavailable and the UI must say so.
- Export is redacted by default and excludes credentials and authentication state.
- Operational logs are append-only during normal operation, not advertised as tamper-proof against a user with local database access.
- Disk-full and write failures pause new externally effective work; do not continue an unlogged mission silently.

## 14. Measurement and cost accounting

### Measurement dimensions

| Area | Metrics |
|---|---|
| Timing | Queued, started and ended timestamps; wall duration; active inference time; tool time; approval wait; retry delay; time to first token |
| Tokens | Input, output, cache-read, cache-write, reasoning where separately exposed, context size, compaction usage |
| Cost | Provider-reported cost, computed API estimate, tool fees, unknown cost, budget reservation and remaining allowance |
| Delegation | Tasks created/completed, depth, concurrency, handoffs, review rounds, failed assignments |
| Reliability | Errors, retries, timeouts, disconnects, recovery events, orphan processes, schema failures |
| Tools | Calls, duration, exit status, output size, blocked actions, cancellation latency |
| Research | Sources inspected, independent evidence coverage, unsupported claims, contradictions, stale sources |
| Engineering | Acceptance criteria passed, tests run, failed checks, review findings, changed files, rework |
| Runtime | BEAM memory, process count, mailbox pressure, scheduler load, database latency, render/input latency |

Use UTC timestamps for records and monotonic clocks for elapsed durations within a process lifetime. After restart, reconstruct duration from persisted intervals; never subtract monotonic values across boots.

### Usage ledger semantics

Each usage record includes provider, model, backend/version, request/session identifiers, task/attempt attribution, raw usage fields, normalized fields, measurement source, billing basis, pricing version, currency, and coverage status.

Coverage is `reported`, `estimated`, `partial`, or `unavailable`. Unknown numerical fields are null, not zero.

- Use Decimal or fixed-point integers for money; do not accumulate currency in floating point.
- Compute costs from non-overlapping billable categories. Cache and reasoning categories may already be included in provider totals; adapters must normalize without double counting.
- Preserve the original provider payload and normalization version.
- Deduplicate incremental and final usage reports. Cumulative session totals require deltas and reset detection.
- Reconcile late final usage after cancellation or disconnect.
- Parent task totals aggregate leaf ledger entries; do not sum a parent's inclusive total and its children again.
- Include failed attempts, abandoned research, compaction and retries in cost.
- Mission wall time is elapsed time; summed worker durations can exceed it because of concurrency.

For subscriptions, show token/quota data when available and label direct monetary cost as unavailable or subscription-based. An optional API-equivalent estimate is separate from actual billing and must not be presented as the user's charge.

Example: `API estimate $2.31 · subscription activity present · 18,420 reported tokens · 1 backend with unknown usage`. A mixed mission must not show $2.31 as a complete total.

### Budget enforcement

Budgets can be set for money, tokens, wall time, model calls, tool calls, active workers, and delegation depth.

Before a billable operation, reserve its estimated upper bound atomically against all relevant budgets. Settle when actual or revised usage arrives. Release unused reservation. Keep in-flight uncertainty visible.

Hard money caps are available only when call bounds and pricing are sufficiently known. Otherwise offer a soft money target plus hard time/call/concurrency limits. Never advertise a guaranteed monetary ceiling for an opaque installed agent.

At 80% of a budget, warn and prefer finishing current deliverables. At 100%, stop new admissions and cancel safely where possible. Already-running requests may still incur charges; show this explicitly. A CEO recommendation cannot raise the cap.

Instrument domain operations with Telemetry and optionally export traces through an OpenTelemetry integration. Telemetry handlers should hand off expensive work rather than block emitters. [S7]

## 15. Persistence and artifact model

Use SQLite on a local filesystem for the first release, with transactional event insertion, materialized state, a durable outbox, and full-text search where practical. Large payloads live in content-addressed files with database metadata.

Proposed entities:

| Entity | Key contents |
|---|---|
| sessions | Project reference, creation time, settings snapshot, last activity |
| missions | Objective, workflow, phase, status, budget policy |
| tasks / attempts | Dependencies, role, ownership lease, acceptance, state |
| agent_instances | Role/backend versions, session handles, capability snapshot |
| messages / outbox | Envelope, payload, delivery/acknowledgment state |
| events | Ordered, versioned audit records |
| artifacts / versions | Type, path/hash, author, sources, acceptance, superseded state |
| evidence / claims | Sources, dates, confidence, support and contradiction links |
| decisions | Alternatives, selected outcome, rationale, authority |
| tool_calls | Inputs, permission decision, execution and result references |
| usage_records | Original and normalized usage, pricing snapshot, coverage |
| budget_reservations | Held, settled, released and uncertain amounts |
| workspaces | Repository, base revision, worktree, ownership and patch status |
| grants | Scope, decision, issuer, expiry and revocation |

Store user configuration and session data in platform-appropriate application directories, with overrides documented. Repository-local `.sprat/config.toml` contains shareable non-secret settings. Mission artifacts can be exported into a chosen directory; operational logs remain outside version control by default.

Use transactions to update authoritative task state and its event/outbox together. Write and sync a payload before committing a reference to it; garbage-collect orphaned blobs later. Backups must use a database-consistent snapshot rather than copying a live database file carelessly.

The database is authoritative. JSONL is an export format, not a second independently updated source of truth.

## 16. Reliability, recovery, and concurrent editing

### Recovery rules

- On startup, detect incomplete attempts, held budgets, pending messages, workspace leases and orphan child processes.
- Resume a backend session only when supported and verified; otherwise create a new attempt using persisted artifacts and explicit recovery context.
- Never restart a completed task because its worker exited.
- Retry safe reads with bounded backoff. Retry writes only with idempotency guarantees or after reconciliation.
- Inference replay may incur fresh cost and produce different results. Event replay reconstructs state without calling a model.
- Circuit-break a failing backend and offer an authorized fallback.
- TUI failures must not corrupt mission state. Restore the terminal where possible and recover from persisted state on relaunch.
- V1 is foreground execution. Terminal close or machine sleep can interrupt work; no background-service guarantee is implied. Recovery is required.

### Workspace rules

- Inspect and record uncommitted user changes before work begins.
- Prefer one worktree per independent write task, pinned to an explicit base revision. Do not lose user changes when choosing that base.
- If worktrees are unsuitable, enforce a single writer to the shared workspace.
- Record file preconditions and content hashes before applying patches.
- Integrate completed branches sequentially, rerun relevant checks on the combined result, and review integration conflicts.
- Preserve unsuccessful worktrees for inspection; cleanup is explicit or governed by a user-selected retention policy.
- Never automatically reset, clean, overwrite, or stash user work to simplify recovery.

## 17. Configuration and extensibility

Illustrative configuration; field names are proposed:

```toml
[execution]
max_concurrency = 3
max_delegation_depth = 2
max_review_rounds = 2
research_depth = "standard"

[budgets]
mode = "ask_on_first_mission"
warn_percent = 80
unknown_cost_policy = "require_time_and_call_limits"

[backends.codex_local]
kind = "installed_agent"
adapter = "codex_app_server"
executable = "codex"

[backends.claude_local]
kind = "installed_agent"
adapter = "claude_code"
executable = "claude"

[backends.api_primary]
kind = "model"
adapter = "openai"
api_key_env = "OPENAI_API_KEY"
# Set an explicit supported model during setup.

[roles.pm]
backend = "api_primary"

[roles.researcher]
backend = "api_primary"

[roles.analyst]
backend = "api_primary"

[roles.ceo]
backend = "api_primary"

[roles.swe]
backend = "codex_local"

[logging]
redact_secrets = true
payload_retention_days = 30
remote_export = false
```

Settings precedence: organization policy if configured → user policy → trusted project settings → mission options. More specific configuration cannot enlarge a higher-level restriction. Display effective settings and their origins.

Custom role definitions are versioned data with prompt, output schema, capability requests and limits. They cannot inject application code. External tools use explicit MCP or subprocess adapters with declared permissions. Arbitrary downloaded Elixir modules are not a V1 plugin mechanism.

## 18. Installation and platform support

Ship target-specific releases containing the Erlang runtime and Sprat application. End users should not need Elixir, Erlang, Mix, a compiler, or Node.js for the core application. Installed-agent dependencies remain the user's chosen backend dependencies.

Elixir releases must match the target OS, architecture and ABI, including native dependencies. A release assembled on macOS is not automatically a Windows or Linux release. [S8]

### Packaging targets

| Platform | Distribution | Initial support target |
|---|---|---|
| macOS Apple Silicon | Homebrew tap and signed archive | V1 |
| macOS Intel | Homebrew tap and signed archive | V1 if CI coverage and dependency support pass |
| Linux x86-64 | Homebrew/Linuxbrew and archive for a documented glibc baseline | V1 |
| Windows x86-64 | Signed installer through WinGet; portable package where practical | V1 |
| Linux ARM64 / Windows ARM64 | Additional native artifacts | After dedicated validation |

Native Windows support is a release requirement, not a synonym for WSL support. WSL can be documented separately as a Linux environment.

Proposed future installation experience:

```text
brew install <sprat-owner>/tap/sprat
winget install --id <SpratPublisher>.Sprat --exact
```

Publisher, tap and package names must be chosen and registered. These commands are not available now. Use a maintained Homebrew tap initially; do not assume Homebrew core acceptance. WinGet requires a valid manifest and package submission. [S9][S10]

### First run

1. Check terminal capabilities, writable application storage, and installed backend executables.
2. Let the user choose BYOK, installed agents, or a mixture.
3. Authenticate through supported provider mechanisms and test connectivity.
4. Discover tools and show missing research capabilities.
5. Choose role mappings, budget policy, project write scope and logging retention.
6. Start a mission or open an existing repository.

`sprat doctor` reports backend versions, supported features, search availability, credential-store state, sandbox support, Git/worktree capability, storage health, and platform limitations without printing secrets.

Updates go through the selected package manager. Database migrations require a backup and tested upgrade path. Downgrades must detect incompatible data rather than corrupt it. Uninstall preserves user data unless deletion is explicitly selected.

## 19. Delivery artifacts

Every completed mission delivers an appropriate subset of:

- Research brief and source register.
- Opportunity comparison and counter-evidence.
- Product brief, PRD, user journeys and MVP scope.
- Validation experiments and interview guide.
- Technical design and recorded decisions.
- Task graph and implementation plan.
- Code diff and review findings.
- Acceptance and test report.
- Usage and cost report, including unknown coverage.
- Session event export.

Markdown is the default human-readable format. JSON preserves structured data; CSV supports usage analysis. Exported documents include mission ID, generation date, source references, version and known limitations. The user can export from the TUI without copying text manually.

## 20. Verification and release acceptance

### Requirement traceability

| Requirement | Acceptance evidence |
|---|---|
| Research first | An implementation tool request before the plan gate is denied even if an LLM asks directly |
| Role delegation | A discovery fixture produces traceable assignments and handoffs across PM, Researcher, Analyst and CEO; SWE participates in feasibility |
| BYOK | A clean install completes a tool-using mission through a configured API without an installed coding agent |
| Installed agents | Supported Codex and Claude Code versions complete real fixture tasks through structured adapters, including denied permissions and cancellation |
| Product shaping | A vague idea produces alternatives, a selected direction, assumptions and measurable validation steps without unauthorized code writes |
| Industry discovery | A mission yields sourced opportunities, counter-evidence, buyer/distribution analysis and an honest PMF limitation |
| TUI only | Setup, work, permissions, review, usage and export are operable entirely in the terminal |
| Elixir orchestration | Supervised workers exchange durable messages and recover after injected process failures |
| Comprehensive logs | Each tested action links intent, permission, execution and result; deliberate secret fixtures never appear in persistent outputs |
| Measurement | Concurrent usage reconciles without double counting; missing usage remains unknown; failed attempts count |
| Installation | Fresh macOS, Linux and native Windows machines can install and launch without an Elixir toolchain |
| Tool access | File, shell, search/fetch, Git and MCP fixtures enforce scope and produce attributable events |

### Testing approach

- Unit tests for policy intersections, state transitions, cost normalization, context selection and scoring.
- Property tests for task ownership, acyclic graphs, budget reservations, event ordering and message deduplication.
- Adapter contract fixtures for partial streams, malformed events, cumulative usage, unsupported features, late final usage and reconnects.
- Small live integration tests against explicitly supported backend versions with capped spending; do not treat mocked tests as protocol compatibility proof.
- Fault injection at action-intent persistence, tool execution, result persistence, budget settlement and artifact commit boundaries.
- TUI snapshot and real-terminal tests for narrow layouts, Unicode, resize, paste, screen-reader mode and terminal restoration.
- Platform tests for subprocess trees, path quoting, filesystem permissions, credential storage and installation.
- Security fixtures for malicious retrieved instructions, path traversal, symlink escape, terminal escape sequences and secret leakage.

### Proposed performance targets

Measured on a documented reference machine and representative persisted session:

| Metric | Target |
|---|---:|
| Launch to usable TUI, without network checks blocking | Under 2 seconds p95 |
| Input-to-render latency during streaming | Under 100 ms p95 |
| Local cancellation acknowledgment | Under 250 ms p95 |
| Local tool process-tree termination | Under 3 seconds, or visible failure with recovery action |
| Event durability acknowledgment under normal load | Under 100 ms p95 |
| Idle core memory, excluding external agents/models | Under 200 MB RSS |
| Recover and show a 10,000-event session | Under 3 seconds p95 |

These are acceptance targets, not current benchmark results. Provider latency and remote cancellation are measured separately and cannot be guaranteed by Sprat.

### Product evaluation

Compare Sprat against a single-agent baseline on a curated mix of bug fixes, feature tasks and product discovery exercises. Track acceptance rate, reviewer-assessed evidence quality, unsupported claims, user interventions, elapsed time and cost per accepted outcome. Delegation should earn its additional cost. If a role adds no measurable benefit on a task class, simplify that workflow.

## 21. Build sequence

### Phase 0 — feasibility and architecture decisions

No broad implementation until these bounded investigations conclude:

1. Validate terminal input/rendering on native Windows, macOS and Linux.
2. Prove Codex and Claude Code structured integration, approvals, cancellation, resume and observable usage using minimal fixtures.
3. Validate native process-tree control, runtime packaging and SQLite dependencies.
4. Establish a direct BYOK tool-call loop with normalized usage.
5. Record supported/unsupported capabilities and select pinned dependency versions.

Exit: written decision records and reproducible fixture results. Failed assumptions revise the spec; they do not become hidden limitations.

### Phase 1 — durable foundation

TUI shell, configuration, secrets, SQLite/event model, direct model adapter, basic tools, logging, budgets, cancellation and recovery. Validate one small mission end-to-end.

### Phase 2 — research and product workflows

Role contracts, research gates, evidence store, idea shaping, opportunity analysis, decision memos and Markdown export. Deliver useful research without requiring code generation.

### Phase 3 — installed agents and engineering

Codex and Claude Code adapters, capability-aware routing, SWE tasks, isolated workspaces, review, verification and mixed-backend usage reporting.

### Phase 4 — release readiness

Native platform packages, upgrade tests, failure recovery, secret/redaction tests, accessibility, performance and workflow evaluation. V1 is not complete until both installed-agent integrations and native Windows acceptance pass.

### Subsequent releases

Generic ACP adapters, headless browser tools, richer file inspection, optional local model profiles, additional architectures, opt-in trace export, and only then background execution or multi-user coordination.

## 22. Decisions and remaining investigations

### Recommended decisions

- Build one local Elixir application with OTP workers and durable coordination.
- Separate direct model adapters from installed-agent adapters.
- Use explicit role contracts and deterministic phase/capability gates.
- Use SQLite plus versioned artifacts as the local source of truth.
- Start with a small concurrency limit and measure whether additional delegation improves outcomes.
- Use TermUI as a candidate behind an interface, contingent on native Windows validation.
- Package bundled-runtime releases through Homebrew and WinGet.
- Make research and idea shaping complete products, not merely preludes to code.

### Investigations that can change implementation choices

- Exact supported backend versions and permission-bridge behavior.
- Native Windows renderer, process control and sandbox implementation.
- Direct API model and search-provider defaults, chosen from current capability and cost tests.
- Encryption/key-store dependencies across all release platforms.
- Licensing and distribution compatibility of selected libraries and native helpers.
- Package publisher identity and release signing setup.

### Business choices outside this technical specification

Open-source versus commercial licensing, pricing, team features, hosted services, and external analytics are not yet selected. The V1 architecture must work locally without requiring those choices.

## 23. Research sources

Sources were inspected on 17 September 2026. Protocols and package capabilities may change. The proposed system design, defaults and acceptance targets above are Sprat recommendations, not claims made by these sources.

- **[S1]** [Codex App Server](https://learn.chatgpt.com/docs/app-server) — structured agent integration, transport, lifecycle, approvals and usage notifications.
- **[S2]** [Run Claude Code programmatically](https://code.claude.com/docs/en/headless) — programmatic output, sessions and permission behavior.
- **[S3]** [Agent Client Protocol overview](https://agentclientprotocol.com/protocol/v1/overview) — agent-client protocol boundary.
- **[S4]** [Model Context Protocol architecture](https://modelcontextprotocol.io/specification/2025-06-18/architecture) — host/client/server organization for tools and resources; this is a versioned reference, not a claim that it is the newest revision.
- **[S5]** [Elixir DynamicSupervisor](https://elixir.hexdocs.pm/DynamicSupervisor.html) — dynamically supervised processes.
- **[S6]** [TermUI documentation](https://term-ui.hexdocs.pm/readme.html) — candidate Elixir terminal framework; documentation claims require platform verification.
- **[S7]** [Telemetry documentation](https://telemetry.hexdocs.pm/telemetry.html) — application event instrumentation.
- **[S8]** [Mix release documentation](https://mix.hexdocs.pm/Mix.Tasks.Release.html) — bundled releases, target compatibility and deployment requirements.
- **[S9]** [Homebrew Formula Cookbook](https://docs.brew.sh/Formula-Cookbook) and [Bottles](https://docs.brew.sh/Bottles) — formula and binary distribution mechanisms.
- **[S10]** [WinGet package manifests](https://learn.microsoft.com/en-us/windows/package-manager/package/manifest) — Windows package definition and submission requirements.

---

Sprat V1 is successful when a user can install it, connect their existing models or agents, give it an idea or coding task, watch a bounded team research and act, inspect the evidence and changes, and export both the result and an honest account of the work.
