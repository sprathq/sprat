#!/usr/bin/env bash
# Drip-feed the experiment across Codex quota windows, one task at a time.
#
#   ./drip.sh runs/<run-dir> [retry-minutes]
#   tail -f runs/<run-dir>/drip.log
#   kill $(cat runs/<run-dir>/drip.pid)
#
# A task is done when its judge.json exists. Each attempt resumes one task and
# spends whatever quota is available; when the limit is hit the harness records
# the failures and exits, and we wait before trying the same task again. Running
# one task at a time means quota buys whole finished tasks rather than a thin
# layer across all ten.
set -u
cd "$(dirname "$0")"
RUN_DIR=${1:?usage: drip.sh runs/<run-dir> [retry-minutes]}
SLEEP_MIN=${2:-45}
TASKS=${TASKS:-01 02 03 04 05 06 07 08 09 10}
LOG="$RUN_DIR/drip.log"
mkdir -p "$RUN_DIR"
echo $$ > "$RUN_DIR/drip.pid"
trap 'rm -f "$RUN_DIR/drip.pid"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG"; }

for task in $TASKS; do
  attempt=0
  while [ ! -f "$RUN_DIR/$task/judge.json" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 12 ]; then
      log "task $task: giving up after 12 attempts"
      break
    fi
    log "task $task: attempt $attempt"
    elixir run.exs --tasks "$task" --resume "$RUN_DIR" >> "$LOG" 2>&1
    log "task $task: attempt $attempt exit=$?"
    [ -f "$RUN_DIR/$task/judge.json" ] && break
    log "task $task: incomplete, sleeping ${SLEEP_MIN}m"
    sleep $((SLEEP_MIN * 60))
  done
  [ -f "$RUN_DIR/$task/judge.json" ] && log "task $task: done"
done

log "all tasks attempted; building summary"
elixir run.exs --resume "$RUN_DIR" --skip-judge >> "$LOG" 2>&1
log "finished"
