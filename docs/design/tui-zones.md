# Sprat TUI — zoned full-screen design

Date: 2026-09-18
Status: **superseded** by `docs/spec-v4.md` §10 (The Pass), 23 Nov 2026
Supersedes: `docs/spec-v1.md` §10 "Rendering model" (inline) if accepted

## What changed

V1 §10 specified a Claude Code-style inline UI: output into normal scrollback, a small
live region at the bottom. The owner wants something else:

- **Zones**, one active at a time, with the user jumping between them to see detail.
- **Many agents visible at once**, collapsed by default, expandable to watch one work.
- Colour coding, ASCII icons, and animation where it helps.

Zones with focus cannot be done inline: the page must be addressable, so this is a
full-screen application on the alternate screen.

## What we lose, and what we do about it

| Lost with the alternate screen | Mitigation |
|---|---|
| Terminal scrollback of the session | Sprat owns a scroll buffer per zone (PgUp/PgDn, `g`/`G`, wheel). The session is in SQLite regardless, and `/export` writes Markdown. |
| The transcript remaining on screen after exit | On exit, print a short summary (objective, artifacts, cost, export path) into normal scrollback. |
| Piping output, screen readers | `--plain` stays exactly as it is: line-oriented, no redraws, no alternate screen. `sprat -p` headless too. |
| Native text selection | Kept: mouse reporting stays **off** by default, so terminal selection still works on the visible screen. `m` toggles mouse mode for click-to-focus and wheel scrolling, at the cost of selection while on. |

Nothing in the domain, store or session layers changes. The renderer's pure pieces —
width, Markdown, sanitising, key parsing, composer, glyphs — all carry over.

## Zone map

Six zones. Exactly one holds focus; it shows a bright border and title, the rest are dimmed.

```text
╭─ ❶ Mission ────────╮╭─ ❸ Conversation ─────────────────────────╮╭─ ❹ Inspector ──────╮
│ gym-idea           ││ > shape an idea for independent gyms     ││ [Evidence] Tasks   │
│                    ││                                          ││ Usage  Events      │
│ ✓ Intake           ││ ◆ PM  Three questions change the         ││                    │
│ ▸ Research     2m14││   direction:                             ││ 31 sources         │
│ ○ Analysis         ││   1. Owner-operated or small chains?     ││ 24 verified        │
│ ○ Directions       ││   2. Revenue, or a tool for your gym?    ││  5 blocked         │
│ ○ Brief            ││   3. Any constraint on mobile?           ││  2 unreachable     │
│                    ││                                          ││                    │
│ Budget             ││ > owner operated, revenue, web first     ││ ▸ clubright.co.uk  │
│ $1.42 / $5.00      ││                                          ││   pricing, 2026-03 │
│ ▰▰▰▰▱▱▱▱▱▱ 28%     ││ ◉ Researcher·1  competitor matrix ready  ││ ▸ reddit.com/r/…   │
╰────────────────────╯│   7 products · 12 sources                ││   owner complaints │
╭─ ❷ Agents ─────────╮│                                          │╰────────────────────╯
│ ◆ PM        ⏸ idle ││ ⎿ web_fetch gymcatch.com/sales-1         │╭─ ❺ Detail ─────────╮
│ ◉ Res·1     ✓ done ││   3.1 KB · 2 claims                      ││ (expanded agent    │
│ ◉ Res·2     ⠙ 1m02 ││                                          ││  or source detail) │
│   ⎿ fetching reddit││                                          ││                    │
│ ▲ Analyst   ○ queue││                                          ││                    │
╰────────────────────╯╰──────────────────────────────────────────╯╰────────────────────╯
╭─ ❻ ───────────────────────────────────────────────────────────────────────────────────╮
│ >                                                                                     │
╰───────────────────────────────────────────────────────────────────────────────────────╯
 INSERT · normal mode · $1.42 · 2 running · tab zones · ? help
```

