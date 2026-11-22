# Fleet layer — direction record

Date: 2026-09-18
Status: direction recorded; not scheduled, not specified
Scope impact on V1: **none**

## Ruling

V1's scope, as written in `spec-v1.md`, does not change. The fleet layer is a
level **above** it, built after V1 ships. This document exists so the direction
is not lost and so V1 does not accidentally make it expensive.

## The problem

A developer has ten repositories in active development, each with a coding
agent running in its own terminal. Multiplexing them is a solved problem. What
is not solved is attention: which of the ten needs a decision right now, which
is stuck, which is burning money, and which can be left alone. The cost is
context-switching, and it grows with the number of projects.

The gap is an **attention router**, not a terminal manager.

## What the layer is

One supervisor process holding N project entries. Each entry is a supervised
piece of work — a Sprat session, or an external coding-agent session behind an
adapter. Above them:

- an aggregate read model across all projects
- a ranked attention queue: what needs the user, and why
- a local dashboard for the overview, with the ability to drop into any one
  project and steer it
- aggregate spend across projects, on top of the per-mission caps

The dashboard is served by the Sprat binary on `localhost`. It is not a hosted
service, and it does not change the local-only, BYOK, no-telemetry promise in
`spec-v1.md` §2. "Dashboard" and "cloud" are separable and stay separated.

## The layering rule

**The fleet layer depends on V1. V1 never depends on the fleet layer.**

It consumes events and projections V1 already produces; V1 does not know it
exists. This is testable: if a change to `Sprat.Orchestrator` is ever needed to
make the dashboard work, the layering has broken and the scope has moved.

## What V1 must keep true

None of these cost V1 any time. They are rules already written down; the point
is that they stay true when the code is written.

| Guardrail | Where it already lives |
|---|---|
| Never assume a single active session | §13 — `SessionSupervisor` supervises sessions; it is not a singleton |
| `Projection` stays renderer-agnostic | §13 — "The UI subscribes to the Projection through `Registry`-based pub/sub. The domain never calls the renderer." A second UI subscribes the same way |
| Task states stay honest and complete | §8 — `needs_input`, `review_pending`, `failed`, `interrupted`, plus stalled detection. These are V1's correctness mechanism and the fleet layer's attention signals, unchanged |
| Agent sessions are not model calls | `spec-full.md` §9 — an installed coding agent "has its own tools, session state, approvals, and accounting behavior" and must not be collapsed into a text-completion function. The fleet adapter is its own behaviour, not a `Sprat.Model` |
| Headless drive-from-outside keeps working | §10 — `sprat -p` with `--output-format stream-json` |
| State stays project-scoped | §13 — `projects/<project-hash>/` |

## Decisions taken

| Question | Ruling |
|---|---|
| Supervise existing agents, or build our own? | **Supervise first, own agent later.** Wrap what the user already runs to prove attention-routing cheaply; keep the option to bring the agent in-house if the orchestration layer is what people value |
| What happens to the research product? | **Ship V1 first.** The fleet layer is V2, built on the proven engine |

## Open questions

1. **Supervision mechanism, and its terms.** Driving an installed coding agent
   has no stable API and `spec-v1.md` §15 already flags subscription-automation
   terms as needing their own investigation. Read the terms before committing to
   this as the mechanism — the answer may force the own-agent path regardless of
   preference.
2. **What ranks the attention queue.** Task state alone is probably not enough;
   "stuck for 40 minutes" and "waiting on a one-word answer" deserve different
   positions. Needs its own design, and it is the layer's entire value.
3. **One process holding N projects, or one process per project with a
   supervisor above them.** Affects the SQLite writer assumption in §13, which
   holds for one process and is stated as such.
4. **Whether the Phase 0 outcome matters here.** It does not: if the team loses
   to solo and the roles are cut, the engine, projection, ledger and event store
   all survive, and this layer is unaffected either way.
