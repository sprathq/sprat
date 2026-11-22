# Phase 0 experiment: team vs solo

Throwaway spike, not product code. Proves (or disproves) whether Sprat's 3-role team beats a
single solo agent on evidence quality, using the installed Codex CLI as the backend. See
`../../docs/phase0/01-experiment-design.md` for the full design this implements.

## Toolchain

Elixir 1.19.5-otp-28 via asdf, pinned by `../../.tool-versions`. Run every command below from
inside `sprat/` (this directory's parent's parent) so asdf picks up the pin, e.g.:

```sh
cd sprat
asdf install   # once, if you don't already have 1.19.5-otp-28 / erlang 28.3.1
```

Requires the `codex` CLI on `PATH` (tested against `codex-cli 0.154.0`), backed by a real
subscription — every run spends real quota.

## Layout

- `tasks/01..10-*.md` — the ten task briefs (5 `idea`, 5 `discovery`), YAML front matter + brief.
- `prompts/` — role personas, per-stage instructions, solo walkthroughs, the judge prompt, and
  shared fragments (`_honesty_rules.md`, `_output_schema.md`, `_final_report_sections.md`,
  `_scorecard.md`) included verbatim in every prompt so solo and team play by identical rules.
- `schemas/stage.json`, `schemas/judge.json` — `--output-schema` files for codex.
- `lib/*.ex` — the runner's modules (`Pure` is the model-free logic; everything else does I/O).
- `run.exs` — the runner (`Mix.install`-based script, no mix project).
- `test_pure.exs` — self-check for the pure logic (URL dedup, usage arithmetic, scorecard,
  decision rule). No codex calls, no quota spent.
- `spot_check.exs` — prints N random tasks' A/B reports with the mapping hidden, for a human
  blind spot-check against the judge's rubric.

## Running

Self-check first (free, no quota):

```sh
cd spikes/experiment
elixir test_pure.exs
```

Smoke test (spends quota — one task, both configs, with judging — ~10 codex calls):

```sh
elixir run.exs --tasks 01
```

Full Phase 0 run (spends significantly more quota — 10 tasks × (7 team calls + 1 solo call) +
10 judge calls + 1 baseline call = 91 calls):

```sh
elixir run.exs
```

Flags:

- `--tasks 01,02` — comma list of task IDs (default: all 10)
- `--configs team,solo` — which configs to run (default: both)
- `--skip-judge` — skip the blind A/B judging step
- `--resume <run_dir>` — reuse an existing run directory; any stage whose output file already
  exists on disk is skipped instead of re-invoked (safe after a crash or a rate limit)
- `--concurrency N` — max concurrent `codex exec` processes across the *entire* run, team and
  solo and every task combined (default 3)

Output lands in `runs/<timestamp>/`:

```
runs/<timestamp>/
  <task>/<config>/stages/<stage>.json      # one per stage (team) or "solo.json" (solo)
  <task>/<config>/events/<stage>.jsonl     # raw codex --json event stream
  <task>/<config>/report.md                # final deliverable's artifact_markdown
  <task>/<config>/sources.verified.json    # merged, deduped, HTTP-verified sources
  <task>/<config>/usage.json               # token totals (raw + baseline-adjusted), failures
  <task>/judge.json                        # blind judge verdict + rubric + counts
  <task>/blind_map.json                    # which label (a/b) was team/solo (not shown to judge)
  summary.md                               # results table, win count, token ratio, decision
```

## Human spot-check

After a run has judged at least one task:

```sh
elixir spot_check.exs runs/<timestamp> 3
```

Prints 3 randomly chosen tasks' reports as "Report A" / "Report B" with the team/solo mapping
withheld. Score each on the same rubric as the judge, then compare against `judge.json` and
`blind_map.json` for those tasks. Per the design doc: if the owner disagrees with the judge on
2 or more of the 3, the automated verdicts aren't trusted and all 10 tasks go to full human
review instead.

## Resuming after a crash or rate limit

`run.exs` writes each stage's output the moment it succeeds. If a run dies partway (rate limit,
`kill -9`, laptop sleep), re-run with `--resume`:

```sh
elixir run.exs --resume runs/20260917T134801.013419Z
```

Every stage whose `stages/<stage>.json` and `stages/<stage>.usage.json` already exist is read
from disk instead of re-invoking codex; everything else picks up where it left off.
