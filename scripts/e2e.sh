#!/bin/bash
# Builds the dictate CLI in release mode and runs the end-to-end cases. Needs LM Studio's server
# with the cleanup model unless --no-cleanup is passed. Extra arguments go to e2e.py.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product dictate
exec python3 -I scripts/e2e.py "$@"
