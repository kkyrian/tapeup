---
description: Design authority for TapeUp: architecture, decisions, invariants, and evolution.
---

# TapeUp: System Design

**Status**: draft
**Prior art**: [Blurt](https://github.com/AGIHunt/blurt) — MIT recorder that hands recordings to agents; its folder-per-session and "writes files, no connectors" stance informed this design; [BetterCapture](https://github.com/jsattler/BetterCapture) — MIT menu-bar recorder on ScreenCaptureKit; [catap](https://pypi.org/project/catap/) — Core Audio tap wrapper
**Supersedes**: None
**Implements**: None
**Extends**: None
**Related**: [README](../README.md) — the product promise. `TU-0NN` marks cite the maintainer's decision records, which are kept outside this repository.

## Purpose

A very simple Mac recorder: all computer audio plus the default microphone,
one click, surviving device switches (AirPods in and out, speakers, the laptop
mic). Each recording becomes a self-describing folder that any agent can be
handed by path and understand from there. TapeUp transcribes on the Mac
itself, never in the cloud; speakers are labeled with every transcript, and
anything an agent does is an optional suggestion the user accepts (TU-013,
TU-014, TU-019, TU-036).

## Operating Charter

- **Scope:** a small, finished, polished tool. The core is recording and transcription on the Mac, with speaker labels; anything more ships only if it stays simple (TU-013).
- **Quality bar:** polished and premium, quick to respond, a delight to use,
  and plain about what it is for. Every interface change is pictured in all
  its states and reviewed by a designer before it ships (TU-004, TU-034).
- **Built with agents, in public:** the agent setup and instructions are
  committed on purpose. The maintainer's records stay in a private layer
  around this repository and are cited here by ID (TU-035).
- **Evolution authority:** agents implement and commit within settled
  decisions; product scope, the folder contract and anything public-facing
  (name, README promise, release) are the maintainer's.

## Architecture

- **The app** (`TapeUp.app`, menu-bar only) does all capture, because macOS
  ties microphone and system-audio permission to the signed app, not to the
  terminal or agent that calls it. Its own status item and a non-activating
  panel (not `MenuBarExtra`), so the saved card can appear after a shortcut
  stop without taking focus from a call; ⌥⌘R starts and stops anywhere. (TU-007)
- **Computer audio:** a global Core Audio process tap
  (`CATapDescription` + `AudioHardwareCreateProcessTap`) read through an
  aggregate device that contains only the tap, with no output device in it.
  Both are private to TapeUp's process, so no other app lists or can choose
  them and they vanish when it exits; tap auto-start stays off, because with
  it a private aggregate waits for audio before it runs. (TU-002)
- **Microphone:** the current default input, read directly through a Core
  Audio IOProc and followed when it changes. `AVAudioEngine` is avoided
  because it also opens the default output, which with AirPods flips them in
  and out of call mode. (TU-001, TU-005)
- **Timeline writer:** both streams are placed on one clock by their host
  timestamps, so a reconnect leaves silence of the right length instead of
  shifting later audio. Audio is written as it records, so a crash keeps the
  meeting. (TU-003)
- **Output:** one stereo file per recording, microphone left and computer
  audio right, so the channels stay separable for "me versus them". Either
  source can be left out; its channel is then silent. Pausing leaves the
  paused time out of the file. (TU-005, TU-009)
- **Transcription:** Qwen3-ASR on MLX through speech-swift (Apache-2.0),
  inside the app, no Python. The recorder hands every written stretch of
  audio to a transcript session; Silero voice detection cuts it into pieces
  at pauses of 0.8 s or more, at most 20 s long, and the model transcribes
  each. All model work, loading included, runs one piece at a time on a
  single queue shared by every engine (MLX is not thread safe), and only
  one model is loaded at a time. If live audio falls more than two minutes
  behind, the transcript is made from the file instead. With headphones and both sources, the two
  channels are transcribed apart and lines carry their side; otherwise the
  channels are mixed. A recording made before the model arrived, cut off by
  a quit, or asked for later is transcribed from its file the same way.
  Models live in `~/Library/Application Support/TapeUp/models`; MLX's shader
  library ships beside the executable. Engine-free logic (pieces, guards,
  hints, the file format) is in `TapeUpCore` and unit-tested; `TapeUpSpeech`
  only adapts the models. (TU-014, TU-015, TU-016, TU-031)
- **Speaker labels:** made as soon as a transcript is done (an import
  follows its own Label speakers switch); Label speakers on the card starts
  them for an older recording. The user's own name, set on the People page,
  is offered first among the names, though they may have missed the meeting
  (TU-036). Nemotron 3 Diarization (MLX INT8, 102 MB, downloaded on first use)
  finds who spoke when in the saved file, and a WeSpeaker voice print is
  taken for each voice it finds; both run on the shared model queue after
  the speech model is let go if idle. The model splits long talkers into
  several voices, so voices are folded into people: with the count the user
  tapped, the voice with the least talk joins the one it sounds most like
  until that many remain; without one, voices whose prints reach 0.6 cosine
  or hold under 3 % of the talk are folded, and what remains is the estimate,
  shown on its count chip. What the model heard is kept in the folder
  (`.voice-prints.json`), so another count refolds without the model. Each
  transcript line takes the voice heard longest during it; lines are kept
  with their times in `.transcript-lines.json` for this. Each voice row
  plays that voice to name it (2026-11-08): the model's turns, folded as
  the labels were, cut from `audio.m4a` and queued back to back on an
  output-only `AVAudioEngine` (its input is never touched), mixed to mono
  so either channel is heard in both ears, through the default output.
  Turns under 0.25 s apart play as one, pieces under 0.3 s are skipped,
  and the row's quote follows the line being heard. It stops with the
  card, the panel, a recount or a recording starting, and cannot start
  while recording, since the computer-audio tap would hear it. (TU-017, TU-031, TU-032)
- **Remembered voices:** `.voices.json` in the recordings root keeps, per
  person on the People list, up to 20 voice prints (the longest talkers)
  from voices a person named or confirmed, and "not me" prints from
  corrections. After labeling, each voice is scored against each person
  (mean of the three best example cosines); a voice is filled in when it
  clears that person's bar (0.50, raised by corrections up to 0.85), leads
  the next person by 0.25, talked 30 s or more, and no other voice in the
  meeting took that person. The numbers come from 40 AMI meetings. A fill
  puts the person in who was there but never adds anyone to the People list
  and never teaches the store; playing that voice, or naming another voice
  in the meeting, confirms it unless the chosen person is on that fill.
  A microphone correction keeps its negative without changing the acoustic
  bar. Changing a fill records "not me", takes the
  person out of who was there if the fill put them there, and offers the
  same fix for unchecked fills of that person in earlier meetings, nothing
  changed without a click. Removing a person forgets their voice; Settings
  shows the count and Forget all. Agents never receive the prints. The
  user's agent titles recordings only (TU-039).
- **Made titles:** once the transcript is done, a recording the user has
  not named is named from lines sampled evenly across it (about 6,000
  characters), in the Mac's language: by the user's agent when one is on,
  otherwise by Apple's on-device model where Apple Intelligence runs (macOS
  26 and later). The title applies at once and renames the folder; the user
  renames it like any title. It is never made while the user is typing a
  name. Each attempt is a `title made` or `title not made` line in
  `events.jsonl`. Without either model the title field is as before. (TU-020)
