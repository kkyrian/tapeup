#!/usr/bin/env bash
# Builds TapeUp with SwiftPM and assembles a signed TapeUp.app in .build/.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --product TapeUp
bin="$(swift build -c "$config" --show-bin-path)/TapeUp"

app=".build/TapeUp.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/TapeUp"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Sign with the first Apple Development identity so macOS keeps the microphone
# and system-audio grants across rebuilds; fall back to ad hoc elsewhere.
# Sign by fingerprint: a keychain can hold two certificates with the same name.
identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${identity:--}" --timestamp=none "$app"
codesign --verify "$app"
echo "$app"
