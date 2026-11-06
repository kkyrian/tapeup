# TapeUp

Meeting context for your agents, wherever they live.

TapeUp is a small macOS menu-bar recorder. One click records your Mac's audio
and your microphone together, keeps going when your AirPods connect or
disconnect, and saves each recording as a folder any agent can be handed by
path and understand from there.

No AI inside. TapeUp records; your own agents transcribe, label and file.

**Status:** early. Works on the maintainer's Mac; not yet released.

## Use

- Click the menu-bar item and press **Record**, or press **⌥⌘R** anywhere.
  Both lanes move while recording, so you can see both sources are alive.
- **Stop and save** (or ⌥⌘R again). The card offers **Copy path**, which
  copies `folder: …` and `audio: …` for your agent, and **Open in Finder**.
- **Who was there** is optional: tap a count, add names. Names are suggested
  from past recordings and from your people list, with forgiving search
  ("ps" finds Priya Shah).
- **People:** let your own AI assistant write the list. TapeUp copies one
  request; Claude Code or Codex saves `people.json` directly, and a chat
  assistant's answer is pasted back with one click.

Recordings go to `~/TapeUp` (change it from the ··· menu). Each folder holds
`audio.m4a` (left: your mic, right: your Mac's audio) and `meta.json`; the
`AGENTS.md` at the root explains the layout to any agent.

## Build

Requires macOS 15 or later and Xcode.

```bash
make verify-full
open .build/TapeUp.app
```

## License

MIT. See [LICENSE](LICENSE).
