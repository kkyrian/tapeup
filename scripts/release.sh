#!/usr/bin/env bash
# Makes a TapeUp release on this Mac; GitHub only serves the files.
#
# Usage: scripts/release.sh [--dry-run | --draft | --publish] <version>   e.g. 0.1.0
#
# 1. Refuses a dirty tree, a version not above VERSION, or failing
#    `make verify-fast`.
# 2. Writes the version to VERSION, builds release, and signs with "TapeUp
#    Release" (scripts/make-keys.sh).
# 3. Makes TapeUp.dmg (the app and an Applications link, volume
#    "TapeUp <version>"), checks the signature and the mounted image.
# 4. Signs the image for Sparkle (the update key in the keychain) and adds an
#    item to packaging/appcast.xml, with notes from the commits since the
#    last tag.
# 5. Commits, tags v<version>, pushes main and the tag, and publishes a
#    GitHub release with TapeUp.dmg and appcast.xml.
# 6. If the tap is cloned ($TAP_DIR, default ~/Developer/homebrew-tap),
#    writes Casks/tapeup.rb there from packaging/homebrew/tapeup.rb, commits
#    and pushes.
#
# --draft does steps 1 to 5 with the release as a GitHub draft, which no one
# else sees, so it works while the repository is still private; the tap waits.
# --publish <version> later makes that draft the latest release, once the
# repository is public, checks the downloads, and does step 6.
#
# --dry-run does all of it except that it signs ad hoc, and commits, tags,
# pushes and publishes nothing: VERSION and the appcast are put back, and the
# cask is written into a copy of the tap. The files land in tmp/release/<version>.
# It signs for Sparkle only when packaging/sparkle-public-key exists (with the
# keychain) or SPARKLE_KEY_FILE names a private key file (for tests).
set -euo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

repo="kkyrian/tapeup"
account="kkyrian" # the Sparkle key's keychain account, as in scripts/make-keys.sh
identity_name="TapeUp Release"
public_key_file="packaging/sparkle-public-key"
appcast="packaging/appcast.xml"
cask_template="packaging/homebrew/tapeup.rb"
tap="${TAP_DIR:-$HOME/Developer/homebrew-tap}"
sparkle_bin=".build/artifacts/sparkle/Sparkle/bin"
feed="https://github.com/$repo/releases/latest/download/appcast.xml"

dry_run=0
draft=0
publish=0
version=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    --draft) draft=1 ;;
    --publish) publish=1 ;;
    -*) echo "unknown option $arg" >&2; exit 2 ;;
    *) version="$arg" ;;
  esac
done
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "usage: scripts/release.sh [--dry-run | --draft | --publish] <version>   (semantic, like 0.1.0)" >&2
  exit 2
fi
((dry_run + draft + publish <= 1)) || { echo "choose one of --dry-run, --draft and --publish" >&2; exit 2; }
tag="v$version"
if ((draft)); then release_kind="--draft"; else release_kind="--latest"; fi
step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# What people and Sparkle download: the stable links must answer.
check_downloads() {
  for file in TapeUp.dmg appcast.xml; do
    curl -fsIL -o /dev/null "https://github.com/$repo/releases/latest/download/$file" \
      || echo "warning: https://github.com/$repo/releases/latest/download/$file does not answer yet." >&2
  done
}

# Writes the cask for $dmg into the tap, or into a copy of it on a dry run.
update_tap() {
  local dmg="$1"
  if [[ ! -d "$tap/.git" ]]; then
    echo "No tap at $tap; the cask is not updated."
    return
  fi
  local sha target
  sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  if ((dry_run)); then
    target="$out/homebrew-tap"
    git clone -q "$tap" "$target"
    step "Dry run: writing the cask into a copy of the tap, $target"
  else
    step "Updating the Homebrew tap, $tap"
    [[ -z "$(git -C "$tap" status --porcelain)" ]] || fail "the tap has changes; the release is out, but the cask is not updated."
    git -C "$tap" pull -q --ff-only
    target="$tap"
  fi
  mkdir -p "$target/Casks"
  # The template's opening comment is about the template; the cask starts at "cask".
  sed -e '1,/^cask /{/^#/d;}' -e "s/^  version \".*\"$/  version \"$version\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" \
    "$cask_template" >"$target/Casks/tapeup.rb"
  ruby -c "$target/Casks/tapeup.rb" >/dev/null
  grep -q "version \"$version\"" "$target/Casks/tapeup.rb" && grep -q "sha256 \"$sha\"" "$target/Casks/tapeup.rb" \
    || fail "the cask template did not take the version and sha256."
  if ((dry_run)); then
    git -C "$target" status --short
    cat "$target/Casks/tapeup.rb"
  else
    git -C "$tap" add Casks/tapeup.rb
    git -C "$tap" commit -q -m "chore(tapeup): $version"
    git -C "$tap" push -q
  fi
}

