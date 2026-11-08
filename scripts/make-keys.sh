#!/usr/bin/env bash
# Run once, on the Mac that makes releases. Creates the two keys a release
# needs and keeps both private halves in the login keychain:
#
#   1. "TapeUp Release", a self-signed code-signing identity. Every release
#      is signed with it, so macOS keeps the microphone and system-audio
#      grants across updates. macOS asks for your password once, to trust it
#      for code signing.
#   2. The Sparkle update key (EdDSA), made by Sparkle's generate_keys. Its
#      public half goes into packaging/sparkle-public-key, to commit; the app
#      accepts only updates signed with the private half.
#
# Nothing private is printed or left on disk. Running it again keeps keys
# that already exist.
#
# Usage: scripts/make-keys.sh [--dry-run]
#   --dry-run  makes the certificate in a temporary folder and checks it,
#              then prints the keychain commands without running them.
set -euo pipefail
cd "$(dirname "$0")/.."

name="TapeUp Release"
# The keychain account of the Sparkle key; scripts/release.sh uses the same.
account="kkyrian"
keychain="$HOME/Library/Keychains/login.keychain-db"
public_key_file="packaging/sparkle-public-key"
generate_keys=".build/artifacts/sparkle/Sparkle/bin/generate_keys"
# The LibreSSL macOS ships: its PKCS#12 files are the kind `security import`
# reads (OpenSSL 3's defaults are not, on older macOS).
openssl=/usr/bin/openssl

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  *) echo "usage: scripts/make-keys.sh [--dry-run]" >&2; exit 2 ;;
esac

run() {
  if ((dry_run)); then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# --- 1. The code-signing identity -------------------------------------------

# Without -v: an identity that exists but is not trusted yet counts too.
if ((!dry_run)) && grep -qF "\"$name\"" <<<"$(security find-identity -p codesigning "$keychain")"; then
  echo "Code signing: \"$name\" is already in your login keychain; kept."
else
  umask 077
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $name
[codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  # Ten years: codesign will not sign with an expired certificate, and a new
  # one would make every user grant the microphone again.
  "$openssl" req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
    -config "$work/cert.cnf" -extensions codesign \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  # A one-time passphrase for the file that carries the key into the
  # keychain; the file is deleted when this script ends.
  TAPEUP_P12_PASS="$("$openssl" rand -hex 24)"
  export TAPEUP_P12_PASS
  "$openssl" pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/identity.p12" -passout env:TAPEUP_P12_PASS
  rm -f "$work/key.pem"

  if ((dry_run)); then
    echo "Dry run: the certificate this would add:"
    "$openssl" x509 -in "$work/cert.pem" -noout -text \
      | grep -A1 -E "Subject:|Not (Before|After)|Basic Constraints|Key Usage" | grep -v -- "^--"
    "$openssl" pkcs12 -in "$work/identity.p12" -passin env:TAPEUP_P12_PASS -noout \
      && echo "Dry run: the PKCS#12 file opens with its passphrase."
  fi

  # -T lets codesign use the key; macOS may still ask once ("Always Allow").
  if ((dry_run)); then
    echo "would run: security import <identity.p12> -k $keychain -f pkcs12 -P <one-time passphrase> -T /usr/bin/codesign"
  else
    security import "$work/identity.p12" -k "$keychain" -f pkcs12 -P "$TAPEUP_P12_PASS" \
      -T /usr/bin/codesign >/dev/null
  fi
  unset TAPEUP_P12_PASS
  # Trusted for code signing only, in your own trust settings (not the
  # system's). macOS asks for your password here.
  echo "Trusting \"$name\" for code signing; macOS asks for your password."
  run security add-trusted-cert -r trustRoot -p codeSign "$work/cert.pem"
  ((dry_run)) || echo "Code signing: \"$name\" added to your login keychain, valid for ten years."
fi

if ((!dry_run)); then
  identities="$(security find-identity -v -p codesigning "$keychain")"
  fingerprint="$(awk -v n="\"$name\"" 'index($0, n) {print $2; exit}' <<<"$identities")"
  if [[ -z "$fingerprint" ]]; then
    echo "error: \"$name\" is in the keychain but not trusted for code signing." >&2
    echo "Open Keychain Access, find \"$name\", and under Trust set Code Signing to Always Trust." >&2
    exit 1
  fi
  echo "  certificate SHA-1 $fingerprint (public; identifies the certificate)"
fi

# --- 2. The Sparkle update key ----------------------------------------------

[[ -x "$generate_keys" ]] || swift package resolve >/dev/null
if ((dry_run)); then
  echo "would run: $generate_keys --account $account   (output discarded)"
  echo "would run: $generate_keys --account $account -p > $public_key_file"
else
  # Keeps a key that already exists. Its own output is not shown; only the
  # public half is read back below.
  "$generate_keys" --account "$account" >/dev/null
  public_key="$("$generate_keys" --account "$account" -p | tr -d '[:space:]')"
  # A public EdDSA key is 32 bytes, 44 characters of base64.
  if [[ ! "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "error: generate_keys did not give a public key." >&2
    exit 1
  fi
  printf '%s\n' "$public_key" >"$public_key_file"
  echo "Updates: the Sparkle key is in your login keychain (account \"$account\")."
  echo "  public key $public_key"
  echo "  written to $public_key_file; commit it."
fi

cat <<EOF

Both private keys stay in your login keychain and nowhere else. Back them up
somewhere safe, such as a password manager: without the update key, apps
already installed can never update again; without the certificate, every
user grants the microphone and system audio once more.
  Update key:  $generate_keys --account $account -x <file>
  Certificate: Keychain Access, "$name", Export as .p12
EOF
