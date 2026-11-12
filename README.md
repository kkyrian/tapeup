**Status**: implemented
**Prior art**: None
**Supersedes**: None
**Implements**: [_docs/SYSTEM.md](_docs/SYSTEM.md) — the app and recording-folder design
**Extends**: None
**Related**: [LICENSE](LICENSE) — MIT license

<p align="center">
  <img src=".github/images/icon.png" width="96" height="96" alt="">
</p>

<h1 align="center">TapeUp</h1>

<p align="center">TapeUp is a meeting recorder for Mac, built for you and your AI agent.</p>

<p align="center">
  <b>Record any meeting on your Mac. Get a transcript you and your AI agent can use.</b><br>
  A click records both sides of the call: your voice and everything your Mac plays.<br>
  TapeUp transcribes it on your Mac while you talk.
</p>

<p align="center">
  <a href="https://github.com/kkyrian/tapeup/releases/latest/download/TapeUp.dmg"><b>Download for Mac</b></a>
  &nbsp;·&nbsp; free, MIT license &nbsp;·&nbsp; Apple silicon, tested on macOS 27<br>
  <sub>First time? macOS asks once before TapeUp opens: <a href="#first-launch">see First launch</a>.</sub>
</p>

```bash
brew install kkyrian/tap/tapeup
```

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/images/record-dark.gif">
    <img src=".github/images/record.gif" width="35.7%" alt="Clicking the cassette in the menu bar opens TapeUp. The Microphone and Transcript switches are turned on, and Record starts the clock, and the call's words appear in the Transcript row. Stop saves the recording, and it names itself “Beta launch plan”.">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/images/import-dark.gif">
    <img src=".github/images/import.gif" width="61.2%" alt="The Import window is open beside a Finder window. Four recordings are dragged in from the Finder and listed with their dates, lengths and sizes. Import 4 recordings copies them in, and each is transcribed in turn: a ring fills, the lines spoken pass under its name with the time left, speakers are found, and a check marks it ready. Done closes the window, and the recordings appear in TapeUp's list under the days they were made.">
  </picture>
</p>

<p align="center">Record a call, or bring in recordings you already have.<br>Both are transcribed on your Mac.</p>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/who-was-there-dark.gif">
  <img align="left" width="380" src=".github/images/who-was-there.gif" alt="A 31-minute call is stopped. On the saved recording, a tap on 4 sets how many were there, and typing “pr”, “jo” and “an” adds Priya Shah, José Ortiz and Ana from suggestions.">
</picture>

### Say who was there

When you stop, tap how many people were on the call and type a few
letters of each name. TapeUp suggests the people you meet with.

It's optional, and it's what a transcript can't know on its own.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/speakers-dark.gif">
  <img align="right" width="380" src=".github/images/speakers.gif" alt="On a saved recording, Label speakers finds four voices, each with how long it talked and a line it said. Play on the first voice turns to Stop, and its line changes to each thing that voice said as it plays. It is named Priya Shah from a menu, then stopped.">
</picture>

### Know who said what

Once the transcript is ready, TapeUp finds each voice in the recording,
on your Mac. Each one comes with a line it said and a button to hear it,
so naming it takes a second.

Name a voice once and later meetings fill that name in by themselves.
The voices TapeUp remembers stay on your Mac and never go to your agent.

With headphones on, your own lines are marked from the start.

<br clear="all">
<br>

### Hand it to your agent

Press **Copy path**, paste it into Claude Code or Codex, and ask.
That answer is Claude Code's own, unedited.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/handoff-dark.gif">
  <img width="100%" src=".github/images/handoff.gif" alt="Copy path on the recording, pasted into Claude Code with the question “What did we decide, and what do I owe by when?”. Claude reads the transcript and answers with the decisions, a table of what the user owes and by when, what others owe, and what is still open.">
</picture>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/settings-dark.gif">
  <img align="right" width="380" src=".github/images/settings.gif" alt="From the ··· menu, Settings… opens Settings. Under Your AI, Claude Code is picked instead of Off.">
</picture>

### Let your AI do the titles

