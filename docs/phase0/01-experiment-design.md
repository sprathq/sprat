# Phase 0 · 01 — Team vs solo experiment design

Date: 2026-09-17
Backend: installed Codex CLI (`codex exec`), subscription, read-only sandbox, live web search

## Question

Do three roles (PM, Researcher, Analyst) running the V1 workflow templates produce better-evidenced product decisions than one agent with the same tools, at ≤2× the token cost?

## Tasks

`spikes/experiment/tasks/*.md`: ten tasks, five per workflow. There's no user in the loop, so wherever a role would ask the user, it records an explicit assumption and continues.

| # | Workflow | Brief |
|---|---|---|
| 01 | idea | Software for owner-operated independent gyms in the UK; goal is revenue; web first |
| 02 | idea | Tool that recovers missed phone calls for independent US dental practices |
| 03 | idea | Client and job management for freelance translators in the EU |
| 04 | idea | Maintenance tracking for UK landlords with 1–5 properties |
| 05 | idea | LLM API cost monitoring for small SaaS teams (2–20 engineers) |
| 06 | discovery | Underserved product opportunity in UK residential property maintenance |
| 07 | discovery | Software opportunities for independent veterinary clinics in the US |
| 08 | discovery | B2B tooling for small specialty coffee roasters in the EU |
| 09 | discovery | Operations software for independent wedding venues in the UK |
| 10 | discovery | Tools for US commercial cleaning companies with 10–100 staff |

## Configurations

### Team

Each stage is one `codex exec` call with a role prompt, the stage's inputs (its direct predecessor's artifact inlined in full, earlier stages inlined compact — see "Slimming the team pipeline" below) and the shared output schema. Stages without dependencies run in parallel (max 3 concurrent calls). Only Researcher-role stages get live web search, per §4's role/tool table.

**idea:** `pm_intake` → `research_a` ‖ `research_b` (segments/angles chosen by PM intake) → `analysis` → `pm_directions` → `analyst_recommendation` (picks the direction itself, standing in for the user) → `pm_brief` (final report)

**discovery:** `pm_intake` → `landscape_a` ‖ `landscape_b` → `analyst_hypotheses_scoring` (5–10 hypotheses, top 3 scored) → `researcher_counter_evidence` → `analyst_recommendation` → `pm_validation_plan` (final report)

### Slimming the team pipeline (added after the first smoke test)

The first smoke test (task 01) came in at 3.33× solo tokens (baseline-adjusted), above the 2×
pass limit, with the team still winning on quality. Per-stage breakdown showed where it went:

| Stage | Role | Input tok. | Cached | Output tok. | Web searches |
|---|---|---:|---:|---:|---:|
| pm_intake | PM | 20,574 | 0 | 1,169 | 0 |
| research_a | Researcher | 325,059 | 252,416 | 3,181 | 6 |
| research_b | Researcher | 306,435 | 241,664 | 4,266 | 5 |
| analysis | Analyst | 213,258 | 153,344 | 3,617 | 4 |
| pm_directions | PM | 27,746 | 0 | 2,223 | 0 |
| analyst_recommendation | Analyst | 102,238 | 62,720 | 2,067 | 2 |
| pm_brief | PM | 30,882 | 11,648 | 3,862 | 0 |

Two causes, not one:

1. **`analysis` and `analyst_recommendation` were doing live web search** (4 and 2 calls) even
   though neither role needs it: V1 spec §4's tool table gives web search to the *Researcher*
   only — PM and Analyst get "read artifacts and sources, calculate," not search. Every team
   stage call in the first pass carried `-c web_search="live"` regardless of role, so the Analyst
   sometimes went and did its own research instead of reasoning over what the Researchers had
   already found. That's not a slimming trick, it's a bug against §4. Fixed by deriving the
   `web_search` flag from role: only `research_a`/`research_b` (idea) and
   `landscape_a`/`landscape_b`/`counter_evidence` (discovery) get it now.
