#!/usr/bin/env bash
# Builds TapeUp with SwiftPM and assembles a signed TapeUp.app in .build/.
# Usage: scripts/bundle.sh [debug|release]
#
# Signs with TAPEUP_SIGN_IDENTITY when set (a name, a SHA-1 fingerprint, or
# "-" for ad hoc; scripts/release.sh sets it). Otherwise with the "TapeUp
# Release" identity from scripts/make-keys.sh, then the first Apple
# Development identity, then ad hoc, so macOS keeps the microphone and
# system-audio grants across rebuilds wherever it can.
#
# For trying updates locally only: TAPEUP_FEED_URL and TAPEUP_ED_PUBLIC_KEY
# replace the appcast address and the update key in the app.
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
swift build -c "$config" --product TapeUp
products="$(swift build -c "$config" --show-bin-path)"
bin="$products/TapeUp"

app=".build/TapeUp.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin" "$app/Contents/MacOS/TapeUp"

# MLX's Metal shaders, built from the pinned checkout (needs Xcode's Metal
# Toolchain once: xcodebuild -downloadComponent MetalToolchain). MLX looks
# for them beside the executable.
BUILD_DIR="$PWD/.build" .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh "$config" >/dev/null
cp "$products/mlx.metallib" "$app/Contents/MacOS/mlx.metallib"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Sparkle, for updates; ditto keeps the framework's symbolic links.
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"

# One version source: VERSION is both the version people see and the one
# Sparkle compares.
plist="$app/Contents/Info.plist"
cp Resources/Info.plist "$plist"
version="$(tr -d '[:space:]' <VERSION)"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
if [[ -n "${TAPEUP_FEED_URL:-}" ]]; then
  plutil -replace SUFeedURL -string "$TAPEUP_FEED_URL" "$plist"
fi
# The public half of the update key (scripts/make-keys.sh writes it). Without
# it the app runs but does not look for updates.
public_key="${TAPEUP_ED_PUBLIC_KEY:-}"
if [[ -z "$public_key" && -f packaging/sparkle-public-key ]]; then
  public_key="$(tr -d '[:space:]' <packaging/sparkle-public-key)"
fi
if [[ -n "$public_key" ]]; then
  plutil -replace SUPublicEDKey -string "$public_key" "$plist"
fi

# Sign by fingerprint: a keychain can hold two certificates with the same name.
identity="${TAPEUP_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  identity="$(awk '/"TapeUp Release"/ {print $2; exit}' <<<"$identities")"
  [[ -n "$identity" ]] || identity="$(awk '/Apple Development/ {print $2; exit}' <<<"$identities")"
  [[ -n "$identity" ]] || identity="-"
fi
sign() { codesign --force --sign "$identity" --timestamp=none "$@"; }

# Inside out, as Sparkle's documentation signs its framework: the helpers,
# then the framework, then the app around them.
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign -o runtime "$sparkle/XPCServices/Installer.xpc"
sign -o runtime --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign -o runtime "$sparkle/Autoupdate"
sign -o runtime "$sparkle/Updater.app"
sign -o runtime "$app/Contents/Frameworks/Sparkle.framework"
# The shader library sits beside the executable, where everything must be
# signed; codesign signs a non-code file through its extended attributes.
sign "$app/Contents/MacOS/mlx.metallib"
sign "$app"
codesign --verify --deep --strict "$app"
echo "$app"
