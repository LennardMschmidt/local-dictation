#!/bin/bash
# Exits 0 (and says so) when the Notetaker is recording or a meeting is still processing, so
# nothing reinstalls or restarts the app in the middle of it. A running recording only shows in
# the log: it is written to a meeting file at Stop. A launch after the start means the app was
# restarted and that recording is over.
dir="$HOME/Library/Application Support/LocalDictation"
last=$(cat "$dir/app.log.1" "$dir/app.log" 2>/dev/null | grep -E "meeting recording started|meeting saved|meeting recording failed|INFO launched version" | tail -1)
if [[ "$last" == *"recording started"* ]]; then echo "recording running: $last"; exit 0; fi
busy=$(grep -l '"status" *: *"\(transcribing\|summarizing\|recording\)"' "$dir"/meetings/*.json 2>/dev/null | head -1)
if [ -n "$busy" ]; then echo "meeting processing: $(basename "$busy")"; exit 0; fi
echo "idle"; exit 1
