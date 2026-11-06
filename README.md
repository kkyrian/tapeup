# TapeUp

Meeting context for your agents, wherever they live.

TapeUp is a small macOS menu-bar recorder. One click records your Mac's audio
and your microphone together, keeps going when your AirPods connect or
disconnect, and saves each recording as a folder any agent can be handed by
path and understand from there.

TapeUp transcribes on your Mac while you record, with Qwen3-ASR; nothing
goes to the cloud. Your own agents take it from there.

**Status:** early. Works on the maintainer's Mac; not yet released.

## Use

- Click the menu-bar item and press **Record**, or press **⌥⌘R** anywhere.
  Both lanes move while recording, so you can see both sources are alive.
- **Transcript** is the third row: on by default, it downloads the speech
  model once (1.7B on Macs with 16 GB or more, 0.6B below) and shows the
  latest words under the timer while you record.
- **Stop and save** (or ⌥⌘R again). The card offers **Copy path**, which
  copies `folder: …`, `audio: …` and `transcript: …` for your agent,
  **Copy transcript**, and **Show in Finder**.
- **How many people in the meeting** is optional: tap a count, add participant names. Names are suggested
  from past recordings and from your people list, with forgiving search
  ("ps" finds Priya Shah).
- **People:** let your own AI assistant write the list. TapeUp copies one
  request; Claude Code or Codex saves `people.json` directly, and a chat
  assistant's answer is pasted back with one click.

Recordings go to `~/TapeUp` (change it from the ··· menu). Each folder holds
`audio.m4a` (left: your mic, right: your Mac's audio), `transcript.md` and
`meta.json`; the `AGENTS.md` at the root explains the layout to any agent.
With headphones, transcript lines say which side they came from:
Microphone or Computer audio.

## Build

Requires macOS 15 or later on Apple silicon, and Xcode with its Metal
Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```bash
make verify-full
open .build/TapeUp.app
```

## License

MIT. See [LICENSE](LICENSE).