| # | Zone | Holds |
|---|---|---|
| ❶ | Mission | Stage checklist, elapsed per stage, budget meter, mode |
| ❷ | Agents | One card per role instance, collapsed; ↑/↓ to select, Enter expands |
| ❸ | Conversation | User messages and finished agent output, Markdown, scrollable |
| ❹ | Inspector | Tabbed: Evidence · Tasks · Usage · Events (the spec's §10 views) |
| ❺ | Detail | Whatever ❷ or ❹ has selected: an agent's live stream, a source record, a task |
| ❻ | Composer | Input, always reachable |

## Focus and keys

Two modes, shown in the footer, so plain typing is never ambiguous (owner's call:
vim-like modal, with emacs-style chords as the escape hatch):

- **INSERT** (default): keystrokes go to the composer. `Esc` leaves to NAV.
- **NAV**: keystrokes navigate. `i`, `Enter` or `/` returns to INSERT (`/` also opens the command menu).
- **Chords work in both modes**, so a user who never wants to leave INSERT doesn't have to:
  `Alt+1`…`Alt+6` jump to a zone, `Alt+n`/`Alt+p` next/previous zone, `Alt+[`/`Alt+]`
  switch Inspector tab, `Alt+f` opens the flow overlay, `Alt+v`/`Alt+V` page the focused
  zone. Composer editing keeps the emacs bindings already implemented (`Ctrl+A/E/W/U/K`,
  `Alt+←/→`).

| Key | NAV | INSERT |
|---|---|---|
| `Tab` / `S-Tab` | next / previous zone | composer completion |
| `1`…`6` | jump to that zone | — |
| `↑ ↓` / `j k` | move selection or scroll within zone | history (composer) |
| `Enter` | expand or open selection into ❺ | submit |
| `Space` | pin an expanded agent so it stays open | — |
| `PgUp/PgDn`, `g`/`G` | scroll zone | — |
| `[` `]` | previous / next Inspector tab | — |
| `Esc` | collapse, close overlay, or return focus to ❸ | leave to NAV |
| `Ctrl+C` | interrupt the running stage; twice quickly exits | same |
| `S-Tab` (INSERT, empty) | cycle permission mode (normal / auto / plan) | |
| `o` | open the focused view in `$PAGER` | — |
| `m` | toggle mouse mode (wheel + click focus vs native selection) | — |
| `?` | key help overlay | — |

Agent cards accordion: one expands at a time unless pinned with `Space`; pinned cards
share ❺ vertically, oldest evicted when space runs out.

## Colour and icons

Colour always pairs with a glyph and a word, never carries meaning alone (§10 accessibility).

| Role | Colour | Icon | | State | Colour | Icon |
|---|---|---|---|---|---|---|
| Orchestrator | grey | ⌁ | | running | bright | ⠙ (spinner) |
| PM | blue | ◆ | | done | green | ✓ |
| Researcher | green | ◉ | | queued | dim | ○ |
| Analyst | amber | ▲ | | waiting on input | cyan | ? |
| SWE (later) | cyan | ■ | | blocked / failed | red | ! |
| | | | | paused | dim | ⏸ |

`SPRAT_ASCII=1` or a non-UTF-8 locale swaps to `*`, `o`, `^`, `#`, `[x]`, `[ ]`, `(!)`.
`NO_COLOR` drops colour and keeps glyphs and words. Both are already implemented in
`Sprat.Terminal.Glyphs` and carry over.

## Animation

Motion only where it carries information:

| Where | Motion | Rate |
|---|---|---|
| Active agent card | braille spinner | 10 fps |
| Streaming text in ❺ | caret, text appended | coalesced, ≤30 fps |
| Budget meter | fills as cost settles | on change |
| Source counter | count-up over ~200 ms | on change |
| Stage transition | 200 ms highlight pulse on the stage row | once |
| Nothing running | no motion at all | — |

Rules: never animate under `--plain`, `NO_COLOR`, a non-TTY, or when the terminal is
under 80×24; stop all timers when idle so an idle Sprat uses no CPU; every animation is a
pure function of state and a frame counter, so tests assert on frames, not on sleeps.

## Message passing between agents

The team is only legible if you can see the traffic. Three views of the same data, all
driven by real message records (§9 envelopes) — nothing decorative is invented.

### 1. Flow gutter in ❷ Agents

A three-column gutter on the left of the agent list. When a message is admitted, an
envelope glyph travels from the sender's row to the recipient's row, then the recipient
card flashes and changes state.

```text
╭─ ❷ Agents ─────────────────────────╮   ╭─ ❷ Agents ─────────────────────────╮
│    ⌁ Orchestrator      ▸ scheduling│   │    ⌁ Orchestrator      ▸ scheduling│
│ ┌▶ ◆ PM               ✓ handoff    │   │    ◆ PM               ⏸ idle       │
│ │  ◉ Researcher·1     ✓ done       │   │    ◉ Researcher·1     ✓ done       │
│ ✉  ◉ Researcher·2     ○ queued     │ → │    ◉ Researcher·2     ⠙ 0m03  NEW  │
│ │  ▲ Analyst          ○ queued     │   │    ▲ Analyst          ○ queued     │
╰────────────────────────────────────╯   ╰────────────────────────────────────╯
     t=0  assignment leaves PM               t=400ms  Researcher·2 wakes, flashes
```

- The travel takes ~400 ms with easing, at 10 fps, then the arrival flash is ~200 ms.
- Message type sets the glyph and colour: `✉` assignment, `?` clarification, `◆` evidence,
  `⇄` handoff, `✓` review, `⚖` decision, `·` status, `✕` cancel, `!` error.
- Several messages at once stack in the gutter and are labelled `✉×3` rather than racing.
- With animation off, the gutter still shows the last message as a static arrow for
  2 seconds, so the information survives without motion.

### 2. State colour on the cards

Intensity, not just hue, so the change reads at a glance and survives colour blindness:

| State | Colour | Intensity | Glyph |
|---|---|---|---|
| idle | grey | dim | ⏸ |
| receiving (flash, 200 ms) | cyan | bright, reversed | ✉ |
| active | the role's own colour | bright | ⠙ spinner |
| waiting on a tool | role colour | normal | ⋯ |
| waiting on user | cyan | bright | ? |
| blocked / failed | red | bright | ! |
| done | green | normal | ✓ |

An idle agent that receives an assignment goes grey → cyan flash → its own bright role
colour, which is exactly the "it woke up and started working" cue you asked for.

### 3. Flow overlay (`f`)

A whole-team view for when several agents are running: who talks to whom, how much, and
what just moved.

```text
╭─ Message flow ─ mission gym-idea ─ 24 messages ──────────────────────────╮
│                                                                          │
│        ⌁ Orchestrator                                                    │
│         │  ╲                                                             │
│    ✉ 4  │   ╲ ✉ 6                        last:  14:32:06                 │
│         ▼    ▼                           ⌁ → ◉ Res·2   assignment        │
│    ◆ PM ──⇄ 2──▶ ▲ Analyst               14:31:58                        │
│         ╲        ▲                       ◉ Res·1 → ⌁   handoff           │
│      ◆ 3 ╲    ◆ 5│                       14:31:40                        │
│           ▼      │                       ◆ PM → ⌁     status            │
│        ◉ Res·1 ──┘   ◉ Res·2                                             │
│                                                                          │
│  traffic  ▂▃▅▇▅▃▂▁▂▃  last 60s          [a]ll [t]ype filter  esc close   │
╰──────────────────────────────────────────────────────────────────────────╯
```

Edges thicken with volume; an edge lights up for ~1 s when a message crosses it.

### 4. Messages tab in ❹ Inspector

The audit view: every envelope in order — time, sender, recipient, type, correlation id,
acknowledgement state. `Enter` opens the payload in ❺ Detail. Filter by role, by type, or
by task. This is what makes the pretty views trustworthy: the same records, unglamorous.

## Responsive layout

| Width | Layout |
|---|---|
| ≥ 120 cols | Three columns as drawn: ❶❷ left, ❸ centre, ❹❺ right |
| 100–119 | Two columns: ❶❷ left, ❸ centre; ❹❺ become overlays on `4`/`5` |
| 80–99 | Single column ❸ with ❶❷ as a collapsible header strip; others overlay |
| < 80 cols or < 24 rows | One zone at a time, full screen, switched with `1`…`6` |

Zones never shrink below a legible minimum; they drop to overlay instead.

Two implementation notes learned while building the core:

- The narrow-breakpoint Mission "header strip" is a compact summary, deliberately smaller
  than the Mission zone's own minimum, so it must be exempt from the generic min-size
  check rather than overlaid away.
- A resize must force a real screen clear. Damage tracking only writes changed cells, so
  content the terminal left outside the new dimensions is never erased otherwise.

## Implementation

Reused unchanged: `Width`, `Markdown`, `Sanitize`, `Keys`, `Composer`, `Glyphs`,
`Transcript`, the session layer, store and pub/sub.

New, roughly 1,200–1,600 lines:

| Module | Purpose |
|---|---|
| `Terminal.Screen` | Alternate screen, cell buffer, damage-tracked flush (only changed cells written) |
| `Terminal.Layout` | Breakpoints, zone rectangles, overlay placement |
| `Terminal.Zone` | Zone behaviour: render(state, rect, focused?), handle_key, scroll state |
| `Terminal.Focus` | Focus ring, modes, key routing |
| `Terminal.Scrollback` | Bounded per-zone line buffer with search |
| `Zones.Mission`, `Zones.Agents`, `Zones.Conversation`, `Zones.Inspector`, `Zones.Detail` | The five content zones |
| `Zones.Flow` | Message-flow overlay: node placement, edge volume, recent list |
| `Terminal.MessageFlow` | Pure: envelope stream → gutter animation frames and edge lighting |
| `Terminal.Animate` | Frame clock, easing, idle stop |
| `Terminal.Theme` | Role and state palette, ASCII and NO_COLOR fallbacks |

`Terminal.Renderer` keeps its role as sole stdout writer; it gains a cell buffer and
diffing instead of line-append. The existing inline renderer stays as `--inline` for
piping and as a fallback if a terminal can't do the alternate screen.

**Performance budget** (unchanged targets): keypress-to-echo < 50 ms p95 while streaming;
full repaint of a 200×60 screen < 8 ms; idle CPU ≈ 0; 2,000-block session opens < 1.5 s.
The 8 ms repaint figure is this design's own target, not a hard user-facing requirement —
stage 2's zone borders (`Terminal.ZoneFrame`) measure ~9.5 ms fully populated, still well
inside the 50 ms keypress-to-echo budget that actually matters to a person typing; noted
here rather than chased further at the cost of zone content.

**Testing**: zone rendering is pure (state + rect + frame → cells), so snapshot tests need
no terminal. tmux drives the real thing for focus movement, resize across every
breakpoint, alternate-screen entry and exit, and restoration after crash and SIGTERM.

## Estimate

Roughly 1–1.5 weeks with agents: screen and layout core, then zones, then animation and
polish. It does not block the model work; the session layer and pub/sub feed both UIs.
