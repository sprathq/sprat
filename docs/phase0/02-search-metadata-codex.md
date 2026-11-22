# Phase 0 · 02 — Search metadata via installed Codex

Date: 2026-09-17
Status: findings recorded; decision pending the experiment (01)

## Context

The V1 spec assumed Anthropic BYOK with server-side search. For Phase 0 the owner chose to use the installed Codex CLI (subscription) instead of spending API money. This record captures what `codex exec` exposes for building §6 source records.

## Setup

- `codex-cli 0.154.0`, invoked through a cmux wrapper shim
- `codex exec --json --ephemeral --skip-git-repo-check -s read-only -c 'web_search="live"' "<prompt>" < /dev/null`
- Raw event log: `codex-probe-search.jsonl`

## Findings

| Question | Result |
|---|---|
| Structured event stream? | Yes. JSONL: `thread.started`, `turn.started`, `item.started/completed` (`agent_message`, `web_search`, `error`), `turn.completed`. |
| Search queries visible? | Yes. `web_search` items carry `action.query` or `action.queries`. |
| Search **results** visible (URLs, titles, snippets)? | **No.** Only the queries are exposed. URLs appear only inside the agent's final Markdown. |
| Page text / snapshot available? | **No.** |
| Usage? | Yes, per turn: `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`. No monetary cost (subscription). |
| Read-only enforcement? | `-s read-only` sandbox is available and enforced by Codex. |
| Structured final output? | `--output-schema <file>` constrains the final message to a JSON Schema. |
| Baseline overhead | ~43k input tokens per call even with `--ignore-user-config --ignore-rules`: skills and a hook-trust bypass still arrive via the cmux wrapper / `CODEX_HOME`. Most of it is cached. |
| Stdin | Reads stdin when not a TTY; pass `< /dev/null`. |

## Consequences for the spec

1. **Codex's events alone can't build source records.** With Codex as a backend, Sprat must:
   - require agents to return sources through `--output-schema` (URL, title, publisher, date, claim supported), and
   - **fetch every cited URL itself** to confirm it exists, capture a snapshot, hash it and extract the title. A cited URL that fails to fetch is flagged `unverified`.
   This also works as a check against hallucinated citations, so it's worth keeping for any backend.
2. **Cost is tokens, not dollars.** The experiment compares tokens and wall time. The usage ledger shows `subscription` coverage with no monetary value, as the parent spec requires.
3. **Per-call overhead penalises the team configuration**, which makes more calls. The experiment reports raw tokens *and* tokens minus a measured per-call baseline.
4. The hook-trust bypass comes from the local cmux wrapper, not from Sprat. A real Sprat adapter must invoke the Codex binary directly and must not inherit that flag.
