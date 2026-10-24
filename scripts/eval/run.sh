#!/bin/bash
# Runs every recognition engine over one measurement set and appends the results to
# results-<set>.tsv in the evaluation folder. The sets and their reference texts live outside
# the repo, in ~/Library/Application Support/LocalDictation/eval/ (set1, set2, long).
#
#   scripts/eval/run.sh set2
#   python3 scripts/eval/score.py <eval>/results-set2.tsv <eval>/refs-set2.json <eval>/terms-set2.json -v
set -euo pipefail
EVAL="$HOME/Library/Application Support/LocalDictation/eval"
CLI="$(cd "$(dirname "$0")/../.." && swift build -c release --show-bin-path)/dictate"
SET=${1:-set2}
cd "$EVAL"
for name in turbo large; do
  model=openai_whisper-large-v3-v20240930; [ $name = turbo ] && model=openai_whisper-large-v3-v20240930_turbo_632MB
  python3 -I -c "
import json,os,sys
s=json.load(open(os.path.expanduser('~/Library/Application Support/LocalDictation/settings.json')))
s['asr']['model']=sys.argv[1]; s['asr']['longDictationModel']=''
json.dump(s,open('settings-'+sys.argv[2]+'.json','w'))" "$model" "$name"
done
for cfg in "whisper turbo" "whisper large" "parakeet-ultra turbo" "parakeet-ultra-boost turbo"; do
  set -- $cfg
  "$CLI" --settings "settings-$2.json" --engine "$1" --no-cleanup "$SET"/*.wav 2>/dev/null | sed "s/^/$1-$2\t/" >> "results-$SET.tsv"
done
echo "results in $EVAL/results-$SET.tsv"
