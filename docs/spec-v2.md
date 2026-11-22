# Sprat V2 — Build Phase Specification

Version: 2.0-draft
Prepared: 26 September 2026
Parent documents: `spec-v1.md` (what exists), `spec-full.md` (long-term target)
Status: proposal, not started

## 1. What V2 is for

V1 answers *what should I build, and on what evidence*. It ends with a product brief, an
MVP boundary and a validation plan. Then it stops, and you open a different tool.

V2 carries the same mission through to a **running MVP you can put in front of someone**,
keeping V1's discipline: every claim sourced, every cost counted, every failure visible,
nothing reported as working that has not been run.

Product promise, extended: **Research the problem. Shape the product. Build it with
evidence it works.**

### The bet V2 tests

> An agent that decided *what* to build, with the evidence and the constraints still in
> hand, builds a better first version than an agent handed the same brief cold.

If that is false — if piping the brief into Claude Code gets you the same result — then V2
should be a thin export and nothing more. §14 makes that a real gate, not a hope.

## 2. What V2 is not

- **Not a better coding agent.** Claude Code and Codex are good at writing code; that is
  commoditised and not where Sprat's value is. V2 may delegate implementation to them
  (§6) rather than compete.
- **Not "any idea to any product".** Scope is bounded and declared (§4). Outside it, V2
  says so and hands you the design instead of pretending.
- **Not autonomous at the start.** V2 ships with three human checkpoints (§5). Removing
  them is V2.x work, gated on measurement, not on optimism.
- **Not a deployment platform.** It can deploy to a target you already own, with your
  credentials, on your say-so. It does not become your hosting.

## 3. What changes from V1

| Area | V1 | V2 |
|---|---|---|
| Roles | PM, Researcher, Analyst | adds **SWE (implementer)** and **Reviewer** — a separate instance with its own context, never the same conversation |
| Tools | read-only: search, fetch, read_file, calculate, artifacts | adds **write_file / apply_patch, shell, git, test runner**, each scoped to a workspace |
| Workspace | none | a git worktree per build task, pinned to a base revision (§7) |
| Gates | artifacts exist, validate, cite sources | adds **it runs**, **its tests pass**, **the reviewer disagrees or signs off** |
| Permissions | fetch approvals, read-only repo | write scope, shell allow/deny, network policy, and an explicit ceiling the agent cannot raise |
| Verification | source hashes, claim citations | execution evidence: command, exit code, output hash, and a screenshot or transcript where the thing has a UI |

Everything else — the orchestrator, gates, artifacts, budget, evidence store, event log,
the TUI, steering, attachments — is reused, not rebuilt.

## 4. Declared scope

V2 builds within a **stack profile**: a declared combination of language, framework,
datastore, test runner and run target that Sprat has a tested recipe for. V1 ships two:

| Profile | Stack | Run target | Why first |
|---|---|---|---|
| `elixir-phoenix` | Elixir, Phoenix, Postgres, ExUnit | `mix phx.server` locally | The team knows it; the repo is the proof |
| `node-next` | TypeScript, Next.js, SQLite/Postgres, Vitest | `npm run dev` locally | Most common MVP shape |

A mission whose brief needs something outside the profiles **stops at the technical
design** and says which part is unsupported. It does not improvise a stack it cannot
verify. Adding a profile is a data change plus a fixture mission that proves it (§14).

A profile declares: scaffold command, dependency install, test command, run command,
health check, lint/format commands, and the file layout conventions the implementer is
told to follow.

## 5. The build workflow

Appended to the idea workflow, after Delivery. `/build` starts it from an existing
mission's brief; a fresh mission can run research and build in one pass.

```text
Technical design (SWE)  →  [CHECKPOINT 1: design approved]
   → Scaffold (SWE)     →  first run must succeed
   → Plan tasks (SWE)   →  a dependency-ordered task graph
   → Implement (SWE, one task at a time, own worktree)
        ↺ test → fix → test, bounded
   → Review (Reviewer, separate context)  →  [CHECKPOINT 2: first run works]
   → Integrate + verify on the combined result
   → Acceptance against the brief (PM)
   → [CHECKPOINT 3: ready to show someone]
```

### The three checkpoints

1. **Design approved.** Stack profile, data model, the MVP's boundary, what is
   deliberately excluded, and the estimated cost to build it. Cheap to redirect here;
   expensive later.
2. **First run works.** The thing starts, the health check passes, and you are shown how
   to run it yourself. This is the checkpoint that stops a confident report of a broken
   app.
3. **Ready to show someone.** Acceptance criteria met, review findings resolved or
   explicitly accepted, and a summary of what is missing.

Each checkpoint can be set to `auto` per project once you trust it (§13). The default is
`ask`, and the default is not a placeholder — see §12.

### Stage gates, checked by code

