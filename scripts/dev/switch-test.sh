#!/usr/bin/env bash
# Records about 100 seconds while switching audio devices on a schedule.
# Counting plays aloud so both tracks have content to judge by ear.
# Usage: scripts/dev/switch-test.sh "<AirPods name as SwitchAudioSource -a lists it>"
set -euo pipefail
cd "$(dirname "$0")/../.."

airpods="${1:?pass the AirPods device name, e.g. from: SwitchAudioSource -a}"
laptop_in="MacBook Pro Microphone"
laptop_out="MacBook Pro Speakers"
out="$PWD/tmp/switch-test"

original_in="$(SwitchAudioSource -c -t input)"
original_out="$(SwitchAudioSource -c -t output)"
restore() {
  SwitchAudioSource -t input -s "$original_in" >/dev/null || true
  SwitchAudioSource -t output -s "$original_out" >/dev/null || true
}
trap restore EXIT

switch() { echo "$(date +%T)  $1 -> $2"; SwitchAudioSource -t "$1" -s "$2" >/dev/null; }

switch output "$airpods"
switch input "$airpods"
scripts/bundle.sh release >/dev/null
open -n .build/TapeUp.app --args record --out "$out" --seconds 100
sleep 2

( for i in $(seq 1 95); do say "$i" & sleep 1; done ) &
sleep 13; switch output "$laptop_out"
sleep 10; switch input "$laptop_in"
sleep 10; switch output "$airpods"
sleep 10; switch input "$airpods"
sleep 10; switch output "$laptop_out"; switch input "$laptop_in"
sleep 10; switch output "$airpods"; switch input "$airpods"
sleep 40
wait

dir="$(ls -d "$out"/*/ | tail -1)"
echo; echo "Recording: $dir"
grep -v '"t":0\.' "$dir/events.jsonl" | cut -c1-200
scripts/dev/levels.py "$dir/audio.m4a" 1
open -R "$dir/audio.m4a"