2. **Every downstream stage got every prior stage's full artifact inlined**, even stages several
   hops back that it wasn't built to read closely. Fixed: each stage now gets its *direct*
   predecessor(s) in full (`Workflow`'s `full_from` list — e.g. `pm_brief` gets full
   `pm_directions` and `analyst_recommendation`, matching "the final PM report needs the
   recommendation and the directions"), and everything further back compact: the stage's
   `handoff` field, a 1,200-character excerpt of its artifact, and its source index (id, title,
   url, supports) — not the full prose. A stage that needs a fact from further back still has it
   available via the source index and excerpt; it just isn't re-reading the whole document.

Also: `research_a`/`research_b` and `landscape_a`/`landscape_b` are now told explicitly which
angle they are *not* covering, since the two runs in parallel were prone to converging on similar
queries.

Stage merging (e.g. folding `analyst_recommendation` into `analysis`) was considered and not
applied: it would have crossed into changing the graph under test rather than trimming waste on
it, and the two fixes above address the actual waste (search misuse + over-inlining) without
reducing from 7 calls to 6. If a future pass still runs hot after this, merging is the next lever.

None of this touches solo: solo's prompt, tools and single-call structure are unchanged, as are
the judge, the rubric, the honesty rules, the final report sections and the decision rule below.

#### Reverted: capping researcher search count

The first slimming pass also told `research_a`/`research_b`/`landscape_a`/`landscape_b` to aim
for "roughly 3-5 searches" instead of exhausting every angle. On re-test this cut research_a/b
from 6/5 searches to 4/4 and tokens from 325k/306k to 190k/189k each — but the team then **lost**
task 01 to solo. The judge's own reasoning named the cause directly: *"B [team] has only two
verified sources and relies on blocked sources for its acquisition and pricing examples"* against
solo's eight verified sources. The cap didn't remove waste, it cut evidence depth — the thing the
whole experiment exists to measure. **Reverted.** The disjoint-angle instruction stays (it
prevents duplicate work between the two parallel researchers without limiting how much either one
digs), but there is no search-count target any more; researchers dig as much as the original,
unslimmed pass did.

This also surfaces a scoring detail worth keeping in mind reading any task's results: the judge
counts a cited source as evidence only when the harness's own verification table calls it
`verified` — a source classified `blocked` (bot wall, 401/403/429) counts against the report that
cited it even if the claim itself is accurate. Sources classified `blocked` are disproportionately
common on vendor case-study and pricing pages that run bot protection, so which specific pages a
run happens to cite, not just how many, affects the verdict.

#### Finding: Codex's read-only sandbox can fetch a URL regardless of the search flag

`analysis` and `analyst_recommendation` run with `web_search` omitted entirely (no
`-c web_search="live"` in their argv — confirmed by inspecting the exact command built for each
call), yet both still produced `web_search`-typed events in the JSONL stream (3 and 2
respectively). Checked against the stage outputs: every one of those events fetched a URL that
was *already in the stage's inlined context* — e.g. `analysis`'s first fetch was
`https://clubright.co.uk/pricing/`, which `research_a` (its direct, full-inlined predecessor) had
already cited as its own source S1. None had `action.type: "search"` with a `queries` array (the
genuine search shape from `02-search-metadata-codex.md`'s probe); all had `action.type: "other"`
with the literal URL as the `query` field — a URL *fetch* of a source already on hand, not a fresh
open-ended search.

Also checked `codex features list` and `codex --help`: the `-c web_search="live"` config key this
experiment's brief specified isn't a recognized feature flag in this Codex build (0.154.0) at
all — `codex features list` shows `search_tool: removed`, `standalone_web_search: under
development`, `web_search_cached`/`web_search_request: deprecated`, no plain `web_search` key; the
real switch is a root-level `--search` flag (`codex --search exec ...`), which this experiment has
never passed either way. So neither the original "every stage gets it" pass nor this one's
role-gated version was necessarily controlling search availability through that flag — what
changed stage-to-stage was the *model's own judgement* about whether the task in front of it
warranted a tool call, and the read-only sandbox exposes URL-fetch as a baseline capability
independent of any search toggle.

**Conclusion, and what it means for V1:** this isn't a role-boundary violation — fetching a URL
that was already handed to you as a cited source is arguably exactly what spec §4's Analyst
toolset ("read artifacts and sources") allows, not independent research. But it does mean "pass a
flag" is not how V1 will be able to enforce §4's per-role tool boundaries against a Codex backend
— there is no config-level kill switch for fetch/browse the way this experiment assumed, so the
harness's `web_search_calls` counter (which does not distinguish a genuine multi-query search from
a single already-cited-URL fetch) currently overstates how much "extra research" a non-Researcher
stage actually did. The role-gated stages' remaining events are cheap (3 and 2 single-URL fetches,
not multi-turn search loops) and match this reading. For the real Sprat build on a native model
adapter (§7), tool availability is enforced by which tools the agent loop actually hands to each
role — a real allow-list, not a config nudge — so this specific gap is a Codex-backend artifact of
Phase 0, not a V1 design problem. Recorded here so it isn't mistaken for the harness silently
failing to gate search.

