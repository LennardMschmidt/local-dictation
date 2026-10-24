#!/bin/bash
# Runs the unit tests with the Command Line Tools. SwiftPM does not find the Testing framework
# there on its own, so its location is passed to the compiler and the linker. The Command Line
# Tools ship the _Testing_Foundation overlay without module files, so cross-import overlays are off.
set -euo pipefail
cd "$(dirname "$0")/.."
# The app target uses SwiftUI's @State, a macro in the macOS 27 SDK whose plugin only Xcode ships;
# as in bundle.sh, the build falls back to the newest macOS 26 SDK when the plugin is missing.
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins"
if [ -z "${SDKROOT:-}" ] && ! ls "$PLUGINS" 2>/dev/null | grep -q SwiftUIMacros; then
  SDK26="$( (ls -d "$(xcode-select -p)"/SDKs/MacOSX26*.sdk 2>/dev/null || true) | sort -V | tail -1)"
  if [ -n "$SDK26" ]; then export SDKROOT="$SDK26"; fi
fi
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$F/Testing.framework" ]; then
  exec swift test -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
