# Sprat V5: the engine as an OTP system, and everything it does in sight

Status: **built** (2026-11-24): jobs and the NOW band, the activity stream and screen, observers as processes, and the board subscribed to the daemon over a Unix socket. Builds on [spec-v4.md](spec-v4.md); the product
does not change, the way it runs and what it shows does.

## 1. Why

V4 runs almost everything in one process, `Sprat.Engine` (1,700 lines): scanning sessions,
tailing transcripts, running `cmux`/`git`/`ps`, the detector, the usage-limit scheduler,
the board's commands and the snapshot the board reads. Only PM investigations run as tasks.

What that costs, from the real daemon log of 2026-11-24:

- fast ticks of 10–17 s and a slow tick of 62 s; "engine is busy, 62s without a snapshot";
- pressing `f continue on .claude-work` copied a 153 MB transcript plus 1,288 subagent files
  inside the engine call: 34 s with no answer, then a session that never appeared, and nothing
  on screen said so;
- `limit_scheduled` written to the events table every 2 s for one finding;
- work is a function call, not a process: from outside it is either done or the board froze.

The owner's requirement: **every piece of work Sprat does is visible, in context, while it
happens**, and the system is built the Elixir way: independent supervised processes, each
owning its own state, crashing alone, and announcing what they do.

## 2. Principles

1. **One process per thing that lives**: a session, a project, a job, the cmux map, the
   accounts. Each owns its state and its timers; a crash restarts that one thing.
2. **Nothing anyone waits on does slow work.** A `call` answers from memory. Outside
   commands, file copies, PM runs and git run in the process that owns the data or in a Job.
3. **Every piece of work is a Job.** It has an id, a kind, a project, a label, steps, and an
   outcome. It announces `started → step… → done | failed` on PubSub. A command that starts
   work replies at once with the job id.
4. **Every outside process goes through `Sprat.Cmd`**, which announces what ran, for how long
   and its exit status. That is how the owner sees Sprat spawn `claude`, `cmux`, `git`, `ps`.
5. **Events, not polling.** The board subscribes; the engine no longer rebuilds a whole
   snapshot every second for a client that re-reads a file.
6. **Results stay where they happened**: on the ticket, the project row, the activity
   timeline. A failure stays red until the owner has seen it.

## 3. Supervision tree (target)

```
Sprat.Supervisor (one_for_one)
├─ Store                      SQLite, the only writer
├─ Sprat.PubSub               topics: "activity", "session:<id>", "project:<root>", "jobs"
├─ Observer.Supervisor (rest_for_one)
│  ├─ Accounts                config dirs + logins; broadcasts changes
│  ├─ Cmux                    the surface map; borrows access; its own timer
│  ├─ SessionSupervisor (DynamicSupervisor)
│  │  └─ SessionServer × N    tails its transcript, folds its state, runs its own rules
│  └─ ProjectSupervisor (DynamicSupervisor)
│     └─ ProjectServer × N    roadmap, git progress, position, autonomy
├─ Work.Supervisor
│  ├─ JobSupervisor (Task.Supervisor)    Job × N
│  ├─ Jobs                    the job table: running and recent jobs, their steps and outcomes
│  └─ Scheduler               limit resets, follow-ups, held deliveries (timers)
├─ Activity                   subscribes to everything; ring buffer + `events` table
└─ Daemon                     the board's connection (see §6)
```

Sessions and projects register in `Registry` by id / root, so a SessionServer finds its
ProjectServer without asking a central process.

## 4. Jobs

```elixir
%Job{id, kind, project_root, session_id, ticket_id, label, steps: [{at, text}],
     status: :running | :done | :failed, result, started_at, finished_at}
```

- Kinds: `:deliver`, `:switch_account`, `:resume`, `:start_session`, `:investigate` (PM run),
  `:roadmap_write`, `:verify`.
- A job body is a plain function given a `step.(text)` callback; `Jobs.start/2` runs it under
  `JobSupervisor`, monitors it, and turns a crash into `failed` with the reason.