require_public() {
  # Release files on a private repository need a sign-in to download.
  [[ "$(gh repo view "$repo" --json visibility -q .visibility 2>/dev/null)" == PUBLIC ]] \
    || fail "$repo is not public, so no one could download the release or its updates."
}

# --- Publishing a draft --------------------------------------------------------

if ((publish)); then
  step "Publishing the draft $tag"
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in (gh auth login)."
  require_public
  [[ "$(gh release view "$tag" --repo "$repo" --json isDraft -q .isDraft 2>/dev/null)" == true ]] \
    || fail "there is no draft release $tag; make one with --draft first."
  out="tmp/release/$version"
  dmg="$out/TapeUp.dmg"
  [[ -f "$dmg" ]] || fail "$dmg is missing; the cask needs the image the draft holds."
  uploaded="$(mktemp -d)"
  gh release download "$tag" --repo "$repo" --pattern TapeUp.dmg --dir "$uploaded"
  [[ "$(shasum -a 256 <"$dmg")" == "$(shasum -a 256 <"$uploaded/TapeUp.dmg")" ]] \
    || fail "$dmg is not the image in the draft."
  rm -rf "$uploaded"
  gh release edit "$tag" --repo "$repo" --draft=false --latest
  check_downloads
  update_tap "$dmg"
  step "Done: TapeUp $version is out"
  echo "Release: https://github.com/$repo/releases/tag/$tag"
  exit 0
fi

# --- Checks before anything changes ------------------------------------------

step "Checking"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has changes; commit or stash them first."
current="$(tr -d '[:space:]' <VERSION)"
[[ "$version" != "$current" && "$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -1)" == "$version" ]] \
  || fail "$version is not above the current version, $current."
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "the tag $tag already exists."

if ((dry_run)); then
  identity="-"
  echo "Dry run: signing ad hoc; nothing is committed, tagged, pushed or published."
else
  # The local update test's settings must never reach people.
  for name in TAPEUP_FEED_URL TAPEUP_ED_PUBLIC_KEY SPARKLE_KEY_FILE TAPEUP_SIGN_IDENTITY; do
    [[ -z "${!name:-}" ]] || fail "$name is set; it is only for dry runs. Unset it first."
  done
  gh auth status >/dev/null 2>&1 || fail "gh is not signed in (gh auth login)."
  [[ "$(git branch --show-current)" == main ]] || fail "releases are made from main."
  # A draft is seen by no one else, so it may be made while private.
  ((draft)) || require_public
  git fetch -q origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || fail "main is not the same as origin/main; pull or push first."
  ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || fail "$tag already exists on GitHub."
  identities="$(security find-identity -v -p codesigning)"
  identity="$(awk -v n="\"$identity_name\"" 'index($0, n) {print $2; exit}' <<<"$identities")"
  [[ -n "$identity" ]] || fail "no trusted \"$identity_name\" identity; run scripts/make-keys.sh first."
  [[ -s "$public_key_file" ]] || fail "$public_key_file is missing; run scripts/make-keys.sh and commit it."
fi

make verify-fast

# The Sparkle key: the keychain's must be the one the app is built with.
[[ -x "$sparkle_bin/sign_update" ]] || swift package resolve >/dev/null
public_key="${TAPEUP_ED_PUBLIC_KEY:-}"
if [[ -z "$public_key" && -f "$public_key_file" ]]; then public_key="$(tr -d '[:space:]' <"$public_key_file")"; fi
sign_args=(--account "$account")
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
  sign_args=(--ed-key-file "$SPARKLE_KEY_FILE")
