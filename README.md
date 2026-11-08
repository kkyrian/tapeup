<p align="center">
  <img src=".github/images/icon.png" width="96" height="96" alt="">
</p>

<h1 align="center">TapeUp</h1>

<p align="center">
  <b>Record any meeting on your Mac. Get a transcript you and your AI agent can use.</b><br>
  A click records both sides of the call: your voice and everything your Mac plays.<br>
  TapeUp transcribes it on your Mac while you talk.
</p>

<p align="center">
  <a href="https://github.com/kkyrian/tapeup/releases/latest/download/TapeUp.dmg"><b>Download for Mac</b></a>
  &nbsp;·&nbsp; free, MIT license &nbsp;·&nbsp; macOS 15 or later, Apple silicon
</p>

```bash
brew install kkyrian/tap/tapeup
```

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/images/record-dark.gif">
    <img src=".github/images/record.gif" width="420" alt="Clicking the cassette in the menu bar opens TapeUp. Record starts the clock, and the call's words appear in the Transcript row. Stop saves the recording, and it names itself “Beta launch plan”.">
  </picture>
</p>

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/floating-dark.gif">
  <img align="left" width="380" src=".github/images/floating.gif" alt="In a video call in another app, ⌥⌘R starts recording. Small controls float under the menu bar with the time, Pause and Stop. Pause holds the clock, play resumes, and Stop saves: the recording drops from the menu bar and names itself “Beta launch plan”.">
</picture>

### Record from any app

Press **⌥⌘R** mid-call. Small controls float over your windows to
pause or stop, and the saved recording drops from the menu bar.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/who-was-there-dark.gif">
  <img align="right" width="380" src=".github/images/who-was-there.gif" alt="A 31-minute call is stopped. On the saved recording, a tap on 4 sets how many were there, and typing “pr”, “jo” and “an” adds Priya Shah, José Ortiz and Ana from suggestions.">
</picture>

### Say who was there

When you stop, tap how many people were on the call and type a few
letters of each name. TapeUp suggests the people you meet with.

It's optional, and it's what a transcript can't know on its own.

<br clear="all">
<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/speakers-dark.gif">
  <img align="left" width="380" src=".github/images/speakers.gif" alt="On a saved recording, Label speakers finds four voices, each with how long it talked and a line it said. The first is named Priya Shah and the fourth José Ortiz from a menu.">
</picture>

### Know who said what

**Label speakers** finds each voice in the recording, on your Mac. Each
one comes with a line it said, so naming it takes a second.

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
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/settings-dark.gif">
  <img align="left" width="380" src=".github/images/settings.gif" alt="From the ··· menu, Settings… opens Settings. Under Your AI, Claude Code is picked instead of Off.">
</picture>

### Let your AI do the naming

Pick Claude Code or Codex in Settings, the one you're signed in to,
and it titles each recording and suggests who was there.

It stays off until you pick one. Without it, Apple Intelligence titles
recordings where your Mac has it.

<br clear="all">
<br>

### Bring in old recordings

Open **Import…** from the ··· menu and drop in files or whole folders,
or drop them on the menu-bar icon. Each comes in under its own name and
date, and is transcribed on your Mac. The originals stay where they are.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset=".github/images/import-dark.gif">
  <img width="100%" src=".github/images/import.gif" alt="From the ··· menu, Import… opens the Import window. Four recordings are dragged in from a Finder window and listed with their dates, lengths and sizes. Import 4 recordings copies them in, Done closes the window, and the recordings appear in TapeUp's list under the days they were made.">
</picture>

## Also

- **Any app.** Zoom, Meet in a browser, Teams, a video. No bot joins the call.
- **Switch devices.** AirPods in or out mid-call, and it keeps recording.
- **Nothing lost.** Audio is written as it records, so a crash keeps the meeting.
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

## First launch

TapeUp is free and isn't notarized by Apple, so macOS stops it once:

1. Open TapeUp. When macOS says it can't verify it, click **Done**.
2. In **System Settings › Privacy & Security**, click **Open Anyway** next to TapeUp.
3. Click the cassette in the menu bar. TapeUp downloads its speech model once
   (2.3 GB, or 680 MB on Macs with less than 16 GB of memory).

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