| Gate | Requirement |
|---|---|
| Design → Scaffold | Design artifact validates; names a supported profile; data model has entities and relations; excluded scope is listed |
| Scaffold → Plan | The scaffold runs: install succeeded, run command starts, health check returns, recorded with command, exit code and output hash |
| Plan → Implement | Task graph is acyclic, every task names files, an acceptance check and a test; no task is "misc" |
| Implement → Review | Every task's tests pass on its own worktree; a task with no test fails the gate |
| Review → Integrate | Reviewer has produced findings with severities; nothing unresolved at `blocker` |
| Integrate → Acceptance | Combined branch builds, full test suite passes, run command starts, health check returns |
| Acceptance → Delivery | Every acceptance criterion from the brief is met or explicitly recorded as not met, with a reason |

**"It runs" is a gate, not a claim.** Execution evidence — command, exit code, duration,
output hash, and the artifact path — is stored for every one of these, exactly as source
hashes are for research.

## 6. Who writes the code

Two execution modes behind the same contract, chosen per project.

**Native (default).** Sprat's own agent loop with write tools, running against a worktree.
Full event visibility, the same budget ledger, and the same context package machinery V1
already has.

**Delegated.** The implementation task is handed to an installed coding agent (Claude
Code, Codex) over its documented programmatic interface, as `spec-full.md` §7 describes.
Sprat supplies the task, the workspace, the constraints and the acceptance check;
consumes its events; and applies the same gates to the result.

The rule that makes delegation safe: **Sprat verifies the result itself.** It runs the
tests, it runs the app, it reads the diff. A delegated agent reporting success is an
input, not evidence. If a backend cannot be given an enforceable write boundary, it is
ineligible for a strict mission (spec-full §7).

Why both: native gives control and observability; delegated means Sprat benefits from
whichever coding agent is best without rebuilding it. The eval in §14 measures whether
either beats a plain brief handed to Claude Code — including the possibility that Sprat's
right answer is to orchestrate, not to implement.

## 7. Workspaces and safety

- **One git worktree per implementation task**, pinned to an explicit base revision. Never
  the user's working tree, never the checkout they have open.
- **Uncommitted user changes are recorded before anything starts**, and never reset,
  cleaned, stashed or overwritten — spec-full §16's rule, restated because this is where
  it bites.
- **Write scope is the worktree**, enforced by path checks plus a platform sandbox. Sandbox
  strength is recorded as `enforced`, `partial` or `none`, and a project can require
  `enforced`.
- **Shell** runs with an explicit argument array, never a shell string built from model
  output, with a timeout, a killed process tree, and an allow/deny list per profile.
  Network access during build is off unless the profile needs it (dependency install), and
  that window is logged.
- **Integration is sequential**: each finished branch merges into an integration branch,
  the combined result is re-verified, and conflicts surface to the user rather than being
  resolved by guesswork.
- **Nothing leaves the machine.** Commits stay local; push, publish and deploy need
  explicit, separately-granted authority (§9), never implied by "build it".
- Failed worktrees are kept for inspection, cleaned on an explicit policy.

## 8. What gets produced

Added to V1's artifacts:

| Artifact | Contents |
|---|---|
| `technical_design` | Profile, data model, components, external services, what is excluded and why, estimated build cost |
| `task_graph` | Ordered tasks: files, acceptance check, test, dependencies, estimate |
| `implementation_report` | Per task: diff summary, tests run, results, retries, cost |
| `review_findings` | Per finding: severity, file, what would go wrong, suggested fix, resolution |
| `run_evidence` | Every execution: command, exit code, duration, output hash, screenshot or transcript |
| `acceptance_report` | Each criterion from the brief: met / not met / partially, with the evidence |
| `handover` | How to run it, what is real, what is stubbed, what to do next, known limitations |

`handover.md` is the one a human reads first. It must state plainly what is **not** built —
a stubbed payment flow, a hardcoded admin user, an untested edge — because that is where
an MVP misleads its owner.

## 9. Permissions, budgets and the ceiling

- **A build mission declares its ceiling before it starts**: money, wall time, model calls,
  and the number of implementation attempts. The agent cannot raise any of them; the user
  can, explicitly, mid-mission via steering.
- **Money matters more here.** A research mission is cents; a build mission is dollars, and
  a retry loop is how it becomes tens of dollars. Every retry is charged against the task's
  own budget, and a task that exhausts it stops and asks rather than grinding.
- **Separate grants**, each asked for once and recorded: write to this workspace, run
  shell, install dependencies (network), commit, push, deploy. "Build it" grants the first
  three. It never grants the last two.
- **Secrets**: a build that needs an API key asks for it by name and reads it from the
  environment or the credential store. It never writes one into the repo, and the redaction
  path covers build logs exactly as it covers model payloads.

## 10. Verification is the product

The distinguishing feature of V2 is not that it writes code; it is that it refuses to
claim success without evidence, and shows you the evidence.

1. **Unit tests** — written per task, run per task, results stored.
2. **It starts** — the run command, the health check, the exit code.
3. **It is driven** — for anything with an interface, a scripted pass over the primary
   flows, capturing what is actually on screen. This is the `/test-tui` and `test-ui`
   discipline applied to what Sprat builds: *a passing test suite is not evidence that the
   thing works; a captured screen is.*
4. **A reviewer disagrees** — a separate instance with the brief and the diff, and no
   memory of having written it, whose findings are recorded whether or not they are acted
   on.