elif [[ -n "$public_key" ]]; then
  [[ "$("$sparkle_bin/generate_keys" --account "$account" -p | tr -d '[:space:]')" == "$public_key" ]] \
    || fail "the update key in the keychain does not match $public_key_file."
elif ((dry_run)); then
  sign_args=()
  echo "Dry run: no update key yet, so the appcast item is not signed for Sparkle."
fi

# --- Build -----------------------------------------------------------------

out="tmp/release/$version"
rm -rf "$out"
mkdir -p "$out"
saved="$(mktemp -d)"
committed=0
published=0
cp VERSION "$saved/VERSION"
[[ -f "$appcast" ]] && cp "$appcast" "$saved/appcast.xml"
# Until the release commit exists, a failure or a dry run leaves the tree as
# it was.
restore() {
  local status=$?
  if ((committed && !published && status != 0)); then
    echo "The release commit and tag $tag are made here. To finish: git push origin main $tag," >&2
    echo "then gh release create $tag $dmg $out/appcast.xml --repo $repo --title \"TapeUp $version\" --notes-file $out/notes.md --verify-tag $release_kind" >&2
  fi
  if ((!committed)); then
    cp "$saved/VERSION" VERSION
    if [[ -f "$saved/appcast.xml" ]]; then cp "$saved/appcast.xml" "$appcast"; else rm -f "$appcast"; fi
  fi
  rm -rf "$saved"
  if [[ -n "${mounted:-}" ]]; then hdiutil detach -quiet "$mounted" || true; fi
}
trap restore EXIT

step "Building $version"
printf '%s\n' "$version" >VERSION
TAPEUP_SIGN_IDENTITY="$identity" scripts/bundle.sh release
app=".build/TapeUp.app"

step "Checking the app's signature"
codesign --verify --deep --strict --verbose=2 "$app"
plist="$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" == "$version" ]] || fail "the app's version is not $version."
[[ "$(plutil -extract CFBundleVersion raw "$plist")" == "$version" ]] || fail "the app's build version is not $version."
if ((!dry_run)); then
  # Read whole first: grep -q stops early, and pipefail would count codesign's SIGPIPE.
  authority="$(codesign -dvv "$app" 2>&1)"
  grep -qx "Authority=$identity_name" <<<"$authority" || fail "the app is not signed by \"$identity_name\"."
  [[ "$(plutil -extract SUPublicEDKey raw "$plist")" == "$(tr -d '[:space:]' <"$public_key_file")" ]] \
    || fail "the app's update key is not the one in $public_key_file."
  [[ "$(plutil -extract SUFeedURL raw "$plist")" == "$feed" ]] || fail "the app's update feed is not $feed."
fi

step "Making TapeUp.dmg"
stage="$out/stage"
mkdir -p "$stage"
ditto "$app" "$stage/TapeUp.app"
ln -s /Applications "$stage/Applications"
dmg="$out/TapeUp.dmg"
hdiutil create -quiet -volname "TapeUp $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
hdiutil verify -quiet "$dmg"

step "Checking the mounted image"
mounted="$(mktemp -d)"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mounted" "$dmg"
[[ "$(ls "$mounted" | sort | tr '\n' ' ')" == "Applications TapeUp.app " ]] || fail "the image holds more than the app and Applications."
[[ "$(readlink "$mounted/Applications")" == /Applications ]] || fail "the Applications link is wrong."
codesign --verify --deep --strict "$mounted/TapeUp.app"
[[ "$(plutil -extract CFBundleShortVersionString raw "$mounted/TapeUp.app/Contents/Info.plist")" == "$version" ]] \
  || fail "the app in the image is not $version."
hdiutil detach -quiet "$mounted"
rmdir "$mounted" 2>/dev/null || true
mounted=""
echo "Volume \"TapeUp $version\": TapeUp.app and Applications."

# --- Release notes and the appcast -------------------------------------------

step "Writing the release notes and the appcast"
last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [[ -z "$last_tag" ]]; then
  notes=("The first release.")