Pick Claude Code or Codex in Settings, the one you're signed in to,
and it titles each recording.

It stays off until you pick one. Without it, Apple Intelligence titles
recordings where your Mac has it.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/all-recordings-dark.gif">
  <img align="left" width="380" src=".github/images/all-recordings.gif" alt="Show all, under the recent recordings, opens every recording by month. The No transcript chip lists the ones without a transcript, and Transcribe 25 recordings starts them: the first one's ring fills while the rest wait. Then a search for “thursday” finds the meetings where it was said, each with the words around it.">
</picture>

### Find any meeting

**Show all** lists every recording by month. Search the titles, the
names, or the words said.

**No transcript** and **No names yet** show what is missing. The missing
transcripts start in one click.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/people-dark.gif">
  <img align="right" width="380" src=".github/images/people.gif" alt="From the ··· menu, People… opens the list of people: Sam, Priya Shah, José Ortiz, Ana and Mei, each with a note. Nora Quinn is added with the note “sales”.">
</picture>

### Keep a list of who you meet

Names with a word on who they are. Add them here, or press
**Fill from your AI** and your agent writes the list.

The list feeds the name suggestions, and transcripts spell those names
right.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/floating-dark.gif">
  <img align="left" width="380" src=".github/images/floating.gif" alt="In a video call in another app, ⌥⌘R starts recording, and small controls float under the menu bar with the time, Pause and Stop. The panel opens, and the call’s words arrive in its Transcript row a few at a time. Stop on the floating controls saves: the recording drops from the menu bar and names itself “Beta launch plan”.">
</picture>

### Record from any app

Press **⌥⌘R** mid-call. Small controls float over your windows to
pause or stop. Click the cassette in the menu bar to read the words as
they're said.

<br clear="all">

## Also

- **Any app.** Zoom, Meet in a browser, Teams, a video. No bot joins the call.
- **Switch devices.** AirPods in or out mid-call, and it keeps recording.
- **Nothing lost.** Audio is written as it records, so a crash keeps the meeting.
- **Free up space.** Clear the audio of old meetings in one go, transcripts kept.
- **Private.** Recording and transcription run on your Mac, in 52 languages.
  Only the agent you pick sees a transcript.

Recording people may need their consent where you live.

## The folder

Every recording is a folder of plain files. `AGENTS.md` tells agents what
each one means, and TapeUp has a command line they can use.

```
~/TapeUp/
├── AGENTS.md         what everything here means
├── people.json       who you meet with
└── 2026/2026-11-07-1400 Beta launch plan/
    ├── audio.m4a     your mic left, your Mac right
    ├── transcript.md
    └── meta.json     when, how long, who was there
```

## Command line

Your agent can work on saved recordings with TapeUp's own command line:
`/Applications/TapeUp.app/Contents/MacOS/TapeUp help`. These examples use
`TapeUp` for that path.

```text
TapeUp folder [<path> [--move]]
TapeUp import <file> [--title T]
TapeUp title <recording> <title>
TapeUp transcribe <recording>
TapeUp speakers <recording> [--voices N]
TapeUp voices <recording>
TapeUp voices name <recording> <voice> <person>
TapeUp people
TapeUp people add <name> [--context C]
TapeUp people rename <old> <new> [--merge]
TapeUp people remove <name>
TapeUp remove-audio <recording>
TapeUp keep <recording>
TapeUp agent [off] [--model M] [--effort E]
```

Give a recording's folder, folder name, start time (`2026-11-06-1430`),
or `latest`: the recording that started most recently, excluding one still
recording. An import uses the file’s date; use the stamp it prints, not
`latest`, for later commands. Import copies one audio or
video file in, leaves the original, then transcribes and labels its speakers.
It waits until everything is ready. Running the same import again keeps the
first copy and finishes any missing work. Allow a long timeout or run in
the background. After interruption, missing stages resume; a transcript
restarts. A duplicate import reports an ignored `--title` and the existing title.
`speakers` keeps existing labels and names unless you ask for a different
voice count with `--voices`. A changed count can change voice numbers; names
follow a clear majority of their earlier lines. An ambiguous merge can leave
a voice unnamed, so review the voices afterward.

