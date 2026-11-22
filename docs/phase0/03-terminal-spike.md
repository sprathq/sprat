# Phase 0 · 03 — Inline terminal spike

Date: 2026-09-17
Status: findings recorded; decision below
Code: `spikes/terminal/` (standalone Mix project, escript). Toolchain:
Elixir 1.19.5 / OTP 28.3.1 via asdf, matching the repo's `.tool-versions`.

## Verdict

**The in-house inline renderer is viable for V1.** Build it as specified in
§10, with three changes to the "Implementation approach" text (below) and
one open risk to close in Phase 1 before relying on it (Ctrl+C).

Automated check: `spikes/terminal/verify.sh` — **15/15 pass** (points 1, 2,
3, 4, 5, 7, 8, 9; point 6 is exercised by the same runs and eyeballed, see
below). Run it yourself: `cd spikes/terminal && mix escript.build &&
./verify.sh`.

## Per-point results

| # | Point | Result | Notes |
|---|---|---|---|
| 1 | Raw input + key parser | **Works** | `:shell.start_interactive({:noshell, :raw})` (OTP 26+) plus a byte-level parser correctly decodes printable UTF-8, Enter, Backspace (0x7F/0x08), arrows, Ctrl+A/E/W/U/K, Ctrl+D, Shift+Tab (`\e[Z`), and disambiguates plain Esc from an escape sequence with a 40ms timeout. Two real bugs found and fixed during the spike (see below) — the *design* is sound, the first implementation was not. |
| 2 | Bracketed paste | **Works** | `\e[200~ … \e[201~` parsed as one paste event; a >3-line paste collapses to `[Pasted text #1 +N lines]` in the composer. |
| 3 | Single renderer process, live-region redraw | **Works, with a real gotcha** | One GenServer is the only stdout writer. Cursor-up-N-and-clear works correctly **once you (a) count physical terminal rows, not logical lines, (b) leave one spare column so no line exactly fills the terminal width, and (c) join lines with `\r\n`, not `\n`.** Missing any one of these three produced visible corruption in tmux — see "What broke" below. |
| 4 | 200 tok/s Markdown stream, paragraph commit, spinner, ⏺/⎿, latency | **Works** | Earmark → ANSI per committed paragraph; raw tokens shown live, wrapped and re-rendered as Markdown on commit. Repaints coalesced to 33ms (≈30fps). **Keypress-to-echo latency while streaming: p50 ≈ 6–33ms, p95 ≈ 6–35ms, max ≈ 34ms** across several runs (target: p95 < 50ms) — comfortably inside target, measured with the composer actively receiving keystrokes for the full run. |
| 5 | Resize: poll + SIGWINCH | **Works (poll only)** | `:io.columns/0` + `:io.rows/0` polled every 250ms and on render; a 250ms poll detects a `tmux resize-window` reliably. **SIGWINCH is confirmed not usable**: `:os.set_signal(:sigwinch, :handle)` returns `:ok` but is a no-op — no message ever arrives, and `System.trap_signal(:sigwinch, ...)` raises `FunctionClauseError` (sigwinch isn't in Elixir's supported signal set at all). The spec's polling-based design is correct and is the only option. |
| 6 | Display width: CJK, emoji (ZWJ, flags), combining marks | **Works** | Used `String.graphemes/1` (Unicode UAX #29 extended grapheme clustering — already correctly groups ZWJ sequences and flag pairs into one cluster) plus a curated width-ranges table (the classic wcwidth.c wide-ranges list + common emoji blocks) to classify each cluster as 0/1/2 cells. Verified visually: `中文 😀 🇬🇧 👨‍👩‍👧‍👦` renders as single correctly-sized glyphs and wraps at sane boundaries in the demo. Curated, not the full Unicode East Asian Width / emoji-data.txt tables — good enough to prove the approach; V1 should vendor the real tables (see "Changes to §10" below). |
| 7 | Numbered permission prompt | **Works** | 1/2/3 with `❯` selection, ↑/↓ moves it, Enter confirms, Esc closes. Verified end to end via tmux (select option 3, confirm the process reports `selected=3`). |
| 8 | Terminal restoration | **Works, except Ctrl+C — see below** | Normal exit, Ctrl+D (composer empty), an exception raised inside the renderer, and `SIGTERM` (`kill -TERM`) all restore cooked mode, hide→show cursor, and disable bracketed paste, via a `try/rescue/after` around the app plus a `System.trap_signal(:sigterm, ...)` and `System.at_exit/1` belt-and-braces. `kill -9`: **documented, real damage** — the cursor stays hidden (confirmed via tmux's `cursor_flag`), and **`stty sane` does not fix it** (confirmed — cursor stays hidden after `stty sane`); an explicit `printf '\e[?25h'` / `tput cnorm` / `reset` is required. Ctrl+C: **does not work as specified — see below, this is the one open risk.** |
| 9 | Untrusted-text sanitiser | **Works** | Regex-stripped CSI/OSC sequences and C0/C1 control bytes from simulated tool output before rendering, keeping `\n`/`\t`. Verified with a fixture string containing color codes, a title-set OSC sequence, cursor-hide, and stray control bytes — all stripped, content intact. |

## The one open risk: Ctrl+C

**Finding, confirmed empirically:** under `:shell.start_interactive({:noshell,
:raw})`, Ctrl+C is **not delivered as byte 0x03 to the application at all**.
It fires a genuine OS-level `SIGINT` that terminates the BEAM via the
default action before any Elixir code — including a `System.trap_signal`
handler — gets a chance to run. Two things confirm this isn't fixable from
inside the app as currently structured:

1. Sending Ctrl+C to a running "log every keystroke" build never logs a
   `:ctrl_c` event; the process just dies and the shell prompt returns.
2. `System.trap_signal(:sigint, ...)` raises `FunctionClauseError` —
   `:sigint` is not one of the signals Elixir's trap API accepts at all, so
   there is no way to intercept it from user code the way `:sigterm` is
   handled.

A layered `stty -isig` after `:shell.start_interactive` did **not**
observably fix delivery in this spike (Ctrl+C still killed the process
immediately) — worth a deeper look in Phase 1, but not resolved here.
Practical consequence: **a stray Ctrl+C currently leaves the terminal
visibly damaged** (cursor stuck hidden, same class of damage as `kill -9`,
confirmed via the same `cursor_flag` check), because the SIGTERM-only trap
and the `try/after` don't run for an OS-delivered SIGINT.

**Recommendation for Phase 1** (pick one, both are small):

- **(a)** Before/instead of `:shell.start_interactive`, put the tty into
  raw mode with a full `stty raw -echo` (which by POSIX definition also
  clears ISIG), and confirm Ctrl+C then arrives as byte 0x03 like every
  other control character. This is what the spec's §10 already lists as a
  documented fallback path (`enable_raw!/0` in this spike already falls
  back to it when `:shell.start_interactive` errors) — Phase 1 should just
  verify it fixes ISIG specifically and consider making it the primary
  path rather than a fallback.
- **(b)** If (a) doesn't pan out, accept SIGINT-as-immediate-exit for V1
  (losing the "clear composer" / "press twice within 2s" nuance from spec
  §10 Keybindings, which becomes a V1.x nice-to-have), and make sure the
  terminal-restore path also runs for it — e.g. wrapping the whole `main/1`
  in a supervisor OTP process whose `Process.flag(:trap_exit, true)` +
  linked children still doesn't help for a real SIGINT killing the whole
  VM; the actual fix is (a).

Either way, this must be closed and re-verified before Phase 1 exit — it's
the only point-8 sub-case that doesn't currently meet the spec.

## What broke building this (useful for whoever builds the real renderer)

Three real, non-obvious bugs, each one worth carrying forward as a design
note into the actual implementation:

1. **UTF-8 input reads must bypass `:standard_io`'s text mode.**
   `IO.binread(:stdio, 1)` reads through Erlang's unicode-aware io server;
   the instant a multi-byte UTF-8 sequence starts, a 1-byte read fails
   (looks like EOF) because the server tries to decode one byte as a whole
   codepoint. Fix: open `/dev/stdin` directly in `:raw` + `:binary` mode
   (`File.open("/dev/stdin", [:read, :raw, :binary])`) and read from that,
   bypassing the io-server text layer entirely; do UTF-8 assembly by hand
   in the key parser (already required anyway, for escape-sequence
   disambiguation). Setting `:io.setopts(:standard_io, encoding: :latin1)`
   "fixes" the input side but breaks Unicode *output* (`IO.write` then
   emits `\x{XXXX}` literal escapes instead of the actual bytes) — don't do
   that.
2. **Raw mode disables output post-processing too.** `stty raw` (and
   whatever `:shell.start_interactive`'s raw mode does under the hood)
   turns off `ONLCR`, so a bare `\n` moves the cursor down one row *without*
   returning it to column 0. Every line written by the renderer drifted
   further right each repaint — looked like the live region "raining"
   diagonally down the screen over several seconds. Fix: join and terminate
   every line with `\r\n`, not `\n`, anywhere the renderer writes to a raw
   terminal.
3. **Cursor-up-N-and-clear must count physical rows, not logical lines,
   and must never write exactly `cols` characters.** `\e[nA` moves the
   cursor up N *physical* terminal rows; a logical line whose visible width
   equals or exceeds the terminal width either wraps into 2+ physical rows,
   or — worse — leaves the cursor in a "deferred wrap" state at the exact
   last column that behaves inconsistently across terminals on the next
   `\n`. Fix: compute physical height as `sum(ceil(visible_width(line) /
   cols))` per repaint (not `length(lines)`), and always draw into
   `cols - 1`, never `cols`, leaving one spare column. All three bugs
   compound: fixing only one still produced visible corruption.

None of these are exotic — they're the standard gotchas any raw-terminal
renderer runs into (Ink, Bubbletea, and Claude Code's own TUI all handle
exactly these three) — but they are not mentioned in spec §10's
"Implementation approach" and would have bitten Phase 1 hard without a
spike to surface them first.

## `mix run` vs escript vs release

Confirmed: **`mix run -e "..."` did *not* break raw stdin** in this OTP
28.3.1 / Elixir 1.19.5 setup — contrary to the caution in this task's
brief, a quick key-logging test via `mix run -e` correctly captured
keystrokes. That said, escript remains the right choice for V1, on
different grounds:

- **Startup latency.** `./sprat_terminal_spike sanitize` (escript, trivial
  workload): ~0.21s wall. `mix run -e "IO.puts(1)"`: ~0.46s wall — over 2x
  slower, and that's before the real app's dependency tree loads. Spec
  §16's "launch to usable composer < 500ms p95" target is comfortably
  inside reach for escript/release; tight-to-risky for anything that goes
  through Mix's project bootstrapping.
- **Fewer moving parts in production.** A `mix release`/escript binary
  doesn't need the project's `mix.exs`, dependency resolution, or compile
  step at runtime — matches spec §13's Burrito-packaged single-file binary
  story directly. `mix run` is a dev convenience, not a deployment target,
  independent of the stdin question.

**Recommendation: build and test Sprat against `mix escript.build` /
`mix release` from day one, never `mix run`, in Phase 1+.** This spike's
own `verify.sh` does exactly that.

## Changes to spec §10 "Implementation approach"

1. Add the three rendering gotchas above (physical-row height, `\r\n`
   joins, never-fill-the-last-column) as explicit implementation notes —
   they are not obvious from "move cursor up, clear to end, repaint" and
   cost real debugging time even in a 1,200-line spike.
2. Change "raw terminal mode (`:shell.start_interactive({:noshell,
   :raw})`, OTP 26+)" to also specify **how Ctrl+C is handled** — either
   name the `stty raw -echo` (ISIG-clearing) path as primary, or
   explicitly accept SIGINT-as-immediate-exit as V1's Ctrl+C behavior. As
   written, §10's Ctrl+C keybinding ("clear composer; twice within 2s to
   exit") is not achievable with the literal implementation note as given.
3. Confirm "resize polled ... since the BEAM does not deliver SIGWINCH" —
   this spike found stronger evidence than "doesn't deliver": SIGWINCH is
   not even in Elixir's `System.trap_signal/3` supported signal set, so
   there's no future-proofing available here short of a NIF or port
   program. Worth stating plainly so nobody spends Phase 1 time looking
   for a signal-based alternative.
4. §10 doesn't mention UTF-8 input read semantics — add a line: input must
   be read via a raw, binary-mode file descriptor, not
   `IO.binread(:stdio, ...)` on the default io device, or multi-byte input
   silently breaks.

## Rough LOC and viability

```
lib/sprat/spike/sanitize.ex    21
lib/sprat/spike/markdown.ex    80
lib/sprat/spike/wcwidth.ex     84
lib/sprat/spike/demo.ex        89   (demo-only, not part of the real app)
lib/sprat/spike/terminal.ex   104
lib/sprat/spike/input.ex      176
lib/sprat/spike/cli.ex        252   (mostly diagnostic subcommands for this spike)
lib/sprat/spike/renderer.ex   433
-----------------------------------
total                        1239
```

Excluding the demo-only and spike-diagnostic code, the actual renderer
stack (input parser, terminal lifecycle, width table, Markdown-to-ANSI,
sanitiser, and the live-region renderer) is **≈900 LOC** to cover input
parsing, bracketed paste, a coalesced live-region redraw, Markdown
rendering, wide-character width, and terminal lifecycle safety. That is a
small, auditable amount of code for what it buys — **the in-house approach
is viable for V1**, no TUI framework needed. TermUI was not evaluated
further: nothing in this spike suggested the in-house renderer is
insufficient, and pulling in a framework would trade ~900 LOC of code this
team fully understands for a dependency whose inline-rendering guarantees
would need their own spike anyway.

## Test artifacts

- `spikes/terminal/verify.sh` — automated tmux-driven test suite, 15/15
  passing, covers points 1, 2, 3, 4, 5, 7, 8, 9.
- `spikes/terminal/MANUAL-CHECK.md` — step list + results table for the
  owner to run across iTerm2, Terminal.app, Ghostty, kitty, WezTerm, VS
  Code's terminal, and tmux (not run as part of this automated pass — no
  access to those GUIs from this environment).
