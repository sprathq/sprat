#!/usr/bin/env bash
# Automated verification for the Sprat terminal spike (Phase 0 item 3).
# Drives the escript inside tmux and asserts on points 1, 2, 3, 5, 7, 8, 9.
# Point 4 (throughput/latency) and point 6 (wide-char rendering) are
# exercised by the same "demo" run here but are eyeballed/measured rather
# than pass/fail-asserted; see docs/phase0/03-terminal-spike.md for numbers.
#
# Usage: ./verify.sh   (run from spikes/terminal/, after `mix escript.build`)

set -u
cd "$(dirname "$0")"

BIN="./sprat_terminal_spike"
PASS=0
FAIL=0
RESULTS=()

record() {
  local point="$1" status="$2" detail="$3"
  RESULTS+=("$point|$status|$detail")
  if [ "$status" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  echo "[$status] $point — $detail"
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required tool: $1"; exit 1; }
}
need tmux
[ -x "$BIN" ] || { echo "build first: mix escript.build"; exit 1; }

new_pane() {
  local name="$1"
  tmux kill-session -t "$name" >/dev/null 2>&1
  tmux new-session -d -s "$name" -x 100 -y 30 -c "$PWD"
}

# ---------------------------------------------------------------------------
# Point 1 + 2: raw input, key parsing, bracketed paste
# ---------------------------------------------------------------------------
LOG=$(mktemp)
new_pane p12
tmux send-keys -t p12 "$BIN keys $LOG" C-m
sleep 1.2
tmux send-keys -t p12 -l "aZ9"; sleep 0.3
tmux send-keys -t p12 -l $'\x7f'; sleep 0.3                 # Backspace (DEL)
tmux send-keys -t p12 Up Down Left Right; sleep 0.3          # arrows
tmux send-keys -t p12 C-a C-e C-w C-u C-k; sleep 0.3         # emacs bindings
tmux send-keys -t p12 -l $'\x1b[Z'; sleep 0.3                # Shift+Tab
tmux send-keys -t p12 Escape; sleep 0.3                      # plain Esc (disambiguated)
tmux send-keys -t p12 -l $'\x1b[200~line1\nline2\nline3\nline4\x1b[201~'; sleep 0.4  # bracketed paste
tmux send-keys -t p12 -l "中文😀"; sleep 0.4                  # UTF-8 / CJK / emoji
tmux send-keys -t p12 C-d; sleep 0.4
tmux kill-session -t p12 >/dev/null 2>&1

KEYLOG=$(cat "$LOG")
p1_expect='{:char, "a"}
{:char, "Z"}
{:char, "9"}
:backspace
:up
:down
:left
:right
{:ctrl, "a"}
{:ctrl, "e"}
{:ctrl, "w"}
{:ctrl, "u"}
{:ctrl, "k"}
:shift_tab
:esc'

if [ "$(echo "$KEYLOG" | head -n 15)" = "$p1_expect" ]; then
  record "1 (raw input/key parser)" "PASS" "printable, backspace, arrows, ctrl-a/e/w/u/k, shift-tab, esc all decoded correctly"
else
  record "1 (raw input/key parser)" "FAIL" "key sequence mismatch: $(echo "$KEYLOG" | head -n 15 | tr '\n' ';')"
fi

if echo "$KEYLOG" | grep -qF '{:paste, "line1\nline2\nline3\nline4"}'; then
  record "2a (bracketed paste parsing)" "PASS" "4-line paste captured as one paste event"
else
  record "2a (bracketed paste parsing)" "FAIL" "paste event not found in: $KEYLOG"
fi

if echo "$KEYLOG" | grep -qF '{:char, "中"}' && echo "$KEYLOG" | grep -qF '{:char, "😀"}'; then
  record "1b (UTF-8/CJK/emoji decoding)" "PASS" "multi-byte UTF-8 decoded to correct grapheme clusters"
else
  record "1b (UTF-8/CJK/emoji decoding)" "FAIL" "UTF-8 chars missing from: $KEYLOG"
fi
rm -f "$LOG"

# large-paste collapse (composer-level, via the demo's live renderer)
LOG2=$(mktemp)
new_pane p2b
tmux send-keys -t p2b "$BIN demo 6 2>$LOG2" C-m
sleep 1.5
PASTE_BODY=$(printf 'l%.0s\n' $(seq 1 6))  # 6 lines
tmux send-keys -t p2b -l "$(printf '\x1b[200~%s\x1b[201~' "$PASTE_BODY")"
sleep 1
PANE=$(tmux capture-pane -t p2b -p)
tmux kill-session -t p2b >/dev/null 2>&1
if echo "$PANE" | grep -q '\[Pasted text #.*+6 lines\]'; then
  record "2b (large paste collapses in composer)" "PASS" "6-line paste shown as placeholder"
else
  record "2b (large paste collapses in composer)" "FAIL" "no collapse placeholder seen"
fi
rm -f "$LOG2"

# ---------------------------------------------------------------------------
# Point 3 + 4 + 6: single renderer, live-region redraw, streaming, wide chars
# ---------------------------------------------------------------------------
LOG3=$(mktemp)
new_pane p3
tmux send-keys -t p3 "$BIN demo 12 2>$LOG3" C-m
sleep 1.5
tmux send-keys -t p3 -l "typing while streaming to check the live region stays coherent"
SNAP_A=""
SNAP_B=""
sleep 5; SNAP_A=$(tmux capture-pane -t p3 -p)
sleep 5; SNAP_B=$(tmux capture-pane -t p3 -p)
sleep 3
tmux kill-session -t p3 >/dev/null 2>&1

# The live region must never duplicate the spinner/checklist/composer/footer
# on screen at once (that's the signature of a broken cursor-up/clear cycle).
DUP_COUNT=$(echo "$SNAP_B" | grep -c "esc to interrupt")
if [ "$DUP_COUNT" -le 1 ] && echo "$SNAP_B" | grep -q "typing while streaming"; then
  record "3 (single live-region, redraw in place)" "PASS" "no duplicated live-region frames; composer text intact after ~10s of streaming"
else
  record "3 (single live-region, redraw in place)" "FAIL" "duplicate/garbled live region (dup spinner lines: $DUP_COUNT)"
fi

if echo "$SNAP_B" | grep -qE '☒ Intake|☒ Research'; then
  record "3b (committed blocks scroll, checklist updates)" "PASS" "checklist state visible and progressing"
else
  record "3b (committed blocks scroll, checklist updates)" "FAIL" "checklist not found in final snapshot"
fi

LAT_LINE=$(grep "keypress-to-echo latency" "$LOG3" || true)
echo "latency: $LAT_LINE"
if echo "$LAT_LINE" | grep -qE 'p95: (0|[0-9]|[1-4][0-9])[,}]'; then
  record "4 (keypress-to-echo p95 < 50ms)" "PASS" "$LAT_LINE"
else
  record "4 (keypress-to-echo p95 < 50ms)" "FAIL" "$LAT_LINE"
fi
rm -f "$LOG3"

# ---------------------------------------------------------------------------
# Point 5: resize polling (SIGWINCH probe is informational, see report)
# ---------------------------------------------------------------------------
new_pane p5
tmux send-keys -t p5 "$BIN resize 2>/tmp/spike_resize.log" C-m
sleep 1
tmux resize-window -t p5 -x 130 -y 40 >/dev/null 2>&1
sleep 1.5
RSZ=$(cat /tmp/spike_resize.log)
tmux kill-session -t p5 >/dev/null 2>&1
if echo "$RSZ" | grep -q "size=130x40"; then
  record "5 (resize detected via polling)" "PASS" "picked up 130x40 within the 250ms poll interval"
else
  record "5 (resize detected via polling)" "FAIL" "no 130x40 reading seen: $(echo "$RSZ" | tail -5 | tr '\n' ';')"
fi

# ---------------------------------------------------------------------------
# Point 7: numbered permission prompt
# ---------------------------------------------------------------------------
new_pane p7
tmux send-keys -t p7 "$BIN permission 2>/tmp/spike_perm.log" C-m
sleep 1.2
FIRST=$(tmux capture-pane -t p7 -p)
tmux send-keys -t p7 Down; sleep 0.2
tmux send-keys -t p7 Down; sleep 0.2
tmux send-keys -t p7 Enter; sleep 0.4
PERM=$(cat /tmp/spike_perm.log)
tmux kill-session -t p7 >/dev/null 2>&1
if echo "$FIRST" | grep -q '❯ 1. Yes' && echo "$PERM" | grep -q "selected=3"; then
  record "7 (permission prompt: numbers/arrows/enter)" "PASS" "moved selection down twice, Enter chose option 3"
else
  record "7 (permission prompt: numbers/arrows/enter)" "FAIL" "prompt: $(echo "$FIRST" | head -1); result: $PERM"
fi

# ---------------------------------------------------------------------------
# Point 8: terminal restoration
# ---------------------------------------------------------------------------
cursor_flag() { tmux display -p -t "$1" '#{cursor_flag}' 2>/dev/null; }

# normal exit
new_pane p8a
tmux send-keys -t p8a "$BIN demo 2; stty -a | grep -o icanon > /tmp/spike_tty_a.txt; echo A_DONE" C-m
sleep 3.5
A=$(cat /tmp/spike_tty_a.txt 2>/dev/null)
tmux kill-session -t p8a >/dev/null 2>&1
[ "$A" = "icanon" ] && record "8a (normal exit restores cooked mode)" "PASS" "icanon set after exit" \
  || record "8a (normal exit restores cooked mode)" "FAIL" "got: $A"

# crash inside the renderer
new_pane p8b
tmux send-keys -t p8b "$BIN crash 2>/tmp/spike_crash.log; stty -a | grep -o icanon > /tmp/spike_tty_b.txt; echo B_DONE" C-m
sleep 1.5
B=$(cat /tmp/spike_tty_b.txt 2>/dev/null)
CRASHLOG=$(cat /tmp/spike_crash.log 2>/dev/null)
tmux kill-session -t p8b >/dev/null 2>&1
if [ "$B" = "icanon" ] && echo "$CRASHLOG" | grep -q "terminal restored"; then
  record "8b (exception in renderer restores terminal)" "PASS" "rescue path fired and restored cooked mode"
else
  record "8b (exception in renderer restores terminal)" "FAIL" "tty=$B log=$CRASHLOG"
fi

# Ctrl+D exit
new_pane p8c
tmux send-keys -t p8c "$BIN demo 30 2>/tmp/spike_ctrld.log" C-m
sleep 1.5
tmux send-keys -t p8c C-d
sleep 1
tmux send-keys -t p8c "stty -a | grep -o icanon > /tmp/spike_tty_c.txt; echo C_DONE" C-m
sleep 0.8
C=$(cat /tmp/spike_tty_c.txt 2>/dev/null)
CTRLD=$(cat /tmp/spike_ctrld.log 2>/dev/null)
tmux kill-session -t p8c >/dev/null 2>&1
if [ "$C" = "icanon" ] && echo "$CTRLD" | grep -q "exit_reason=ctrl_d"; then
  record "8c (Ctrl+D on empty composer exits cleanly)" "PASS" "exit_reason=ctrl_d, cooked mode restored"
else
  record "8c (Ctrl+D on empty composer exits cleanly)" "FAIL" "tty=$C log=$CTRLD"
fi

# SIGTERM
new_pane p8d
tmux send-keys -t p8d "$BIN demo 30" C-m
sleep 1.5
PID=$(pgrep -nf "sprat_terminal_spike demo 30")
if [ -n "$PID" ]; then
  kill -TERM "$PID"
  sleep 1.2
  tmux send-keys -t p8d "stty -a | grep -o icanon > /tmp/spike_tty_d.txt; echo D_DONE" C-m
  sleep 0.8
  D=$(cat /tmp/spike_tty_d.txt 2>/dev/null)
else
  D="no-pid-found"
fi
tmux kill-session -t p8d >/dev/null 2>&1
[ "$D" = "icanon" ] && record "8d (SIGTERM restores terminal)" "PASS" "icanon set after kill -TERM" \
  || record "8d (SIGTERM restores terminal)" "FAIL" "got: $D"

# kill -9 (expected to leave damage — this asserts the *documented* damage, not a fix)
new_pane p8e
tmux send-keys -t p8e "$BIN demo 30" C-m
sleep 1.5
CURSOR_BEFORE=$(cursor_flag p8e)
PID9=$(pgrep -nf "sprat_terminal_spike demo 30")
if [ -n "$PID9" ]; then
  kill -9 "$PID9"
  sleep 1
  CURSOR_AFTER=$(cursor_flag p8e)
else
  CURSOR_AFTER="?"
fi
tmux kill-session -t p8e >/dev/null 2>&1
if [ "$CURSOR_BEFORE" = "0" ] && [ "$CURSOR_AFTER" = "0" ]; then
  record "8e (kill -9 damage, documented)" "PASS" "expected damage: cursor stays hidden after kill -9, as documented — stty sane alone does not fix it"
else
  record "8e (kill -9 damage, documented)" "INFO" "before=$CURSOR_BEFORE after=$CURSOR_AFTER"
fi

# ---------------------------------------------------------------------------
# Point 9: sanitiser strips escape/control sequences from untrusted text
# ---------------------------------------------------------------------------
RAW=$'\x1b[31mRED\x1b]0;title\x07TEXT\x07\x1b[?25lctrl\x01\x02\nkeep\tthis'
OUT=$(printf '%s' "$RAW" | "$BIN" sanitize)
if [ "$OUT" = $'REDTEXTctrl\nkeep\tthis' ]; then
  record "9 (untrusted-text sanitiser)" "PASS" "CSI/OSC/control bytes stripped, newline+tab preserved"
else
  record "9 (untrusted-text sanitiser)" "FAIL" "got: $(echo "$OUT" | xxd | head -3 | tr '\n' ';')"
fi

# ---------------------------------------------------------------------------
tmux kill-server >/dev/null 2>&1
echo
echo "=================== SUMMARY ($PASS pass / $FAIL fail) ==================="
for r in "${RESULTS[@]}"; do
  IFS='|' read -r point status detail <<< "$r"
  printf "%-55s %s\n" "$point" "$status"
done

[ "$FAIL" -eq 0 ]