`voices` gives each voice's number, name, where the name came from, talk time
and a quote. Name a voice only when the user said who it is: TapeUp learns
that person's voice from it. It changes only that voice; other fills stay
unchecked. Give `""` to clear a name. Placeholder names are refused. Correcting a name
TapeUp filled in lists similar earlier fills for the user to review; it
changes none of them by itself. Each offered correction includes the exact
`voices name` command with a stale-fill guard; ask the user before running
it. Its name changes only the reviewed voice.

Change people with `TapeUp people`: renames follow through recordings and
remembered voices. A rename prints its reverse command. Ask the user whether
two listed names are the same person before using `--merge`; merges and
removals cannot be undone from the command line. Removing a person
forgets their voice and leaves past recordings' names. `remove-audio` moves
audio to the Trash once its transcript is complete, its speakers are labeled
and nothing is using it. The result gives its Trash path; Finder's Put Back
restores it. `keep` locks audio against removal. Only the user unlocks it in
Free up space.

`Next:` suggests a likely next step; run it only if it serves the request.
Commands in results use the running executable's path unless it is on PATH. Use `--json` when
branching in code, and plain output when reading or telling the user. JSON
mode gives one object on stdout or one error object on stderr, without
progress. Voice listings contain a `voices` array; when names are missing,
`next` asks the user who they are before showing a command shape. While the app runs, commands go through it so its list and Undo follow along. Recordings start in the app.

## First launch

TapeUp is free and isn't notarized by Apple, so macOS stops it once:

1. Open TapeUp. When macOS says it can't verify it, click **Done**.
2. In **System Settings › Privacy & Security**, scroll to Security and click
   **Open Anyway** next to TapeUp.

<p align="center">
  <img src=".github/images/first-launch-warning.png" width="160" alt="macOS says “TapeUp.app” Not Opened: Apple could not verify it is free of malware. The buttons are Move to Trash and Done.">
  &nbsp;
  <img src=".github/images/first-launch-open-anyway.png" width="480" alt="System Settings, Privacy &amp; Security, Security: “TapeUp.app” was blocked to protect your Mac, with an Open Anyway button beside it.">
</p>

3. Click the cassette in the menu bar. TapeUp downloads its speech model once
   (2.3 GB, or 680 MB on Macs with less than 16 GB of memory).

After that, TapeUp updates itself. It checks once a day and never installs
while you record; **Check for Updates…** is in the ··· menu.

## Models

TapeUp runs open models on your Mac with [speech-swift](https://github.com/soniqo/speech-swift) on MLX:

- **Transcripts:** [Qwen3-ASR 1.7B](https://huggingface.co/aufklarer/Qwen3-ASR-1.7B-MLX-8bit), 8-bit,
  or [0.6B](https://huggingface.co/aufklarer/Qwen3-ASR-0.6B-MLX-4bit), 4-bit, on Macs with less than
  16 GB of memory, with [Silero](https://huggingface.co/aufklarer/Silero-VAD-v6.2.1-MLX) to find the pauses.
- **Speakers:** [Nemotron 3 Diarization](https://huggingface.co/aufklarer/Nemotron-3-Diarization-100M-MLX-INT8)
  and [WeSpeaker](https://huggingface.co/aufklarer/WeSpeaker-ResNet34-LM-MLX) voice prints.
- **Titles and who was there:** the Claude Code or Codex you pick, with the
  model it is set to. Without one, Apple Intelligence's model on your Mac
  writes the titles.

## Build

Needs Xcode and its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```bash
make verify-full   # format check, build, tests
make install       # puts TapeUp in Applications and opens it
```

The design and its decisions are in [`_docs/SYSTEM.md`](_docs/SYSTEM.md).
Issues and pull requests are welcome.

## License

MIT. See [LICENSE](LICENSE).

## How to update this document

Keep the examples aligned with `TapeUp help` and describe what people can do
with the released app. Keep architecture in `_docs/SYSTEM.md`.

## Open Questions

None currently.
