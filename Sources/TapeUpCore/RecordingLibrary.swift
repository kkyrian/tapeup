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

    public init(folder: URL, started: Date, duration: Double, audio: URL, status: String, people: People) {
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
        var folder = root.appendingPathComponent(name, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(name)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Creates the root and its `AGENTS.md` when missing. An existing
    /// `AGENTS.md` is the user's and is never rewritten.
    public func prepareRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guide = root.appendingPathComponent("AGENTS.md")
        guard !FileManager.default.fileExists(atPath: guide.path) else { return }
        try Self.agentsGuide.write(to: guide, atomically: true, encoding: .utf8)
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
            people: people)
    }

    /// Saves who was there into the recording's `meta.json`, keeping every other field.
    public static func save(people: RecordingEntry.People, in folder: URL) throws {
        var meta = readMeta(folder) ?? [:]
        if people.isEmpty {
            meta["who_was_there"] = nil
        } else {
            var who: [String: Any] = ["names": people.names]
            if let count = people.count { who["count"] = count }
            meta["who_was_there"] = who
        }
        let data = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func readMeta(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static let agentsGuide = """
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

        """
}
