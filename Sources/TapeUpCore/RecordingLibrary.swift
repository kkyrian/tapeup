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

    public init(
        folder: URL, started: Date, duration: Double, audio: URL, status: String, people: People,
        title: String? = nil
    ) {
        self.title = title
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

    /// The two labeled lines Copy path puts on the clipboard.
    public var clipboardText: String { "folder: \(folder.path)\naudio: \(audio.path)" }
}

/// The recordings root: creating folders, listing them, and editing the
/// optional fields of `meta.json` without touching anything else in it.
public struct RecordingLibrary: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("TapeUp", isDirectory: true)
    }

    /// A new folder named for the minute it starts, suffixed when that name is taken.
    public func newFolder(at date: Date = Date()) throws -> URL {
        try prepareRoot()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: date)
        // Creating is the check: another recorder may take a name between a
        // look and a create.
        for suffix in 1...999 {
            let folder = root.appendingPathComponent(suffix == 1 ? name : "\(name)-\(suffix)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Creates the root and its `AGENTS.md` when missing. An existing
    /// `AGENTS.md` is the user's and is never rewritten.
    public func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guide = root.appendingPathComponent("AGENTS.md")
        guard !FileManager.default.fileExists(atPath: guide.path) else { return }
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
        for entry in entries() {
            let name = entry.folder.lastPathComponent
            let to = destination.appendingPathComponent(name, isDirectory: true)
            guard !manager.fileExists(atPath: to.path) else {
                skipped.append(name)
                continue
            }
            try manager.moveItem(at: entry.folder, to: to)
            moved += 1
        }
        for file in [PeopleList.fileName, "AGENTS.md"] {
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

    /// Recordings newest first. Folders without a readable `meta.json` are skipped.
    public func entries(limit: Int = .max) -> [RecordingEntry] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return
            folders
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
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
            people: people, title: (meta["title"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Saves the recording's title into `meta.json` and names the folder
    /// after it, after the time it started (`2026-11-06-1430 Lab sync`), so
    /// Finder shows familiar names. An empty title removes both. Returns the
    /// folder's new location; it stays put when the new name is taken.
    @discardableResult
    public static func save(title: String?, in folder: URL) throws -> URL {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try MetaFile.update(folder) { meta in meta["title"] = trimmed.isEmpty ? nil : trimmed }
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

    /// The `yyyy-MM-dd-HHmm` start of a folder name, with its `-2` suffix.
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

        """
}
