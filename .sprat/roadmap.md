# Roadmap: sprat
<!-- sprat: edit freely; lines you change are never overwritten -->

## 0 · spikes (days)
source: docs/spec-v4.md

- [x] Transcript shapes: golden files from the owner's real transcripts across the two Claude Code versions on the machine; a parser that…
- [x] Peer delivery: can Sprat deliver a message to a live session's socket, does it arrive at the next tool round or wake an idle session, and…
- [x] W1/W2 detection: confirm "idle with a pending question" and "idle on a permission prompt" are distinguishable from the transcript alone.

## A · the board, read-only
source: docs/spec-v4.md

- [x] the board, read-only

## B · findings and the PM in propose
source: docs/spec-v4.md

- [x] findings and the PM in propose

## C · the PM acts
source: docs/spec-v4.md

- [x] the PM acts

## D · resume and verify
source: docs/spec-v4.md

- [x] resume and verify

## E · Staged Research Workflow  [active]
source: docs/superpowers/plans/2026-09-20-staged-workflow.md

- [ ] Sprat.Workflow.Template — stage and template structs
- [ ] Sprat.Workflow.ArtifactSchema — required-field schemas per artifact type
- [ ] Sprat.Workflow.Idea and Sprat.Workflow.Opportunity — the two templates + depth limits
- [ ] Sprat.Workflow.Gate — pure gate checks (§5 Gates table)
- [ ] Sprat.Workflow.Scorecard — §6 weighted scoring, unknowns, sensitivity
- [ ] Sprat.Store.Artifacts and Sprat.Store.Decisions
- [ ] write_artifact tool, type-restricted per task
- [ ] Sprat.Orchestrator — walks a template, one stage at a time
- [ ] The Directions user-choice point
- [ ] Stall detection and per-stage/mission budget exhaustion
- [ ] /idea, /research, /depth — wire the entry points; keep plain messages on Mission
- [ ] Feed the Mission zone checklist and budget meter from real stage state  <!-- blocked: V1 research product parked behind sprat legacy -->
- [ ] Artifacts tab in the Inspector; /artifacts, /open, /claims, /export against real rows
- [ ] Sprat.Store.MissionState and a real paused_budget mission status
- [ ] Budget exhaustion mid-workflow and resume without re-running a completed stage
- [ ] Full verification pass
- [ ] Live end-to-end run — /idea at quick depth, real spend capped at $3  <!-- blocked: V1 research product parked behind sprat legacy -->
