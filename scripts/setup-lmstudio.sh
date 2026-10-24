#!/bin/bash
# Sets up LM Studio with the cleanup model, so dictations are cleaned up on this Mac:
#   1. installs LM Studio when /Applications has none: with Homebrew when it is there, otherwise
#      from the official download (lmstudio.ai, the latest Apple silicon build);
#   2. installs its command line tool `lms` to ~/.lmstudio/bin, where the app looks for it;
#   3. downloads the model (about 2.5 GB) when it is not on disk yet.
# Every step is skipped when its result is already there, so the script can run on every build.
#
#   scripts/setup-lmstudio.sh [model]
set -euo pipefail

MODEL="${1:-qwen/qwen3-4b-2507}"
APP="/Applications/LM Studio.app"
LMS="$HOME/.lmstudio/bin/lms"
BUNDLED_LMS="$APP/Contents/Resources/app/.webpack/lms"
DOWNLOAD="https://lmstudio.ai/download/latest/darwin/arm64"

if [ ! -d "$APP" ]; then
  echo "LM Studio: installing"
  if command -v brew >/dev/null 2>&1; then
    brew install --cask lm-studio
  else
    TMP="$(mktemp -d)"
    trap 'hdiutil detach "$TMP/mount" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT
    curl -fL --progress-bar -o "$TMP/LM-Studio.dmg" "$DOWNLOAD"
    hdiutil attach "$TMP/LM-Studio.dmg" -nobrowse -quiet -mountpoint "$TMP/mount"
    cp -R "$TMP/mount/LM Studio.app" /Applications/
  fi
fi

if [ ! -x "$LMS" ]; then
  echo "LM Studio: installing the lms command line tool"
  "$BUNDLED_LMS" bootstrap -y
fi

if ! "$LMS" ls --json 2>/dev/null | grep -q "\"$MODEL\""; then
  echo "LM Studio: downloading $MODEL (about 2.5 GB)"
  "$LMS" get "$MODEL" -y
fi
echo "LM Studio: ready with $MODEL"
