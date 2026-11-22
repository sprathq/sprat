# Sprat

The product manager for every Claude Code agent on your machine.

Sprat watches every Claude Code session you run, knows where each project stands on its
roadmap, notices when an agent or a project stops moving, and gets it moving again itself:
it checks the roadmap and the decisions already written down, searches your memory and how
the same problem was solved in your other projects, researches on the web, then unblocks
the agent, answers its question from what was decided, or hands it the next unblocked item.
It continues sessions when a usage limit resets. Only what is genuinely yours (credentials,
money, scope, irreversible actions, judgement calls nobody wrote down) reaches you.

Status: **V4 built** (spec: [docs/spec-v4.md](docs/spec-v4.md)). Local, single user, macOS.

## Use

```sh
sprat                 # the Pass: a board of every project, what needs you, what Sprat is doing
sprat serve           # run the observer/PM as a daemon; boards connect over <data>/v4/sprat.sock and get every change pushed
sprat status          # one line per project: roadmap position, last progress, live sessions
sprat brief           # today's brief, one lowercase line per project
sprat install-agent   # start `sprat serve` at login (writes a launchd agent; prints how to remove it)
sprat attach [path]   # opt-in Verify: Sprat runs the project's checks when an agent tries to stop
sprat legacy          # the V1 research product
```

`SPRAT_DRY_RUN=1` runs everything (investigations included) but types nothing into any
session and starts no session; what would have been sent goes to `<data>/v4/dry-run.log`.

### How it sees your work (no setup)

- Sessions: `<config>/sessions/*.json` and transcripts under `<config>/projects/`, for every
  Claude config dir: `~/.claude`, every `~/.claude-*`, and the `CLAUDE_CONFIG_DIR` of any
  running process wherever it points (remembered after it exits). Accounts that share one
  `sessions/` folder through symlinks are told apart by each process's own `CLAUDE_CONFIG_DIR`,
  so usage limits, investigations and resumes use the right account.
- Roadmaps: `docs/PAUSE.md`, superpowers plans (tasks done when their quoted commit landed),
  `ROADMAP.md`/`PLAN.md`/`TODO.md`, spec build phases, git history. Press `w` on a project to
  confirm its roadmap into `.sprat/roadmap.md`, which you can edit and which wins.
- Delivery into a live session: cmux (`send`/`send-key`, only into an empty prompt with no
  dialog open), tmux, or the clipboard. Never the internal peer socket
  ([docs/phase-v4/00-spikes.md](docs/phase-v4/00-spikes.md)). cmux only answers processes
  it started; `sprat serve` under launchd borrows the socket capability cmux gave a live
  Claude session it runs. The board's header says `✗ cmux refused sprat` when that fails.
- Usage limits: the main thread's limit message, and background agents that failed on a
  limit (their task notification). The later reset wins.
- Several accounts can work on one project (same folder, different `CLAUDE_CONFIG_DIR`).
  A project is limited only while all of them are; when a session's account runs out and
  another account that has worked on the project is free, its ticket offers `f continue on
  <account>`, which forks the conversation there in a new cmux workspace. Accounts with their
  own `projects/` folder get a copy of the session's transcript first, so the conversation
  carries on instead of starting over.