5. **Acceptance against the brief** — by PM, in the user's terms, not the implementer's.

Anything Sprat could not verify is named in the handover as unverified. That list is
expected to be non-empty; an empty one is a smell.

## 11. What the user sees

The existing zones carry it:

- **Mission** — build stages alongside research stages, with the same honest glyphs.
- **Agents** — SWE and Reviewer instances, their current task and file.
- **Inspector** — a **Diff** tab (per task and combined), a **Runs** tab (every execution
  with its exit code), and Tests alongside Evidence.
- **Detail** — the diff of the selected task; the output of the selected run.
- **Conversation** — stage transitions, gate results, checkpoint prompts.

Steering applies during a build: "use Postgres, not SQLite" typed mid-run reaches the next
task boundary and marks the affected design artifact stale, exactly as it does in research.

## 12. Honesty rules, extended

V1's rules carry over unchanged. Added, in the same spirit:

- **Never report a build as working without an execution record.** "Should work" is not a
  status.
- **Never claim a test passes without its output.** A test that was not run is not a
  passing test.
- **Stubs are declared.** Anything faked to make a flow complete — a payment, an email, an
  auth provider — appears in the handover under what is not built.
- **Estimates are labelled as estimates**, including build cost before the fact.
- **A failed build is delivered as a failed build**, with what exists, what broke, and the
  evidence — not quietly retried into something that compiles but does nothing.
- **No unrequested scope.** The MVP boundary from the brief is the boundary; anything extra
  is a finding for the user, not a commit.

## 13. Autonomy, earned

V2 ships asking at three checkpoints. Each can be set to `auto` per project, and the
setting is per checkpoint, not global.

The rule for removing one: **evidence, not confidence.** A checkpoint may default to `auto`
only when, across the eval set (§14), missions that auto-passed it produced no worse an
outcome than missions where a human answered — measured by the acceptance report and the
reviewer's findings, not by whether the run finished.

Full autonomy — no checkpoints, a mission left alone — is V2.x at the earliest, and only
within a stack profile with a track record. This document does not promise it, and a
version that claims it without the measurement is lying to its user.

## 14. How we will know it worked

**The eval set:** ten briefs, real ones, spread across both profiles — a CRUD tool, an API
client, a scheduled job, a small web app with auth, a data importer. Each has acceptance
criteria written by a human before the run.

Each brief runs in three configurations:

1. **Sprat V2** — research plus build, in one mission.
2. **Brief → Claude Code** — the same brief handed cold to a good coding agent.
3. **Sprat design → Claude Code** — Sprat's technical design and task graph, implemented
   elsewhere.

Judged on: acceptance criteria met (by a human, blind to configuration), whether it runs
unaided, defects found by a reviewer who did not build it, honesty of the handover
(stubs declared versus stubs discovered), cost, and human interventions needed.

**Pass:** V2 beats configuration 2 on acceptance and honesty at a defensible cost. If
configuration 3 wins, the finding is that Sprat should orchestrate and delegate rather than
implement — and that is a legitimate, and cheaper, product.

**Fail:** if neither Sprat configuration beats a cold brief, V2 does not ship. The brief
export gets better instead.

## 15. Build sequence

**Phase A — the spine, one profile, native execution.** Technical design and scaffold
stages, worktrees, write and shell tools with their sandbox, run evidence, the Diff and
Runs tabs. Exit: a scaffolded Phoenix app that starts, from a real brief, with the first
run recorded.

**Phase B — implementation and review.** Task graph, per-task worktrees, the test-fix
loop with bounds, the Reviewer as a separate instance, integration and combined
verification. Exit: a two-entity CRUD app built from a brief, tests passing, reviewed.

**Phase C — acceptance, handover and the second profile.** PM acceptance against the
brief, the handover document, `node-next`, and driving a UI for real evidence. Exit: the
eval set runs end to end.

**Phase D — the eval, then autonomy.** Run §14. Publish the result honestly, including if
it says delegate rather than implement. Only then consider defaulting a checkpoint to
`auto`.

Estimates deliberately omitted: V1's Phase 0 took a day and its "4–5 week" Phase 2 took an
afternoon with subagents. Sequence is the useful commitment; duration is not.

## 16. Open questions

1. **Native or delegated first?** Delegated reaches a working MVP sooner and tests the
   orchestration bet directly. Native gives the event visibility everything else here
   depends on. My inclination: native for the spine (Phase A), measure delegation in
   Phase D.
2. **Does the Reviewer need a different model** to be genuinely independent, or is a
   separate context enough? spec-full §4 warns that the same model reviewing itself is not
   independent evidence.
3. **Team-vs-solo is still unsettled**, and it matters more here than in research. A
   builder and a reviewer that are genuinely independent is the only mechanism that catches
   what tests miss without a human.
4. **How far does "it is driven" go?** Scripted flows are cheap and catch most of it;
   anything more is a research project of its own.
5. **What happens on the second run?** An MVP that exists and needs changing is a different
   workflow from one being created, and this document only covers creation.
