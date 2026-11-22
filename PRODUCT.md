# Product

<!-- impeccable:product-schema 1 -->

## Platform

terminal — a full-screen TUI on the alternate screen (Elixir, own renderer in `lib/sprat/terminal/`), with `--plain` and one-shot CLI output (`sprat status`, `sprat brief`) for pipes. None of web/ios/android applies.

## Users

The owner first: a solo founder running many projects in parallel, each moved forward by Claude Code sessions (on a typical day, ~17 sessions across ~9 repositories, several as worktrees of one repo). Designed so other solo founders and independent developers in the same situation can use it later, through the sprat.dev beta.

## Product Purpose

Sprat V4 is the product manager for every Claude Code agent on the machine: it knows where each project stands on its roadmap, notices when an agent or project stops moving, and unsticks it itself: researching on the web, checking memory and how the same problem was solved in other projects, answering from recorded decisions, or handing the agent the next unblocked item. It continues sessions after usage limits reset. Only credentials, money, scope, irreversible actions and unrecorded judgement calls go to the owner. Success: stalls resolved in minutes without the owner, fewer interruptions, and the owner rarely overrides what Sprat did. Spec: `docs/spec-v4.md`.

## Positioning

Not a terminal multiplexer or session host: sessions stay in the owner's own terminals. Sprat is an attention router over sessions it did not start, reading what Claude Code already writes to disk (session registry, transcripts) plus each project's own roadmap docs, so it works with zero setup per project. Stall detection is plain rules with cited evidence; Claude acts as the PM within guardrails code enforces, and every action names its source.

## Operating Context

- Lives in an **always-on terminal pane** (tmux split, a tab, or a second monitor) beside the Claude Code sessions it watches, glanced at between tasks all day. The pane may be narrow and tall as often as wide.
- Pulled back by desktop notifications when something needs the owner.
- Owner's rituals it plugs into: `/pause` writing `docs/PAUSE.md`, superpowers plan files with checkboxes, numbered spec phases, casual lowercase standup notes (the brief uses that voice).

## Capabilities and Constraints

- Reads `<config>/sessions/*.json` and `<config>/projects/*/*.jsonl` for every Claude config dir (`~/.claude`, `~/.claude-work`, …); git; roadmap sources.
- Writes nothing into projects except `.sprat/roadmap.md` (blocked/done marks are revertible).
- Autonomy per project: watch, propose, act (default after a project's first day), act+resume. Sprat never edits application code; it unblocks agents with messages and roadmap marks.
- Undecided: whether peer-socket delivery into live sessions is dependable (Phase 0 spike).

## Brand Commitments

- Name: **Sprat**.
- Mascot: the ASCII fish `><>` — swims when something is running, turns to face the owner (`<><` / `<•<` blink) when it needs them, still when idle. Idle animates nothing.
- Every state must stay legible with `NO_COLOR` and in ASCII mode (no dependence on Unicode glyphs or colour).
- The owner has asked to rethink the zoned multi-pane layout (`docs/design/tui-zones.md`); panes are not a commitment.

## Evidence on Hand

Real session registry and transcripts on the owner's machine; real project docs (e.g. cupful, liftlog, studio, dreamboard). No users, metrics or testimonials beyond the owner exist yet; none may be invented.

## Product Principles

1. Attention first: the top of the screen is always what needs the owner.
2. Silence is the default: nothing moves, blinks or speaks unless something changed.
3. Every number has a source one keypress away.
4. Act as the PM, never as the owner: unblock, answer from what was decided, reassign; escalate the rest.
5. Activity is not progress.

## Accessibility & Inclusion

`NO_COLOR` and ASCII-only terminals fully supported; state never carried by colour alone; mouse optional (text selection stays native).
