import Foundation

/// One recording folder as the app lists it.
public struct RecordingEntry: Sendable, Identifiable, Equatable {
    public var id: String { folder.path }
    public let folder: URL
    public let started: Date
    public let duration: Double
    public let audio: URL
    public let status: String
    public var people: People
    /// The name the user gave it; the folder keeps its dated name.
    public var title: String?
    /// A title made from the transcript, shown until the user names it.
    public var titleSuggestion: String?
    public var transcript: Transcript
    /// Kept: Free up space never removes its audio.
    public var keepAudio: Bool

    public init(
        folder: URL, started: Date, duration: Double, audio: URL, status: String, people: People,
        title: String? = nil, titleSuggestion: String? = nil, transcript: Transcript = .none, keepAudio: Bool = false
    ) {
        self.keepAudio = keepAudio
        self.title = title
        self.titleSuggestion = titleSuggestion
        self.transcript = transcript
        self.folder = folder
        self.started = started
        self.duration = duration
        self.audio = audio
        self.status = status
        self.people = people
    }

    /// Who was there: an optional head count and optional names.
    public struct People: Sendable, Equatable {
        public var count: Int?
        public var names: [String]

        public init(count: Int? = nil, names: [String] = []) {
            self.count = count
            self.names = names
        }

        public var isEmpty: Bool { count == nil && names.isEmpty }
    }

    /// How far the recording's transcript has got.
    public enum Transcript: Sendable, Equatable {
        /// Never asked for: recorded with transcripts off, or before TapeUp made them.
        case none
        /// Waiting for the model, or being made now.
        case pending
        case done
        case failed
    }

    public var transcriptFile: URL { folder.appendingPathComponent(TranscriptDocument.fileName) }

    /// False once the user removed the audio and kept the transcript.
    public var hasAudio: Bool { FileManager.default.fileExists(atPath: audio.path) }

    /// The labeled lines Copy path puts on the clipboard. The transcript is
    /// the one with speaker names once the user has labeled speakers.
    public var clipboardText: String {
        var text = "folder: \(folder.path)"
        if hasAudio { text += "\naudio: \(audio.path)" }
        if transcript == .done {
            let labeled = folder.appendingPathComponent(SpeakerLabels.fileName)
            let file = FileManager.default.fileExists(atPath: labeled.path) ? labeled : transcriptFile
            text += "\ntranscript: \(file.path)"
        }
        return text
    }
}