else
  # What changed for people: features, fixes and speedups, without the
  # Conventional Commits prefix. Other commits only when there are none.
  subjects="$(git log --no-merges --format=%s "$last_tag..HEAD")"
  user_facing="$(grep -E '^(feat|fix|perf)(\([^)]*\))?!?: ' <<<"$subjects" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //' || true)"
  [[ -n "$user_facing" ]] || user_facing="$(sed -E 's/^[a-z]+(\([^)]*\))?!?: //' <<<"$subjects")"
  notes=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && notes+=("$(tr '[:lower:]' '[:upper:]' <<<"${line:0:1}")${line:1}")
  done <<<"$user_facing"
  ((${#notes[@]})) || notes=("Small changes.")
fi
printf -- '- %s\n' "${notes[@]}" >"$out/notes.md"

signature=""
if ((${#sign_args[@]})); then
  # Prints sparkle:edSignature="…" length="…"; the private key never leaves
  # the keychain (or the test key file).
  signature="$("$sparkle_bin/sign_update" "${sign_args[@]}" "$dmg")"
  [[ "$signature" =~ sparkle:edSignature=\"[^\"]+\"\ length=\"[0-9]+\" ]] || fail "sign_update gave no signature."
else
  signature="length=\"$(stat -f %z "$dmg")\""
fi

minimum="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
NOTES="$(printf '%s\n' "${notes[@]}")" python3 - "$appcast" "$version" "$tag" "$minimum" "$signature" "$repo" <<'PY'
import email.utils, html, os, sys
path, version, tag, minimum, signature, repo = sys.argv[1:]
items = "".join(f"<li>{html.escape(n)}</li>" for n in os.environ["NOTES"].splitlines() if n)
item = f"""        <item>
            <title>TapeUp {version}</title>
            <pubDate>{email.utils.formatdate(localtime=False, usegmt=True)}</pubDate>
            <sparkle:version>{version}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
            <description><![CDATA[<ul>{items}</ul>]]></description>
            <enclosure url="https://github.com/{repo}/releases/download/{tag}/TapeUp.dmg" type="application/octet-stream" {signature}/>
        </item>
"""
try:
    feed = open(path).read()
except FileNotFoundError:
    feed = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>TapeUp</title>
        <link>https://github.com/{repo}</link>
    </channel>
</rss>
""".replace("{repo}", repo)
# Newest first, after the channel's own lines.
at = feed.find("        <item>")
if at < 0:
    at = feed.index("    </channel>")
open(path, "w").write(feed[:at] + item + feed[at:])
PY
xmllint --noout "$appcast"
cp "$appcast" "$out/appcast.xml"
cat "$out/notes.md"

# --- Publish ---------------------------------------------------------------

if ((dry_run)); then
  step "Dry run: would commit VERSION and $appcast, tag $tag, push main and $tag, and publish"
  echo "gh release create $tag $dmg $out/appcast.xml --title \"TapeUp $version\" --notes-file $out/notes.md --verify-tag --latest"
else
  step "Committing and tagging $tag"
  git add VERSION "$appcast"
  git commit -q -m "chore(release): $tag"
  committed=1
  git tag -a "$tag" -m "TapeUp $version"
  git push -q origin main "$tag"
  if ((draft)); then step "Uploading the draft release"; else step "Publishing the GitHub release"; fi
  gh release create "$tag" "$dmg" "$out/appcast.xml" --repo "$repo" --title "TapeUp $version" \
    --notes-file "$out/notes.md" --verify-tag $release_kind
  published=1
  ((draft)) || check_downloads
fi

# --- Homebrew --------------------------------------------------------------

if ((draft)); then
  echo "The tap waits for the draft to be published: scripts/release.sh --publish $version"
else
  update_tap "$dmg"
fi

step "Done: TapeUp $version"
echo "Image: $dmg"
if ((draft)); then
  # A draft has no page at its tag until it is published.
  echo "Draft: $(gh release view "$tag" --repo "$repo" --json url -q .url)"
  echo "Only you see it. After the repository is public: scripts/release.sh --publish $version"
elif ((!dry_run)); then
  echo "Release: https://github.com/$repo/releases/tag/$tag"
fi
