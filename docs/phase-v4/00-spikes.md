# V4 Phase 0 — spike results

Date: 2026-11-23 · Claude Code 2.1.328–2.1.330 on the owner's machine

## 1. Transcript shapes

Records Sprat depends on, confirmed in real transcripts under `~/.claude/projects` and
`~/.claude-work/projects`:

- `user` / `assistant` with `message.content` (string or blocks: `text`, `tool_use`,
  `tool_result`), `timestamp`, `cwd`, `gitBranch`, `sessionId`, `isSidechain`.
- `assistant.isApiErrorMessage: true`, `apiErrorStatus: 429`, `error: "rate_limit"` on usage
  limits; the text carries the reset.
- `ai-title.aiTitle`, `cost-state.totalCostUSD`, `pr-link`, `worktree-state`, `system`.
- Many other record types (`api-request`, `attachment`, `queue-operation`, …) — ignored.

Decision: parse only the above; ignore unknown types and fields; golden fixtures in
`test/fixtures/v4/transcripts/`.

## 2. Delivery into a live session

The registry's `messagingSocketPath` speaks Claude Code's internal peer protocol. It is not
documented, and reverse-engineering it from the minified binary is fragile. **Dropped.**

The owner runs sessions inside **cmux**, whose supported CLI does what Sprat needs:

- `cmux top --all --processes --format tsv` maps every Claude pid to its `surface:N`.
- `cmux read-screen --surface S --lines N` reads the pane.
- `cmux send --surface S <text>` + `cmux send-key --surface S enter` submits a prompt.

Tested on a throwaway workspace: messages arrive as normal `user` turns in the transcript.
Two hazards found and turned into rules:

1. A dialog in the session (e.g. "Teach auto mode…") swallows typed input. **Only deliver
   when the last screen line under the input rule is an empty `❯` prompt.**
2. `ctrl+u` does not clear Claude's prompt; text typed by the owner gets concatenated.
   **Never deliver when the prompt line is non-empty** (also the "owner is typing" rule).

Order of adapters: cmux → tmux (`tmux send-keys`, when the registry has `tmux`) →
clipboard. Decision recorded in `spec-v4.md` §9.3.

## 3. Usage-limit messages

Formats seen (all `isApiErrorMessage`, HTTP 429):

- `You've hit your 5-hour limit · resets 11:50am (Europe/London)`
- `You've hit your session limit · resets 4pm (Europe/London)`
- `You've hit your weekly limit · resets Nov 24 at 5pm (Europe/London) · out of usage credits`
- any of the above followed by ` (error type rate_limit, HTTP 429, request id …)`

At the time of the spike the `~/.claude` account was at its weekly limit (resets Nov 24
5pm); `~/.claude-work` was not. Limits are per config dir (account).

## 4. PM runtime

`claude -p … --output-format json --json-schema <schema>` returns `structured_output`,
`total_cost_usd`, `num_turns`, `session_id`, `subtype`, `is_error`. The account used is
the one `CLAUDE_CONFIG_DIR` points to; Sprat sets it per project's account.

## 5. W1/W2 detection

Distinguishable from the transcript: a pending `AskUserQuestion` / question text ends the
last assistant turn (W1); a `tool_use` with no `tool_result` while the registry says
`idle` is a permission prompt (W2). `cmux read-screen` can confirm both where available.