/// The recordings root: creating folders, listing them, and editing the
/// optional fields of `meta.json` without touching anything else in it.
public struct RecordingLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// Serializes library edits with the existing people and voice-store lock.
    public func withLock<T>(_ operation: () throws -> T) throws -> T {
        try VoiceFiles.withRootLock(root, operation)
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TapeUp", isDirectory: true)
    }

    /// A new folder in its year's folder, named for the minute it starts,
    /// suffixed when another folder already starts with that stamp, titled
    /// or not: `2026/2026-11-06-1430`, then `2026/2026-11-06-1430-2`.
    public func newFolder(at date: Date = Date()) throws -> URL {
        try prepareRoot()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: date)
        let year = root.appendingPathComponent(String(name.prefix(4)), isDirectory: true)
        try FileManager.default.createDirectory(at: year, withIntermediateDirectories: true)
        // A titled folder holds its stamp under a longer name.
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: year.path)) ?? []).map(Self.stamp(of:)))
        // Creating is the check: another recorder may take a name between a
        // look and a create.
        for suffix in 1...999 {
            let stamp = suffix == 1 ? name : "\(name)-\(suffix)"
            guard !taken.contains(stamp) else { continue }
            let folder = year.appendingPathComponent(stamp, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Creates the root and its `AGENTS.md` when missing. An `AGENTS.md` the
    /// user has changed is theirs and is never rewritten.
    public func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guide = root.appendingPathComponent("AGENTS.md")
        if let existing = try? String(contentsOf: guide, encoding: .utf8),
            // Compared without trailing blank lines, which editors add.
            !Self.earlierAgentsGuides.map(Self.trimmedEnd).contains(Self.trimmedEnd(existing))
        {
            return
        }
        try Self.agentsGuide.write(to: guide, atomically: true, encoding: .utf8)
    }

    /// Moves every recording, and `people.json` and `AGENTS.md` when the new
    /// root has none, into `destination`. A recording whose folder name is
    /// already taken there stays where it is. Other files at the old root stay.
    public func move(to destination: URL) throws -> (moved: Int, skipped: [String]) {
        let target = RecordingLibrary(root: destination)
        try target.prepareRootFolder()
        let manager = FileManager.default
        var moved = 0
        var skipped: [String] = []
        for folder in recordingFolders() {
            let name = folder.lastPathComponent
            let year = destination.appendingPathComponent(folder.deletingLastPathComponent().lastPathComponent)
            let to = year.appendingPathComponent(name, isDirectory: true)
            guard !manager.fileExists(atPath: to.path) else {
                skipped.append(name)
                continue
            }
            try manager.createDirectory(at: year, withIntermediateDirectories: true)
            try manager.moveItem(at: folder, to: to)
            moved += 1
        }
        for file in [PeopleList.fileName, VoiceStore.fileName, VoiceLibrary.pendingRenamesFileName, "AGENTS.md"] {
            let from = root.appendingPathComponent(file)
            let to = destination.appendingPathComponent(file)
            if manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) {
                try manager.moveItem(at: from, to: to)
            }
        }
        try target.prepareRoot()
        return (moved, skipped)
    }

    private func prepareRootFolder() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Every folder inside the year folders (`2026/…`), newest first by name.
    public func recordingFolders() -> [URL] {
        func folders(in url: URL) -> [URL] {
            let found =
                (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            return found.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        return folders(in: root)
            .filter { $0.lastPathComponent.wholeMatch(of: /\d{4}/) != nil }
            .flatMap(folders(in:))
            .filter(Self.hasMetadata)
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Recordings newest first. Folders without a readable `meta.json` are skipped.
    public func entries(limit: Int = .max) -> [RecordingEntry] {
        recordingFolders()
            .lazy
            .compactMap(Self.entry(at:))
            .prefix(limit)
            .map { $0 }
    }

    public static func entry(at folder: URL) -> RecordingEntry? {
        guard let meta = readMeta(folder), let startedText = meta["started"] as? String,
            let started = ISO8601DateFormatter().date(from: startedText)
        else { return nil }
        let audioName = meta["audio"] as? String ?? "audio.m4a"
        var people = RecordingEntry.People()
        if let who = meta["who_was_there"] as? [String: Any] {
            people.count = who["count"] as? Int
            people.names = who["names"] as? [String] ?? []
        }
        return RecordingEntry(
            folder: folder, started: started, duration: meta["duration_seconds"] as? Double ?? 0,
            audio: folder.appendingPathComponent(audioName), status: meta["status"] as? String ?? "recording",
            people: people, title: (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            titleSuggestion: (meta["title_suggestion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            transcript: transcriptState(meta, folder: folder), keepAudio: meta["keep_audio"] as? Bool ?? false)
    }

    /// Marks a recording as kept, or not, in `meta.json`.
    public static func save(keepAudio: Bool, in folder: URL) throws {
        try MetaFile.update(folder) { $0["keep_audio"] = keepAudio ? true : nil }
    }

    static func transcriptState(_ meta: [String: Any], folder: URL) -> RecordingEntry.Transcript {
        switch (meta["transcript"] as? [String: Any])?["status"] as? String {
        case "waiting", "transcribing": .pending
        case "failed": .failed
        case "done":
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptDocument.fileName).path)
                ? .done : .failed
        default: .none
        }
    }

    /// Records how far the transcript has got in `meta.json`'s `transcript`
    /// field; `done` also moves `status` on to `transcribed`.
    public static func markTranscript(
        _ status: String, model: String? = nil, sideLabels: Bool? = nil, missing: Int = 0, error: String? = nil,
        in folder: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: MetaFile.url(in: folder).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try MetaFile.update(folder) { meta in
            var transcript: [String: Any] = ["status": status]
            if let model { transcript["model"] = model }
            if status == "done" {
                transcript["file"] = TranscriptDocument.fileName
                transcript["side_labels"] = sideLabels ?? false
                if missing > 0 { transcript["missing_passages"] = missing }
                // Only a final audio.m4a moves on; a recording whose encoding
                // failed keeps saying so.
                if meta["status"] as? String == "recorded" { meta["status"] = "transcribed" }
            }
            if let error { transcript["error"] = error }
            meta["transcript"] = transcript
        }
    }

    /// A recording named the way a person or agent would: its folder path,
    /// its folder name, or the time stamp it starts with. A path into another
    /// recordings folder names nothing here.
    public func recording(_ argument: String) -> URL? {
        if argument == "latest" {
            return entries().filter { $0.status != "recording" }.max { $0.started < $1.started }?.folder
        }
        let stamp = Self.stamp(of: URL(fileURLWithPath: argument).lastPathComponent)
        guard let folder = folder(withStamp: stamp) else { return nil }
        if argument.hasPrefix("/") || argument.hasPrefix("~") {
            let given = URL(fileURLWithPath: (argument as NSString).expandingTildeInPath)
            let parent = given.deletingLastPathComponent().deletingLastPathComponent()
            guard parent.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else { return nil }
        }
        return folder
    }

    /// Only real recording directories participate. An ambiguous stamp has no
    /// winner; callers must report the conflict instead of trusting listing order.
    public func folders(withStamp stamp: String) -> [URL] {
        let year = root.appendingPathComponent(String(stamp.prefix(4)), isDirectory: true)
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: year,
                includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.filter {
            Self.stamp(of: $0) == stamp
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && Self.hasMetadata($0)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func hasMetadata(_ folder: URL) -> Bool {
        (try? MetaFile.url(in: folder).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public func folder(withStamp stamp: String) -> URL? {
        let matches = folders(withStamp: stamp)
        return matches.count == 1 ? matches[0] : nil
    }

    public static func stamp(of folder: URL) -> String { stamp(of: folder.lastPathComponent) }

    /// Saves the recording's title into `meta.json` and names the folder
    /// after it, after the time it started (`2026-11-06-1430 Lab sync`), so
    /// Finder shows familiar names. An empty title removes both. Returns the
    /// folder's new location; it stays put when the new name is taken.
    @discardableResult
    public static func save(title: String?, in folder: URL) throws -> URL {
        let parent = folder.deletingLastPathComponent()
        let root =
            parent.lastPathComponent == String(stamp(of: folder).prefix(4))
            ? parent.deletingLastPathComponent() : parent
        return try VoiceFiles.withRootLock(root) {
            try MetaFile.withLock(in: folder) { folder in
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try MetaFile.update(folder) { meta in
                    meta["title"] = trimmed.isEmpty ? nil : trimmed
                    // A name given settles the suggestion.
                    if !trimmed.isEmpty { meta["title_suggestion"] = nil }
                }
                let name = folderName(stamp: stamp(of: folder.lastPathComponent), title: trimmed)
                guard name != folder.lastPathComponent else { return folder }
                let renamed = folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
                do {
                    try FileManager.default.moveItem(at: folder, to: renamed)
                    return renamed
                } catch CocoaError.fileWriteFileExists {
                    return folder
                }
            }
        }
    }

    /// The `yyyy-MM-dd-HHmm` start of a folder name, with its `-2` suffix.
    static func trimmedEnd(_ text: String) -> String {
        var text = Substring(text)
        while text.last?.isWhitespace == true { text = text.dropLast() }
        return String(text)
    }

    static func stamp(of name: String) -> String {
        let pattern = /^\d{4}-\d{2}-\d{2}-\d{4}(-\d+)?/
        return name.prefixMatch(of: pattern).map { String($0.output.0) } ?? name
    }

    static func folderName(stamp: String, title: String) -> String {
        let safe = title.map { "/:".contains($0) || $0.isNewline ? "-" : $0 }
        let clipped = String(String(safe).prefix(60)).trimmingCharacters(in: .whitespaces)
        let visible = clipped.hasPrefix(".") ? String(clipped.drop { $0 == "." }) : clipped
        return visible.isEmpty ? stamp : "\(stamp) \(visible)"
    }

    /// Keeps a suggested title in `meta.json`; nothing is renamed until the
    /// user accepts it.
    public static func save(titleSuggestion: String, in folder: URL) throws {
        try MetaFile.update(folder) { $0["title_suggestion"] = titleSuggestion }
    }

    public static func save(people: RecordingEntry.People, in folder: URL) throws {
        try MetaFile.update(folder) { meta in
            if people.isEmpty {
                meta["who_was_there"] = nil
            } else {
                var who: [String: Any] = ["names": people.names]
                if let count = people.count { who["count"] = count }
                meta["who_was_there"] = who
            }
        }
    }

    static func readMeta(_ folder: URL) -> [String: Any]? { MetaFile.read(folder) }

    static let agentsGuide = """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent. The user may remove it to keep only the
          transcript; `events.jsonl` then has an `audio removed` line.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once speakers are
          labeled: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count. TapeUp fills in
          the names of voices it recognizes from earlier recordings.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`. `keep_audio` is true
          when the user chose to keep the audio when clearing space.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made`,
          `agent failed` or `person renamed` (a person renamed everywhere).

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        Make changes through `TapeUp people` so every recording and the remembered
        voices follow.
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts. `.voices.json` holds the voice
        prints TapeUp remembers to recognize people: biometric data that stays
        on this Mac. Never copy it, send it anywhere, or edit it.

        A recording imported from another file has `imported` in `meta.json`
        (`file`: the original name, `fingerprint`: its SHA-256, `at`: when it
        was imported) and an empty `sources`. Its `audio.m4a` has the same sound
        in both channels, so it has no sides; `started` is when the file says it
        was recorded. The original file stays where it was.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists the command
        line: import a file (copy, transcribe and label speakers, resuming on
        retry); set a title; transcribe; ensure speaker labels; list voices
        with `TapeUp voices`; name one with `TapeUp voices name`; manage people
        with `TapeUp people`; remove audio or lock it to keep it. A recording
        is its folder, folder name, start stamp (`2026-11-06-1430`), or `latest`
        (the most recent saved recording, never one still recording). Name a
        voice only when the user said who it is: TapeUp learns from it. Ask
        before applying any offered correction to earlier fills. Commands give
        a copyable `Next:` step and say how to undo when possible; use `--json`
        when branching in code and plain output when reading or telling the
        user. Recordings are started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """

    /// Guides earlier versions wrote. A file still identical to one is
    /// TapeUp's own text, not the user's, and is brought up to date.
    static let earlierAgentsGuides = [
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent. The user may remove it to keep only the
          transcript; `events.jsonl` then has an `audio removed` line.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once speakers are
          labeled: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count. TapeUp fills in
          the names of voices it recognizes from earlier recordings.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`. `keep_audio` is true
          when the user chose to keep the audio when clearing space.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made`,
          `agent failed` or `person renamed` (a person renamed everywhere).

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        Make changes through `TapeUp people` so every recording and the remembered
        voices follow.
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts. `.voices.json` holds the voice
        prints TapeUp remembers to recognize people: biometric data that stays
        on this Mac. Never copy it, send it anywhere, or edit it.

        A recording imported from another file has `imported` in `meta.json`
        (`file`: the original name, `fingerprint`: its SHA-256, `at`: when it
        was imported) and an empty `sources`. Its `audio.m4a` has the same sound
        in both channels, so it has no sides; `started` is when the file says it
        was recorded. The original file stays where it was.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: import a file, show or change this folder,
        name a recording or a voice, make a transcript, label speakers, manage
        people, remove audio or lock it to keep it. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent. The user may remove it to keep only the
          transcript; `events.jsonl` then has an `audio removed` line.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once speakers are
          labeled: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count. TapeUp fills in
          the names of voices it recognizes from earlier recordings.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`. `keep_audio` is true
          when the user chose to keep the audio when clearing space.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made`,
          `agent failed` or `person renamed` (a person renamed everywhere).

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts. `.voices.json` holds the voice
        prints TapeUp remembers to recognize people: biometric data that stays
        on this Mac. Never copy it, send it anywhere, or edit it.

        A recording imported from another file has `imported` in `meta.json`
        (`file`: the original name, `fingerprint`: its SHA-256, `at`: when it
        was imported) and an empty `sources`. Its `audio.m4a` has the same sound
        in both channels, so it has no sides; `started` is when the file says it
        was recorded. The original file stays where it was.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent. The user may remove it to keep only the
          transcript; `events.jsonl` then has an `audio removed` line.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once speakers are
          labeled: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made` or
          `agent failed`.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        A recording imported from another file has `imported` in `meta.json`
        (`file`: the original name, `fingerprint`: its SHA-256, `at`: when it
        was imported) and an empty `sources`. Its `audio.m4a` has the same sound
        in both channels, so it has no sides; `started` is when the file says it
        was recorded. The original file stays where it was.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made` or
          `agent failed`.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        A recording imported from another file has `imported` in `meta.json`
        (`file`: the original name, `fingerprint`: its SHA-256, `at`: when it
        was imported) and an empty `sources`. Its `audio.m4a` has the same sound
        in both channels, so it has no sides; `started` is when the file says it
        was recorded. The original file stays where it was.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `title_suggestion` when
          TapeUp or the user's agent suggested one the user has not accepted (not a name), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `agent failed`.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Never rewritten once finished. See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `title_suggestion` when
          TapeUp suggested one the user has not accepted (not a name), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Each folder here is one recording made by TapeUp, named for the minute it
        started (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute),
        then its title once the user names it (`2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), and, when the user filled it in,
          `who_was_there` with an optional `count` (including the user) and
          optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it; transcripts can use it to label speakers.

        `status` is `recording` while it runs and `recorded` once `audio.m4a` is
        final. If a folder still says `recording` with an `audio.caf`, TapeUp
        stopped unexpectedly; it finishes such folders the next time it opens.

        Later steps may add their own status values (for example `transcribed`)
        and files; keep the files above unchanged.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file.

        """,
        """
        # TapeUp recordings

        Each folder here is one recording made by TapeUp, named for the minute it
        started (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute).

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), and, when the user filled it in,
          `who_was_there` with an optional `count` (including the user) and
          optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it; transcripts can use it to label speakers.

        `status` is `recording` while it runs and `recorded` once `audio.m4a` is
        final. If a folder still says `recording` with an `audio.caf`, TapeUp
        stopped unexpectedly; it finishes such folders the next time it opens.

        Later steps may add their own status values (for example `transcribed`)
        and files; keep the files above unchanged.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file.

        """,
        """
        # TapeUp recordings

        Each folder here is one recording made by TapeUp, named for the minute it
        started (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute).

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), and, when the user filled it in,
          `who_was_there` with an optional `count` (including the user) and
          optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it; transcripts can use it to label speakers.

        `status` is `recording` while it runs and `recorded` once `audio.m4a` is
        final. If a folder still says `recording` with an `audio.caf`, TapeUp
        stopped unexpectedly; it finishes such folders the next time it opens.

        Later steps may add their own status values (for example `transcribed`)
        and files; keep the files above unchanged.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `title_suggestion` when
          TapeUp suggested one the user has not accepted (not a name), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Never rewritten once finished. See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `title_suggestion` when
          TapeUp suggested one the user has not accepted (not a name), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Never rewritten once finished. See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Never rewritten once finished. See "Sides" below.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Never rewritten once finished. See "Sides" below.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once the user names it (`2026/2026-11-06-1430 Lab sync`). A
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` when the user named the recording, `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), and, when the user filled it in,
          `who_was_there` with an optional `count` (including the user) and
          optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it; transcripts can use it to label speakers.

        `status` is `recording` while it runs and `recorded` once `audio.m4a` is
        final. If a folder still says `recording` with an `audio.caf`, TapeUp
        stopped unexpectedly; it finishes such folders the next time it opens.

        Later steps may add their own status values (for example `transcribed`)
        and files; keep the files above unchanged.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file.

        """,
        """
        # TapeUp recordings

        Recordings are filed by year: each folder inside `2026/` and the like is
        one recording made by TapeUp, named for the minute it started
        (`YYYY-MM-DD-HHMM`, with `-2`, `-3` when two start in the same minute), then
        its title once it has one (`2026/2026-11-06-1430 Lab sync`). A title is
        made from the transcript unless the user names the recording first, and a
        rename moves the folder, so look recordings up by folder, not by a saved path.

        - `audio.m4a`: stereo AAC. **Left channel: the microphone** (the person at
          this Mac). **Right channel: everything the Mac played** (the other people
          on a call, a video, a lecture). Never modified once written; write
          derived files beside it. When the user recorded only one source, the
          other channel is silent.
        - `transcript.md`: made on this Mac while recording, one paragraph per
          stretch of speech, each starting with its time from the start of
          `audio.m4a`. Rewritten only when asked to transcribe again (then
          speaker labels are redone from the same voices). See "Sides" below.
        - `transcript-with-speaker-labels.md`: present once the user asked for
          speaker labels: the same lines, each starting with who spoke, a name
          the user picked or `Voice 1`, `Voice 2` (numbered by talk time). Rewritten
          when the user names a voice or changes the count.
        - `meta.json`: `started` (ISO 8601), `duration_seconds`, `status`,
          `title` once the recording is named (by the user, or made from the
          transcript by TapeUp or the user's agent), `sources` (what was
          recorded: `microphone`, `computer audio` or both), `paused_seconds`
          when the user paused (paused time is left out of the audio),
          `devices` (inputs and outputs used, in order), `timeline` (silence
          inserted where a device switched), `transcript` (`status`: `waiting`,
          `transcribing`, `done` or `failed`; `model`; `side_labels`;
          `missing_passages` when some speech could not be transcribed),
          `speaker_labels` once asked for (`status`: `finding`, `done` or
          `failed`; `voices`; `voices_estimated`, true when the user gave no
          count; `names`), and, when
          the user filled it in, `who_was_there` with an optional `count`
          (including the user) and optional `names`.
        - `events.jsonl`: what happened while recording, one JSON object per line;
          later work adds lines with an `at` time, such as `title made` or
          `agent failed`.

        `people.json` beside this file lists the people the user records with
        (`you` is the user; each person has a `name` and an optional `context`).
        TapeUp suggests names from it and gives the names to the speech model, so
        they are spelled right in transcripts.

        `status` is `recording` while it runs, `recorded` once `audio.m4a` is
        final, and `transcribed` once `transcript.md` is. If a folder still says
        `recording` with an `audio.caf`, TapeUp stopped unexpectedly; it finishes
        such folders the next time it opens.

        ## Sides

        When the computer audio played into headphones for the whole recording,
        each line of `transcript.md` starts with the side it was heard on:
        `Microphone` (said at this Mac) or `Computer audio` (played by the Mac,
        such as the other people on a call). Either side can be more than one
        person: several people can share one microphone, and a call can have many
        people on the other end. A side is never a person's name.

        With speakers, the microphone also hears the call, so the two sides
        cannot be told apart and lines carry no side (`side_labels` is false).
        Telling individual voices apart is a separate step the user asks for; it
        writes `transcript-with-speaker-labels.md` and leaves `transcript.md` as
        it is. Voice labels come from how voices sound: lines where two people
        talk at once, or people sharing one microphone, are the most often wrong.

        ## Commands

        `/Applications/TapeUp.app/Contents/MacOS/TapeUp help` lists what you can
        do from the command line: show or change this folder, name a recording,
        make its transcript again, label its speakers. A recording is named by
        its folder or the time it starts with (`2026-11-06-1430`). Recordings are
        started only in the app.

        ## Your rules

        Write your own instructions for agents here: how to name transcripts,
        where summaries go, who usually attends. TapeUp never rewrites this file
        once you change it.

        """,
    ]
}