- A limit belongs to the login that hit it (`oauthAccount` in the dir's `.claude.json`).
  `/login` to another account, or any session on the dir working again before the reset,
  resumes the dir's paused sessions straight away.

### Talking to a session from the board

Open a session (⏎ on it in a project) and its screen is the session: its own terminal,
mirrored live from its cmux tab (`tab` switches to the condensed transcript). Type to write
to it and ⏎ sends your words as typed, waiting until its prompt is free; the NOW band shows
the message going out. When the session shows a dialog (a permission question, a menu),
1–9, ↑↓ and ⏎ answer it from the board. `ctrl-o` jumps to the session's own tab.

### What Sprat is doing

The header counts every live agent: how many are working, how many just finished a turn
(their next prompt is someone's move), how many tickets need you. The NOW band shows every
job and investigation while it runs (investigating a stall, moving a session to another
account, sending a message), for how long, and how it ended. `a` opens the activity screen:
everything Sprat did, its processes, and the programs it runs (`ps`, `git`, `cmux`, `claude`)
with how often and how long.

`p` on the activity screen opens Sprat's processes, live, four ways:

- **Grouped** (the default): every Claude session under its project, with its state and
  the last thing its watcher process read ("read 12 new lines · now"); the parts that
  decide and deliver (the engine, the publisher, the line to your board, the tasks
  running investigations and jobs); and the latest change followed hop by hop from Claude
  to your screen, sparks running along the hops while it is new.
- **Pulse** (`p`): each live session's last two minutes as a lane, newest on the right: a
  mark for each edit, command, read, reply and question, a bar while a command runs, and
  the latest thing at the end. Editing-and-testing, a long build and waiting-on-you each
  have their own rhythm. Below, the engine's checks and your board's redraws.
- **Fish tank** (`f`): every live session as a fish. Working fish are big and quick, idle
  ones drift, one that needs you hangs at the surface, one that finished rests on the
  sand; bubbles rise when its watcher reads something new.
- **Tree** (`t`): the raw supervision tree inside `sprat serve`, how hard each process is
  working, what just started or ended, and the messages they send each other, drawn as
  lanes a dot travels from sender to receiver. Messages are traced only while it is open.

### Talking to Sprat (hold space)

Hold space, speak, let go. On the board a few spoken commands work: "open studio", "talk to
studio-67", "activity", "help", "send it", "back". On a session's screen your words go into
the message line, appearing as you speak; say "send" to send them, "cancel" to drop them.
Speech becomes text on this Mac (sox records, whisper.cpp transcribes with a local model);
nothing is sent anywhere. `sprat voice setup` installs what is missing, asking first.

### Autonomy, per project (`A` on the board)

| Level | What Sprat does |
|---|---|
| `watch` | detects and investigates; acts on nothing |
| `propose` | every decision waits for you to press `f` (a new project's first day) |
| `act` | delivers unblocks, answers from written decisions, reassignments; ticks items it verified done (revertible with `u`) |
| `act+resume` | also starts a session itself for stalled projects and limit resumes of dead sessions |

Guardrails are code, not prompts (`Sprat.PM.Policy`): owner-only content is refused, one
message per session per 20 min, three investigations per finding, daily budgets ($3 per
project, $15 fleet by default), never the same message twice, never while you are typing.

## Development

Requires Elixir 1.19.5 / OTP 28.3.1 (see `.tool-versions`).

```sh
mix deps.get
mix test                          # unit, property and engine integration tests
SPRAT_REAL_REPOS=~/code/a:~/code/b mix test --only real_machine   # read-only, against real sessions and repos
mix sprat.board_demo              # the Pass board with fixture data
mix run -e 'Sprat.CLI.main(["status"])'

MIX_ENV=dev mix release --overwrite
_build/dev/rel/sprat_rt/bin/sprat          # the command users type
```

## Layout

```text
lib/sprat/observer/   sessions, transcripts, usage limits, session state, detector, store
lib/sprat/roadmap/    roadmap sources, parsers, .sprat/roadmap.md, position, progress
lib/sprat/pm/         PM runner (claude -p), policy, MCP tool server
lib/sprat/nudge/      delivery into live sessions (cmux, tmux, clipboard)
lib/sprat/engine/     the engine's snapshot, commands, runtime (daemon/client), notifier
lib/sprat/terminal/board*  the Pass TUI
lib/sprat/brief.ex    the daily brief
```

## Documents

| Document | What it is |
|---|---|
| [docs/spec-v4.md](docs/spec-v4.md) | **Current.** V4: Sprat as PM for every Claude Code agent; the Pass TUI |
| [docs/phase-v4/00-spikes.md](docs/phase-v4/00-spikes.md) | V4 Phase 0: transcript shapes, delivery, usage-limit formats, PM runtime |
| [PRODUCT.md](PRODUCT.md) | Product record for design work |
| [docs/spec-v3.md](docs/spec-v3.md) | V3 supervisor (goals, checks, Stop gate); partly superseded, Verify built from it |
| [docs/spec-v1.md](docs/spec-v1.md), [docs/spec-v2.md](docs/spec-v2.md) | The research product and its build phase (parked behind `sprat legacy`) |
| [docs/spec-full.md](docs/spec-full.md) | The long-term target architecture V1 was cut down from |

## Licence

MIT. See [LICENSE](LICENSE). Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).