### Solo

One `codex exec` call. The prompt contains the same workflow steps, the same deliverable requirements and the same honesty rules, in a single-agent voice.

### Shared rules (in every prompt)

- Every material external claim cites a source from the `sources` array by ID. Anything unsourced is labelled `[assumption]` or `[model knowledge]`.
- Never invent interviews, quotes, demand figures, revenue or willingness-to-pay data.
- Never claim product–market fit; the strongest conclusion is “promising hypothesis”.
- Look for counter-evidence. Duplicated or syndicated articles count as one source.
- Scorecard (discovery): the §6 weights, 1–5 per dimension, `unknown` when unevidenced. Arithmetic is done by the harness, not the model.

### Stage output schema (`--output-schema`)

```json
{
  "artifact_markdown": "string",
  "sources": [{"id": "S1", "url": "string", "title": "string", "publisher": "string|null", "published": "string|null", "supports": ["string"]}],
  "assumptions": ["string"],
  "handoff": "string"
}
```

The final report has fixed sections: *Summary · Target customer & problem · Evidence · Counter-evidence · Options considered · Recommendation (go / revise / validate_first / stop) · Validation plan (assumption, participants, method, budget, duration, success threshold, failure threshold, next decision) · Limitations*.

## Post-processing (harness, no model)

1. Merge sources across stages; de-duplicate by normalised URL.
2. **Verify every cited URL:** HTTP GET with a 10 s timeout, following redirects. Record status, final URL, `<title>` and content hash, and store the text snapshot. Mark each source `verified`, `unreachable` or `blocked` (401/403/429 or bot wall).
3. Count citations in the final report whose source ID doesn't exist (`dangling`).
4. Sum tokens per configuration. Measure the per-call baseline once with a trivial prompt; report raw and baseline-adjusted totals.

## Judging

- **Blind:** for each task, the two final reports are randomly labelled A and B. The mapping is stored separately and not shown to the judge.
- **Judge:** `codex exec` in the read-only sandbox **without** web search. It receives both reports plus each report's source verification table.
- **Rubric** (1–5 each, with a one-sentence justification):
  1. Evidence grounding: material claims backed by verified sources
  2. Counter-evidence: contradicting evidence actively sought and addressed
  3. Honesty: assumptions labelled, no fabrication, no PMF overclaim
  4. Specificity: concrete customer, problem and scope rather than generic
  5. Validation plan actionability: thresholds and next decision are testable
- Plus counts: unsupported material claims, dangling citations, unverified sources cited.
- **Verdict per task:** A, B or tie on overall evidence quality.
- **Human spot-check:** the owner blind-reviews 3 randomly chosen tasks with the same rubric. If the owner disagrees with the judge on 2 or more of the 3, the automated verdict is not trusted, and all 10 go to human review.

Known bias: a Codex judge scoring Codex output. That is why the spot-check exists.

## Decision rule (from V1 spec §14)

- **Pass:** team wins ≥7/10 on evidence quality at ≤2× baseline-adjusted tokens → build roles as specified.
- **Fail:** V1 ships solo mode; the roles section is removed.
- **Ambiguous** (5–6 wins, or ≤2× only on raw tokens): the owner decides, with the per-rubric breakdown in front of them.

## Outputs

`spikes/experiment/runs/<timestamp>/`
- `<task>/<config>/stages/<stage>.json`: stage output
- `<task>/<config>/events/<stage>.jsonl`: raw Codex events
- `<task>/<config>/report.md`, `sources.verified.json`, `usage.json`
- `<task>/judge.json`, `<task>/blind_map.json`
- `summary.md`: results table, win count, token ratio, decision
