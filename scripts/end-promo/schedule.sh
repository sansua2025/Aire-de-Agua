#!/bin/bash
# Sleep until TARGET_TIME then run the end-promo job.
# Usage: TARGET_TIME="2026-05-31 00:01:00" ./schedule.sh
set -euo pipefail

TARGET="${TARGET_TIME:-2026-05-31 00:01:00}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/run-$(date +%Y%m%d-%H%M%S).log"

TARGET_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$TARGET" "+%s")
NOW_EPOCH=$(date "+%s")
SLEEP_SECS=$((TARGET_EPOCH - NOW_EPOCH))

if [ "$SLEEP_SECS" -lt 0 ]; then
  echo "Target time $TARGET is in the past" >&2
  exit 1
fi

{
  echo "Scheduler started at $(date)"
  echo "Target time: $TARGET ($(date -r $TARGET_EPOCH))"
  echo "Sleeping ${SLEEP_SECS}s..."
} | tee "$LOG"

# Use caffeinate to prevent idle sleep until job finishes
exec caffeinate -i bash -c "sleep $SLEEP_SECS && echo '=== Waking at '\$(date)' ===' >> \"$LOG\" && cd \"$HERE\" && /usr/bin/env node run.mjs >> \"$LOG\" 2>&1"
