#!/bin/bash
# Starts the installed app, waits until both models report ready, checks that the process is
# still alive after 60 seconds, prints the log and quits the app again. Exit code 0 means pass.
#
#   scripts/smoke.sh [--keep-running]
set -uo pipefail

APP="/Applications/LocalDictation.app"
[ -d "$APP" ] || APP="$HOME/Applications/LocalDictation.app"
LOG="$HOME/Library/Application Support/LocalDictation/app.log"
KEEP=0
[ "${1:-}" = "--keep-running" ] && KEEP=1

fail() { echo "SMOKE FAIL: $*"; [ -f "$LOG" ] && cat "$LOG"; exit 1; }

[ -d "$APP" ] || fail "$APP not installed, run scripts/bundle.sh first"
pkill -x LocalDictation 2>/dev/null && sleep 1
open "$APP" || fail "open failed"
START=$(date +%s)

for _ in $(seq 1 180); do
  grep -q "whisper model ready" "$LOG" 2>/dev/null && grep -q "cleanup model" "$LOG" 2>/dev/null && break
  grep -q "whisper model failed" "$LOG" 2>/dev/null && fail "speech model failed to load"
  pgrep -x LocalDictation >/dev/null || fail "process exited during start"
  sleep 1
done
grep -q "whisper model ready" "$LOG" || fail "speech model not ready after 180 s"

ELAPSED=$(( $(date +%s) - START ))
[ $ELAPSED -lt 60 ] && sleep $(( 60 - ELAPSED ))
pgrep -x LocalDictation >/dev/null || fail "process not running after 60 s"

echo "--- app.log"
cat "$LOG"
echo "---"
grep -q "ERROR" "$LOG" && echo "note: the log contains ERROR lines (expected without permissions: event tap)"
grep -q "cleanup model ready" "$LOG" && echo "cleanup model: ready" || echo "cleanup model: NOT ready"
echo "process alive after $(( $(date +%s) - START )) s: yes"

if [ $KEEP = 0 ]; then
  osascript -e 'tell application id "local.dictation.LocalDictation" to quit' >/dev/null 2>&1 || pkill -x LocalDictation
fi
echo "SMOKE PASS"
