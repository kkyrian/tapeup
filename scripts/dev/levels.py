#!/usr/bin/env python3
"""Print per-window loudness for each channel of a TapeUp recording.

Usage: scripts/dev/levels.py <audio.m4a|caf> [window_seconds]
Converts with afconvert, then reports dBFS per window for left (microphone)
and right (computer audio), and lists windows where a channel is silent.
"""
import array, math, os, subprocess, sys, tempfile, wave

src = sys.argv[1]
window = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
with tempfile.TemporaryDirectory() as tmp:
    wav = os.path.join(tmp, "a.wav")
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "2", src, wav], check=True)
    with wave.open(wav) as w:
        rate, frames = w.getframerate(), w.getnframes()
        data = array.array("h", w.readframes(frames))

def db(samples):
    if not samples:
        return -120.0
    rms = math.sqrt(sum(s * s for s in samples) / len(samples)) / 32768
    return 20 * math.log10(rms) if rms > 0 else -120.0

step = int(rate * window)
rows = []
for start in range(0, frames, step):
    seg = data[start * 2:(start + step) * 2]
    rows.append((start / rate, db(seg[0::2]), db(seg[1::2])))
print(f"duration {frames / rate:.1f}s, window {window}s")
print("   t     mic dB   computer dB")
for t, left, right in rows:
    print(f"{t:6.1f}  {left:7.1f}  {right:9.1f}")
