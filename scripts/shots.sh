#!/usr/bin/env bash
# Films the README's journeys from the real panel with made-up meetings and
# renders GitHub's link preview, into .github/images. Each take shows a
# window behind your others for a few seconds; it is recorded on its own,
# so your mouse and windows stay out of it. Needs ffmpeg.
# Usage: scripts/shots.sh [journey,...]   (all of them by default)
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh debug >/dev/null
app=.build/TapeUp.app/Contents/MacOS/TapeUp
images=".github/images"
mkdir -p "$images" tmp/film tmp/shots

$app film --out tmp/film ${1:+--only "$1"} >/dev/null
$app shots --out tmp/shots >/dev/null

# GitHub takes a link preview under 1 MB.
sips -s format jpeg -s formatOptions 88 tmp/shots/social.png --out "$images/social.jpg" >/dev/null
sips -s format png -Z 256 Resources/AppIcon.icns --out "$images/icon.png" >/dev/null

# Twenty-five frames a second, sharp on Retina screens (shown at half
# width), one palette per movie, redrawing only what changed.
for movie in tmp/film/*.mov; do
  base="$(basename "$movie" .mov)"
  name="${base%-light}"
  name="${name%-dark}"
  [ "$name" = probe ] && continue
  gif="$images/$name.gif"
  [ "$base" = "$name-dark" ] && gif="$images/$name-dark.gif"
  # Twice the width each is shown at; the terminal journey, at full page
  # width, a little less.
  case "$name" in
    handoff) width=1388 ;;
    import) width=1440 ;;
    import-progress) width=1056 ;;
    floating) width=760 ;;
    *) width=840 ;;
  esac
  # The first moments are the window settling; the journey starts after.
  ffmpeg -loglevel error -y -ss 0.3 -i "$movie" -vf \
    "fps=25,scale=$width:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    -loop 0 "$gif"
done
ls -lh "$images"
