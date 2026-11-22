# Manual terminal checklist

Run these against a real build of the spike in each terminal listed below.
Automated coverage (`verify.sh`) already proves the logic works under tmux;
this list is for things tmux can't tell you — true rendering, real key
codes from real keyboards, and how each terminal's own emulator behaves.

## Setup (once per terminal)

```sh
cd spikes/terminal
mix deps.get
mix escript.build
./sprat_terminal_spike demo 60
```

Terminals to cover: **iTerm2, Terminal.app, Ghostty, kitty, WezTerm, VS Code
integrated terminal, tmux** (inside any of the above — nested is fine and
worth doing once, since spec §14 calls it out separately).

## Steps

1. **Launch.** Composer box, spinner and footer should appear within well
   under half a second, cursor hidden, no flicker/full-screen clear (you
   should still see your shell prompt above the app in scrollback).
   - Expected: inline, not alternate-screen. Confirm by resizing your
     terminal window bigger after quitting — the whole conversation, plus
     your shell history from before you launched, is still there.
2. **Type while it streams.** Start typing a sentence immediately and keep
   typing for the full 60s. Expected: every keystroke appears with no
   perceptible lag (target: unnoticeable, spec target is <50ms); the
   composer box never garbles, duplicates, or drifts sideways.
3. **Markdown rendering.** Watch a committed paragraph scroll past.
   Expected: headings bold+cyan, bullets, inline code faint, a fenced code
   block dimmed — and once committed, it's never touched again.
4. **Wide characters.** Paste this line into the composer:
   `中文 日本語 한글 🇬🇧🇯🇵 👨‍👩‍👧‍👦 é (e + ́) 🙂`
   Expected: line wraps at a sane point (not mid-character), CJK/emoji take
   two columns each, the flags render as single flag glyphs (not two
   separate letter-in-box symbols), and the family emoji is one glyph, not
   four stacked people. If your terminal's font lacks a glyph, expect a
   tofu box — that's a font issue, not a Sprat bug; note it anyway.
5. **Bracketed paste.** Copy 10+ lines of text from anywhere and paste into
   the composer (Cmd+V / Ctrl+Shift+V). Expected: composer shows
   `[Pasted text #1 +N lines]`, not the raw text; the full text still gets
   used if you had a way to submit it (this spike's demo mode doesn't
   submit, just shows the collapse).
6. **Resize.** While the demo runs, resize the terminal window by dragging.
   Expected: live region re-lays-out within ~250ms, no leftover garbage
   rows, footer still at the bottom.
7. **Composer editing.** Type some text, then try: Ctrl+A/E (start/end —
   this spike doesn't move a visible cursor marker, but shouldn't error or
   drop input), Ctrl+W (delete last word), Ctrl+U (clear line), Backspace,
   arrow keys, Shift+Tab (should not insert a character), Esc (should not
   insert a character either).
8. **Newline vs submit.** Type `\` then Enter — expect a newline inserted,
   composer stays open. Try Alt+Enter (Option+Enter on Mac) — same.
   Try plain Enter — composer clears (this spike does not send anything
   anywhere; that's the "submit" stand-in).
9. **Ctrl+D.** With the composer empty, press Ctrl+D. Expected: clean exit,
   cursor visible again, shell prompt behaves normally, `stty -a` shows
   `icanon` (cooked mode).
10. **Ctrl+C.** ⚠️ Known gap from this spike (see the Phase 0 report): a
    single Ctrl+C currently kills the process outright via a real SIGINT
    instead of the spec's "clear composer / press twice to exit" — note
    whether your terminal leaves anything visibly broken afterward (cursor
    still hidden is the specific thing to check; run `printf '\e[?25h'` to
    fix it if so).
11. **kill -9.** In another terminal, `pgrep -f sprat_terminal_spike` and
    `kill -9 <pid>`. Expected known damage: cursor stays hidden. Try
    `stty sane` (expect it does *not* fix the cursor), then `printf
    '\e[?25h'` or `tput cnorm` or `reset` (expect one of these fixes it).
12. **Permission prompt.** `./sprat_terminal_spike permission` — use
    ↑/↓ to move, Enter to confirm. Expected: `❯` marker moves, no visual
    artifacts, process prints the chosen option number to stderr and exits.

## Results table

Fill in ✅ / ⚠️ (works with caveat, describe) / ❌ per terminal.

| Step | iTerm2 | Terminal.app | Ghostty | kitty | WezTerm | VS Code term | tmux |
|---|---|---|---|---|---|---|---|
| 1. Launch inline, fast |  |  |  |  |  |  |  |
| 2. Type while streaming |  |  |  |  |  |  |  |
| 3. Markdown rendering |  |  |  |  |  |  |  |
| 4. Wide chars / emoji / ZWJ |  |  |  |  |  |  |  |
| 5. Bracketed paste collapse |  |  |  |  |  |  |  |
| 6. Resize |  |  |  |  |  |  |  |
| 7. Composer editing keys |  |  |  |  |  |  |  |
| 8. Newline vs submit |  |  |  |  |  |  |  |
| 9. Ctrl+D exit |  |  |  |  |  |  |  |
| 10. Ctrl+C behavior |  |  |  |  |  |  |  |
| 11. kill -9 damage/fix |  |  |  |  |  |  |  |
| 12. Permission prompt |  |  |  |  |  |  |  |

Notes / terminal-specific quirks:

-