- Starting a job broadcasts `{:job, job}`; each step and the outcome broadcast again.
- The owner of the data applies the outcome (e.g. the finding is dismissed only when a
  switch actually started a session), so a failed job changes nothing but its own record.
- Jobs are kept in memory (last 200) and written to `events` as `job_started`/`job_done`.

### Example: `f continue on .claude-work`

1. Board: the key answers in the same frame: `f · moving studio-67 to .claude-work…`.
2. Engine: starts a `:switch_account` job and replies `{:ok, {:job, id}}` immediately.
3. Job steps, each visible: `copying conversation 82/153 MB` → `copying 1,288 agent
   transcripts` → `opening a cmux workspace` → `waiting for Claude to start` →
   `started in "studio · .claude-work"` (or `failed: claude exited — <its last screen lines>`).
4. Done: the finding is dismissed, served records the move, the ticket shows the outcome.

## 5. What the board shows

- **Instant acknowledgement**: every key that sends a command shows its pending line at once.
- **Now strip** (below the header, only while something runs or just finished):
  ```
  ⠋ studio · moving studio-67 to .claude-work · copying conversation 82/153 MB      12s
  ⠋ joylum · investigating stall · PM run 1/3 · $0.04                              40s
  ✓ liftlog · nudged liftlog-12 · 2m ago
  ```
- **Tickets** carry their job's live step and outcome.
- **Doing column** comes from live jobs first, then the current inference.
- **Activity screen (`a`)**: a timeline of jobs, PM runs and outside commands (what ran,
  duration, exit), filterable to one project; `⏎` on a project shows its slice.
- **`sprat debug`** attaches `observer_cli` to the daemon node for the live process tree.

## 6. Board ↔ daemon

V4 passes a snapshot file and a command spool. V5 adds a Unix socket,
`<data>/v4/sprat.sock` (mode 0600), carrying length-prefixed Erlang terms:

- `Sprat.Engine.Publisher` builds the snapshot when the engine signals a change (a command, a
  job's step or outcome, a tick), at most every 100 ms and at least once a second, writes the
  file, and pushes it to every subscribed board;
- `Sprat.Engine.Socket` accepts boards, one linked process each; commands run in their own
  task;
- `Sprat.Engine.Remote` is the board's side: it keeps the last pushed snapshot, wakes the board
  on each push, answers with the last snapshot marked stale while the daemon restarts, and
  reconnects every second.

Chosen over Erlang distribution: that needs `epmd` listening on the network and a shared
cookie; a socket file keeps everything on this machine, for this user. The file and spool stay
for older boards.

## 7. Order of work

Each step ships on its own and keeps the 1,200+ tests green.

1. **Jobs, first user: switch account.** `Sprat.Engine.Jobs` (job table in the engine state,
   bodies under the existing `TaskSupervisor`); `switch_account` as a job with copy progress
   and a check that the session really started; the now strip; instant acknowledgement in the
   board; `limit_scheduled` logged once per finding and reset time.
2. **Activity stream.** `Sprat.PubSub`, `Sprat.Cmd` announcing commands, deliveries and PM
   runs as jobs, the activity screen. Visible without the big refactor.
3. **Split the engine.** Built as `Sprat.Observer.Supervisor`: Accounts, Cmux, the session
   scan, a SessionServer per session and a ProjectServer per project, publishing to ETS
   (`Sprat.Observer.Live`); the engine reads what they published and decides. The same
   observer code runs inline in tests and one-shot commands (`observers: :inline`).
   The scheduler, holds and follow-ups stay in the engine: they are decisions over
   in-memory state, take microseconds, and splitting them would add coordination without
   removing any wait. Revisit if the activity screen ever shows the engine's mailbox
   growing.
4. **The board subscribes.** Built as the socket of §6; snapshot file and spool as fallback.

## 8. Not changing

The product rules of spec-v4 (rules, policy, guardrails, autonomy levels), the store schema
except new event types, the CLI.