- **The user's agent:** off until the user picks Claude Code or Codex under
  Your AI in Settings; picking it is the consent.
  TapeUp runs the user's own unmodified command, found in the usual install
  places or through the login shell, in an empty folder, prompt on stdin,
  no tools, the answer held to a JSON schema (`claude -p --json-schema`,
  `codex exec -s read-only --output-schema`). It never reads their
  credentials; sign-in and install open Terminal on the tools' own
  commands. It suggests the title (before Apple's model) and, after speaker
  labels, which known person each voice is: the names are an enum of this
  recording's people and the people list, so with none known nothing is
  asked. Its title applies like Apple's; suggested names show grey with
  a Use button. Claude Code runs Sonnet at low effort, Codex its own model at
  low effort (`TapeUp agent --model --effort` changes them); a failed call
  is tried once with the user's own settings, then given up for that
  suggestion with an `agent failed` line in `events.jsonl`. The state of
  both agents is checked when Settings opens and before each call, and
  every few seconds while Terminal installs or signs one in; Settings
  says each one's state in words, never by greying it out. A chosen agent
  that is signed out or gone puts a dot on ··· and says so on the
  Settings… item. One call at a time, only for recordings the user finishes or
  opens. (TU-019)
- **Panel pages:** the recorder with Recent, a recording's card, People,
  Settings and All recordings, one at a time. ··· (and right-click on the menu-bar icon)
  holds People…, Settings… and Quit. Settings holds the recordings folder,
  Your AI, and the app switches (floating controls, open at login, which
  starts on at an installed app's first launch). (TU-004, TU-008, TU-021, TU-036)
- **All recordings:** reached by Show all under Recent when there are more
  recordings than Recent shows; browse first, search second. Chips for the
  five people named at the most recordings, then No transcript (with one
  action transcribing every one shown) and No names yet; chips combine,
  each must hold. The search matches titles, names and transcript text,
  read off the main thread when first searched and cached. The list goes
  by month, one line a recording (two while searching, so a transcript
  match shows what was said), at a fixed height so filtering never
  resizes the page. Rows are Recent's. (TU-030)
- **People list:** `people.json` at the recordings root. The People page is
  the list itself: add a person with an optional note, edit one in place,
  remove on hover, set the user's own name. "Fill from your AI" copies one
  request the user's own AI assistant answers by writing the file, or whose
  answer is pasted back. It seeds name suggestions. (TU-012, TU-021)
- **CLI:** the app's own executable answers `folder`, `import`, `title`,
  `transcribe`, `speakers`, `voices` (including `voices name`), `people`,
  `remove-audio`, `keep` and `agent` (`TapeUp help`), for agents and scripts; `AGENTS.md` in the
  recordings folder points to it. Recordings are started only in the app.
  While the app runs, a command is handed to it over a distributed
  notification carrying the recordings folder, so only the app working on
  that folder answers, the work shows in the panel and only one model
  loads; the command then waits by reading `meta.json`. Without the app it
  does the work itself. People changes go through `TapeUp people`, so names
  in recordings and remembered voices follow. Import is fingerprint-idempotent
  and ensures transcription and speaker labels, waiting for completion and
  resuming missing stages on retry. `speakers` leaves completed labels alone
  unless a different voice count is requested. `latest` resolves the most
  recent saved recording, excluding active recordings. Successful commands
  orient agents with a copyable next step, and describe reversal where possible.
  Staged settings domains always work alone, so tests cannot reach the user's
  app. Voice names require the user's identification; correcting a fill lists earlier similar fills for
  review and never changes them automatically. Audio removal requires a
  transcript, idle audio and no keep lock. `keep` sets or clears that lock.
  Concurrent file edits use the existing library and recording locks.
  The binary also keeps `record`, `snapshot`, `uitest`, and timed
  `time-transcribe` and `time-speakers` runs for testing. (TU-018)
- **Import:** Import… in ··· and files dropped on the menu-bar icon open a
  small movable window that stays on top: a drop area with Choose Files…, a
  list with name, date, length and size, and one Import button. Files are
  copied into the library as ordinary recording folders and the originals
  stay; m4a, mp3, wav, aiff and the audio of mp4 and mov are read, at 48 kHz
  stereo. Duplicates are skipped, the date comes from the file, and each file
  keeps its own name as its title. Switches for Transcribe and Label speakers
  (with a voice count per row) apply after the copy, and each row then
  follows its recording through every stage (TU-023, TU-024, TU-033).
- **Updates:** Sparkle 2 (`App/Updates.swift`). Once a day it reads
  `appcast.xml` from the latest GitHub release, downloads a newer
  `TapeUp.dmg` in the background and checks its EdDSA signature against
  `SUPublicEDKey`. The install waits until the app quits, or until it sits
  idle (no recording, panel and Import closed, no transcript running);
  Install and Relaunch from Check for Updates… waits for a recording to
  end. A build without the public key does not look for updates. (TU-025)

## The recording folder (public contract)

```text
<recordings root>/       ~/TapeUp by default
├── AGENTS.md            what this folder is, plus the user's own rules
├── people.json          tapeup-people/1: you, and people with optional context
└── <YYYY>/              one folder per year
    └── <YYYY-MM-DD-HHMM>[ title]/   -2, -3 when two start in the same minute; the title once named
        ├── audio.m4a        never modified after it is finalized; the user may remove it and keep the transcript
        ├── meta.json        time, duration, sources, devices, gaps, pauses, status, title, you, who was there
        ├── events.jsonl     what happened while recording
        ├── transcript.md    made on this Mac while recording; never rewritten once finished
        └── transcript-with-speaker-labels.md   once speakers are labeled; transcript.md stays as it is
```

The file starts at the first audio either source delivers, not at the click,
so device start-up time is not recorded as silence. A folder whose
`meta.json` still says `recording` beside an `audio.caf` was cut off by a
crash; the app finishes it at the next launch (TU-003, TU-010). Naming a recording renames
its folder (`2026/2026-11-06-1430 Lab sync`) so Finder shows familiar names; the
time stamp always leads, full date included, so a folder handed on alone
still says when it was made; a name already taken leaves the folder as it is.

`meta.json` records how far a recording has got (`recorded`, then
`transcribed`) and its `transcript` (`waiting`, `transcribing`, `done` or
`failed`, with the model, whether lines carry sides, and how many passages
could not be transcribed, which `transcript.md` also says) and, once asked
for, its `speaker_labels` (`finding`, `done` or `failed`, how many voices,
whether that number was estimated, and the names given). After a recording
stops, the card offers Copy path (`folder: …`, `audio: …`, and `transcript: …`
once there is one), Copy transcript (spinning while it is made, Try again
after a failure, Transcribe when there is none) and Show in Finder. Once
the transcript is done, Remove audio beside the trash moves `audio.m4a` to
the Trash and keeps the rest, with Undo while the card stays open (also
from a row's right-click menu); the card then says Transcript only, a row
marks it with a page glyph before its length, Copy path leaves out the
audio line, and what needs sound (playing a voice, labeling speakers)
hides (TU-037). Who was there (a count, optional names suggested from past
recordings) is optional and never delays saving. Free up
space, from ···, lists recordings that still hold audio by age, grouped by
what happens to them: "These lose their audio" (exactly what its one
action removes, after a confirming click, with Undo), Locked, speakers not
labeled (label first), and no transcript (transcribe first, or move the
whole recording to the Trash after one more click). A lock on each of its
rows, and nowhere else, keeps a recording's audio (`keep_audio` in
`meta.json`) and moves it to Locked (TU-038). Renaming a person
on the People page renames them in every recording, the labeled
transcripts and the voice store at once, with Undo; renaming onto a listed
name asks to merge (TU-040). Undo applies the inverse to fresh data, preserving
unrelated edits; label Undo also reverses learning for its recording and voice.
Busy recordings catch up through a persistent journal at launch and reload.
Unusable or ambiguous recording folders are reported and retired from that
journal. Root mutations and metadata patches use stable cross-process locks.

## Design Decisions

- **Swift Package Manager, no hand-edited Xcode project.** Agents edit text
  reliably and `.pbxproj` badly; `scripts/bundle.sh` assembles and signs the
  app bundle from the SwiftPM build.
- **Verification:** `make verify-fast` and `make verify-full` (see
  `CLAUDE.md`); there is no backend.
- **Distribution:** no paid Apple Developer membership and no notarization
  for now. Releases are built, signed and packaged on a maintainer's Mac;
  GitHub only serves the files. Every release is signed with one
  self-signed certificate, "TapeUp Release", so the microphone and
  system-audio grants survive updates; users open the first download
  through System Settings → Privacy & Security → Open Anyway. Revisit
  enrolling if TapeUp gains users (TU-022, TU-028).
- **Release flow:** `scripts/make-keys.sh`, once per Mac that releases,
  puts the "TapeUp Release" identity and the Sparkle update key in the
  login keychain and writes the public key to `packaging/sparkle-public-key`.
  `make release VERSION=x.y.z` (`scripts/release.sh`) then refuses a dirty
  tree or failing `make verify-fast`, writes `VERSION` (the one version
  source for both bundle versions), builds and signs, makes `TapeUp.dmg`
  (the app and an Applications link, volume "TapeUp x.y.z"), checks the
  signature and the mounted image, signs the image for Sparkle, adds an
  item to `packaging/appcast.xml` with the release's notes for people,
  `packaging/release-notes/x.y.z.md`, which a real release requires, commits, tags `vx.y.z`, pushes, and publishes
  the GitHub release with `TapeUp.dmg` and `appcast.xml`. The download is
  always `releases/latest/download/TapeUp.dmg`. If the tap
  `kkyrian/homebrew-tap` is cloned (`TAP_DIR`, see `scripts/release.sh`), it writes `Casks/tapeup.rb` from
  `packaging/homebrew/tapeup.rb` and pushes it. `--dry-run` signs ad hoc,
  publishes nothing, writes the cask into a copy of the tap, and leaves
  its files in `tmp/release/x.y.z`. `--draft` does everything up to a
  GitHub draft release, which no one else sees, so it runs while the
  repository is private; `--publish x.y.z` later, once public, publishes
  that release if it is still a draft, checks the download links and
  writes the cask. `scripts/bundle.sh` signs other builds
  with "TapeUp Release" when present, then Apple Development, then ad hoc
  (TU-026, TU-028).
- **License:** MIT. Reuse MIT code (Blurt, BetterCapture) with attribution;
  never copy AGPL code.

## Invariants

- The recording is saved before any question is asked; nothing the user skips
  can lose audio.
- `audio.m4a` is never modified after it is finalized.
- A device switch never ends a recording.
- The recording indicator is always visible while recording, because other
  people on a call get no notice.
- Nothing committed names real people or private context.
- An agent is called only when the user picked it, and only suggests.
- An update never installs while a recording runs or is being saved.

## Evolution Strategy

Scope grows only under the charter's scope rule (TU-013). A settled design
change lands here in the same change as the code, with the ID of its decision
record.

## How to update this document

Update this document in the same change as an architecture, invariant, or
design-decision change. Keep this guidance forward-looking; Git holds history.

## Open Questions

- How recordings and transcripts are organized and browsed over years (an
  agent-assisted library, not yet designed; TU-030).
- Transcription and speaker-label speed on a base-chip 8 or 16 GB Mac
  (measured only on one high-end Apple silicon Mac so far).
- Whether the speaker folding rules (0.6 cosine, 3 % of the talk) hold
  beyond the three meetings they were tuned on.
