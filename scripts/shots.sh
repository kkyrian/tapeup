#!/usr/bin/env bash
# Renders the README's pictures and its animation from the real panel with
# made-up meetings, into .github/images. Shows a window briefly per frame.
# Needs ffmpeg. Usage: scripts/shots.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh debug >/dev/null
out="tmp/shots"
.build/TapeUp.app/Contents/MacOS/TapeUp shots --out "$out" >/dev/null

images=".github/images"
mkdir -p "$images"
for name in people; do
  for look in light dark; do
    cp "$out/$name-$look.png" "$images/$name-$look.png"
  done
done

cp "$out/handoff.png" "$images/"
# GitHub takes a link preview under 1 MB.
sips -s format jpeg -s formatOptions 88 "$out/social.png" --out "$images/social.jpg" >/dev/null
sips -s format png -Z 256 Resources/AppIcon.icns --out "$images/icon.png" >/dev/null

# Ten frames a second; one palette per look, redrawing only what changed.
for look in light dark; do
  gif="$images/flow.gif"
  [ "$look" = dark ] && gif="$images/flow-dark.gif"
  ffmpeg -loglevel error -y -framerate 10 -i "$out/frames/$look-%03d.png" \
    -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$gif"
done
ls -lh "$images"
