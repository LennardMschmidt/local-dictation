#!/bin/bash
# Builds LocalDictation.app in release mode, signs it with the local signing identity and installs
# it to /Applications (to ~/Applications when /Applications is not writable for the user, who
# then is no admin). The build copy in build/ is removed after installing and an install in the
# other folder is removed too, so Spotlight and Launchpad show one app. Runs without any dialog. Before that it sets up LM Studio with the cleanup
# model (scripts/setup-lmstudio.sh), which takes a moment only when something is missing.
#
#   scripts/bundle.sh [--no-install] [--adhoc] [--no-lmstudio]
#
# --no-install keeps the signed app in build/LocalDictation.app and installs nothing.
# --adhoc signs without the local identity; macOS then forgets the permissions on every rebuild.
# --no-lmstudio skips the LM Studio setup, for a Mac that uses Claude or Codex only.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
ADHOC=0
LMSTUDIO=1
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --adhoc) ADHOC=1 ;;
    --no-lmstudio) LMSTUDIO=0 ;;
    *) echo "unknown option $arg" >&2; exit 2 ;;
  esac
done

BUNDLE_ID="local.dictation.LocalDictation"
VERSION="0.1.0"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/LocalDictation.app"

if [ "$LMSTUDIO" = 1 ]; then
  scripts/setup-lmstudio.sh || echo "LM Studio setup failed; dictations stay uncleaned until it works" >&2
fi

# The macOS 27 SDK makes SwiftUI's @State a macro whose plugin ships only with Xcode, not with the
# Command Line Tools. Without that plugin the app is built against the newest macOS 26 SDK; the
# app runs the same on macOS 27.
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins"
if [ -z "${SDKROOT:-}" ] && ! ls "$PLUGINS" 2>/dev/null | grep -q SwiftUIMacros; then
  SDK26="$( (ls -d "$(xcode-select -p)"/SDKs/MacOSX26*.sdk 2>/dev/null || true) | sort -V | tail -1)"
  if [ -n "$SDK26" ]; then
    export SDKROOT="$SDK26"
    echo "building against $(basename "$SDKROOT") (no SwiftUI macro plugin in the Command Line Tools)"
  else
    echo "The Command Line Tools have no SwiftUI macro plugin and no macOS 26 SDK; install Xcode or a macOS 26 SDK." >&2
    exit 1
  fi
fi

swift build -c release --product LocalDictation
BIN="$(swift build -c release --show-bin-path)/LocalDictation"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LocalDictation"

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>LocalDictation</string>
  <key>CFBundleDisplayName</key><string>LocalDictation</string>
  <key>CFBundleExecutable</key><string>LocalDictation</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>The Notetaker shows your upcoming meetings so you can start a note for them. The calendar is read on this Mac only.</string>
  <key>NSMicrophoneUsageDescription</key><string>LocalDictation records your voice while you hold Fn and turns it into text on this Mac. Audio never leaves the computer.</string>
</dict>
</plist>
EOF

if [ "$ADHOC" = 1 ]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
else
  KEYCHAIN="$(scripts/signing-identity.sh)"
  # codesign only finds identities in keychains on the search list, so the signing keychain is
  # added for the duration of the signing and the previous list is restored afterwards.
  ORIGINAL=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    ORIGINAL+=("${line//\"/}")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${ORIGINAL[@]}" "$KEYCHAIN"
  trap 'security list-keychains -d user -s "${ORIGINAL[@]}"' EXIT
  codesign --force --sign "LocalDictation Local Signing" --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=1 "$APP"

if [ "$INSTALL" = 1 ]; then
  TARGET_DIR="/Applications"
  OTHER_DIR="$HOME/Applications"
  if [ ! -w "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/Applications"
    OTHER_DIR="/Applications"
  fi
  # Quitting the app ends a running recording without saving it; refuse unless FORCE=1.
  if [ "${FORCE:-0}" != 1 ] && "$(dirname "$0")/recording-running.sh"; then
    echo "not installing: the Notetaker is busy (FORCE=1 to install anyway)" >&2
    exit 3
  fi
  pkill -x LocalDictation 2>/dev/null && sleep 1 || true
  mkdir -p "$TARGET_DIR"
  rm -rf "$TARGET_DIR/LocalDictation.app"
  cp -R "$APP" "$TARGET_DIR/LocalDictation.app"
  # An earlier install in the other folder would show up as a second app.
  if [ -d "$OTHER_DIR/LocalDictation.app" ] && rm -rf "$OTHER_DIR/LocalDictation.app" 2>/dev/null; then
    echo "removed the earlier install in $OTHER_DIR"
  fi
  rm -rf "$APP"
  echo "installed $TARGET_DIR/LocalDictation.app"
fi
