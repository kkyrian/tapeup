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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/TapeUp"

# MLX's Metal shaders, built from the pinned checkout (needs Xcode's Metal
# Toolchain once: xcodebuild -downloadComponent MetalToolchain). MLX looks
# for them beside the executable.
BUILD_DIR="$PWD/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh "$config" >/dev/null
cp "$(dirname "$bin")/mlx.metallib" "$app/Contents/MacOS/mlx.metallib"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Sign with the first Apple Development identity so macOS keeps the microphone
# and system-audio grants across rebuilds; fall back to ad hoc elsewhere.
# Sign by fingerprint: a keychain can hold two certificates with the same name.
identity="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development/ {print $2; exit}')"
# The shader library sits beside the executable, where everything must be
# signed; codesign signs a non-code file through its extended attributes.
codesign --force --sign "${identity:--}" --timestamp=none "$app/Contents/MacOS/mlx.metallib"
codesign --force --sign "${identity:--}" --timestamp=none "$app"
codesign --verify "$app"
echo "$app"
