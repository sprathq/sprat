# Sprat

The product manager for every Claude Code agent on your machine.

[Website](https://sprat.dev) · [Docs](https://sprat.dev/docs) · [Install](#install) · [MIT licence](LICENSE)

![The Sprat board: every project, what needs you, what Sprat is doing](https://sprat.dev/images/screens/board.webp)

Sprat watches every Claude Code session you run, knows where each project stands on its
roadmap, notices when an agent or a project stops moving, and gets it moving again itself:
it checks the roadmap and the decisions already written down, searches your memory and how
the same problem was solved in your other projects, researches on the web, then unblocks
the agent, answers its question from what was decided, or hands it the next unblocked item.
It continues sessions when a usage limit resets. Only what is genuinely yours (credentials,
money, scope, irreversible actions, judgement calls nobody wrote down) reaches you.

Local and single user, on macOS and Linux. Nothing you work on is sent to sprat.dev.

## Install

```sh
curl -fsSL https://sprat.dev/install.sh | sh     # into ~/.local/lib/sprat, linked as ~/.local/bin/sprat
brew install sprathq/tap/sprat                   # or with Homebrew
```

Every build bundles its own Erlang runtime; you do not need Elixir. Sprat needs
[Claude Code](https://code.claude.com/docs/en/overview) (its investigations run
`claude -p` on your account), and [cmux](https://cmux.com) or tmux to type into live
sessions (without either it falls back to the clipboard).

Then:

```sh
sprat install-agent   # macOS: start `sprat serve` at login (a launchd agent)
sprat                 # open the board
```

On Linux, run `sprat serve` yourself (a systemd user service, or a spare terminal); the
board works without it too, but then stops watching when you close it.

## Use

```sh
sprat                 # the Pass: a board of every project, what needs you, what Sprat is doing
sprat serve           # the observer/PM as a daemon; boards connect over its socket and get every change pushed
sprat status          # one line per project: roadmap position, last progress, live sessions
sprat brief           # today's brief, one lowercase line per project
sprat install-agent   # start `sprat serve` at login (writes a launchd agent; prints how to remove it)
sprat voice setup     # talk to the board: installs sox and whisper.cpp and fetches the model, asking first
sprat attach [path]   # opt-in Verify: Sprat runs the project's checks when an agent tries to stop
sprat detach [path]   # remove that Stop hook
sprat legacy          # the V1 research product (parked)
```

On the board, `?` explains the screen you are on. The keys you will use most: `←→`
tickets, `↑↓` projects, `⏎` open, `f` do what the ticket proposes, `x` dismiss, `space`
hold to talk, `a` activity, `b` brief, `/` commands (`/settings`, `/findings`, `/nudges`,
`/add <path>`, `/stats`), and on a project `A` autonomy, `r` its roadmap, `w` confirm it.

`SPRAT_DRY_RUN=1` runs everything (investigations included) but types nothing into any
session and starts no session; what would have been sent goes to `<data>/v4/dry-run.log`.
`<data>` is `~/Library/Application Support/sprat` on macOS and `~/.local/share/sprat` on
Linux.

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
mirrored live from its cmux tab. `↑↓` and `pgup`/`pgdn` scroll back through its history;
scrolling to the bottom follows it live again. Type to write to it and ⏎ sends your words as
typed, waiting until its prompt is free; the NOW band shows the message going out. When the
session shows a dialog (a permission question, a menu), 1–9, ↑↓ and ⏎ answer it from the
board. `ctrl-o` jumps to the session's own tab.

`tab` cycles the terminal, the condensed transcript and the **recap**: what the session did
over the last 1, 4, 12 or 24 hours (`←→`). It is read from the session's transcript and its
subagents' tool calls, without a model: the prompts from you and from Sprat, where each turn
ended, the repositories it worked in (a session started in one folder that works in another
repo shows that repo), its commits, failed test runs and usage limits.

A session that has gone quiet says why on its row and on its screen (it finished its turn,
it asked you something, it waits for your ok to run a command, it hit a usage limit, you
are typing there) and what Sprat will do about it next. When Sprat writes to a session, it
names a roadmap item only when the session's own recent conversation or branch shows it is
working on it; otherwise it asks it to continue from where it stopped.

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

### Settings, privacy and cost

`/settings` on the board sets autonomy, the PM's budgets and accounts. Investigations run
`claude -p` on your own Claude account, so they cost what any Claude Code use costs; the
daily caps above bound it. Everything else (watching, the board, voice) runs on your
machine and costs nothing. Sprat sends nothing to sprat.dev.

| Environment | Effect |
|---|---|
| `SPRAT_DRY_RUN=1` | do everything but type into sessions or start them |
| `SPRAT_PM_DISABLED=1` | no investigations at all: watch and report only |
| `SPRAT_CLAUDE_DIRS=a:b` | watch exactly these Claude config dirs instead of discovering them |
| `SPRAT_CLAUDE_BIN=path` | the `claude` binary investigations run |
| `NO_COLOR=1`, `SPRAT_ASCII=1` | no colour; ASCII glyphs only |
| `SPRAT_REDUCED_MOTION=1` | no animation on the board |
| `SPRAT_TZ=Europe/London` | the time zone for the board's clock and dates |
| `SPRAT_DATA_DIR=path` | keep Sprat's data somewhere else |

### Update and uninstall

```sh
curl -fsSL https://sprat.dev/install.sh | sh     # update: the installer replaces the version in place
brew upgrade sprat                               # or with Homebrew

launchctl unload -w ~/Library/LaunchAgents/dev.sprat.serve.plist; rm -f ~/Library/LaunchAgents/dev.sprat.serve.plist
rm -rf ~/.local/lib/sprat ~/.local/bin/sprat     # the installer's files (your data stays in <data>)
brew uninstall sprat                             # or with Homebrew
```

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
lib/sprat/engine/     the engine: snapshot, commands, runtime (daemon/client), publisher, socket,
                      process map and tracer (the processes screen), notifier
lib/sprat/terminal/board*  the Pass TUI (board, keys, help, the processes screen's pulse and tank)
lib/sprat/voice/      hold-to-talk: recording, local transcription, spoken commands
lib/sprat/verify/     opt-in Verify: the Stop hook and its checks
lib/sprat/brief.ex    the daily brief
```

## Documents

| Document | What it is |
|---|---|
| [docs/spec-v4.md](docs/spec-v4.md) | **Current product.** V4: Sprat as PM for every Claude Code agent; the Pass TUI |
| [docs/spec-v5-architecture.md](docs/spec-v5-architecture.md) | **Current architecture.** `sprat serve` as an OTP tree: observers, engine, publisher, socket |
| [docs/phase-v4/00-spikes.md](docs/phase-v4/00-spikes.md) | V4 Phase 0: transcript shapes, delivery, usage-limit formats, PM runtime |
| [PRODUCT.md](PRODUCT.md) | Product record for design work |
| [docs/spec-v3.md](docs/spec-v3.md) | V3 supervisor (goals, checks, Stop gate); partly superseded, Verify built from it |
| [docs/spec-v1.md](docs/spec-v1.md), [docs/spec-v2.md](docs/spec-v2.md) | The research product and its build phase (parked behind `sprat legacy`) |
| [docs/spec-full.md](docs/spec-full.md) | The long-term target architecture V1 was cut down from |

## Licence

MIT. See [LICENSE](LICENSE). Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).
