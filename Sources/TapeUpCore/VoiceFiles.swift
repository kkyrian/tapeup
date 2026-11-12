import Foundation

/// Undo restores a file only while it still contains this operation's bytes.
/// Later edits, unreadable files and busy recordings are reported and left alone.
public struct VoiceFileUndo: Sendable {
    struct File: Sendable {
        var url: URL
        var data: Data?
        var written: Data?
    }
    var files: [File]
    var root: URL? = nil
    public var fileCount: Int { files.count }

    public struct RestoreResult: Sendable {
        public var restored: [URL] = []
        public var skipped: [URL] = []
    }

    @discardableResult
    public func restore() throws -> RestoreResult {
        if let root { return try VoiceFiles.withRootLock(root) { try restoreLocked() } }
        return try VoiceFiles.locked { try restoreLocked() }
    }

    private func restoreLocked() throws -> RestoreResult {
        var result = RestoreResult()
        let groups = Dictionary(grouping: files, by: { VoiceFiles.recordingFolder(for: $0.url) })
        for (folder, files) in groups {
            var held: FolderLock?
            if let folder {
                held = FolderLock(folder: folder)
                guard held != nil else {
                    result.skipped += files.map(\.url)
                    continue
                }
            }
            defer { held?.release() }
            for file in files.reversed() {
                if try VoiceFiles.restore(file) {
                    result.restored.append(file.url)
                } else {
                    result.skipped.append(file.url)
                }
            }
        }
        return result
    }

    mutating func include(_ next: VoiceFileUndo) {
        if root == nil { root = next.root }
        for file in next.files {
            if let index = files.firstIndex(where: { $0.url == file.url }) {
                files[index].written = file.written
            } else {
                files.append(file)
            }
        }
        files.removeAll { $0.data == $0.written }
    }
}

enum VoiceFiles {
    private static let lock = NSRecursiveLock()
    static let rootLockName = ".voices.lock"
    private static let activeKey = "TapeUpVoiceRoot"

    static func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Keep the lock file: unlinking it would let another process lock a new
    /// inode while a process still holds the old one. Nested saves reuse it.
    static func withRootLock<T>(_ root: URL, _ operation: () throws -> T) throws -> T {
        try locked {
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            let key = "TapeUpVoiceLock:" + root.path
            if Thread.current.threadDictionary[key] != nil { return try operation() }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let descriptor = open(root.appendingPathComponent(rootLockName).path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            Thread.current.threadDictionary[key] = true
            let previous = Thread.current.threadDictionary[activeKey]
            Thread.current.threadDictionary[activeKey] = root
            defer {
                Thread.current.threadDictionary.removeObject(forKey: key)
                if let previous {
                    Thread.current.threadDictionary[activeKey] = previous
                } else {
                    Thread.current.threadDictionary.removeObject(forKey: activeKey)
                }
                flock(descriptor, LOCK_UN)
            }
            return try operation()
        }
    }

    static func withRecordingLock<T>(_ folder: URL, _ operation: () throws -> T) throws -> T {
        let key = "TapeUpVoiceFolder:" + folder.standardizedFileURL.resolvingSymlinksInPath().path
        if Thread.current.threadDictionary[key] != nil { return try operation() }
        guard let held = FolderLock(folder: folder) else { throw VoiceLibrary.Failure.busyRecording }
        Thread.current.threadDictionary[key] = true
        defer {
            Thread.current.threadDictionary.removeObject(forKey: key)
            held.release()
        }
        return try operation()
    }

    static func recordingFolder(for url: URL) -> URL? {
        switch url.lastPathComponent {
        case "meta.json", "events.jsonl", SpeakerLabels.resultFileName, SpeakerLabels.fileName:
            return url.deletingLastPathComponent()
        default: return nil
        }
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func object(_ url: URL) throws -> [String: Any] {
        guard let data = try read(url), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }

    enum Write {
        case file(URL, Data?)
        case meta(URL, (inout [String: Any]) -> Void)
        case event(URL, String, [String: Any])
        var url: URL {
            switch self {
            case .file(let url, _): return url
            case .meta(let folder, _): return MetaFile.url(in: folder)
            case .event(let folder, _, _): return folder.appendingPathComponent("events.jsonl")
            }
        }
    }

    struct RollbackError: Error {
        var original: any Error
        var skipped: [URL]
    }

    /// Read each target immediately before its write, inside the relevant lock.
    static func apply(_ writes: [Write], beforeWrite: (URL) throws -> Void = { _ in }) throws -> VoiceFileUndo {
        var undo = VoiceFileUndo(files: [], root: Thread.current.threadDictionary[activeKey] as? URL)
        do {
            for write in writes {
                try beforeWrite(write.url)
                let file: VoiceFileUndo.File
                switch write {
                case .meta(let folder, let change):
                    file = try MetaFile.withLock {
                        let before = try read(write.url)
                        var object = try self.object(write.url)
                        change(&object)
                        let after = try json(object)
                        if before != after { try put(after, at: MetaFile.url(in: folder)) }
                        return .init(url: write.url, data: before, written: after)
                    }
                case .file(let url, let after):
                    let before = try read(url)
                    if before != after { try put(after, at: url) }
                    file = .init(url: url, data: before, written: after)
                case .event(let folder, let event, let fields):
                    var captured: VoiceFileUndo.File?
                    let appended = EventLog.append(event, fields, in: folder) { before, after in
                        captured = .init(url: write.url, data: before, written: after)
                    }
                    if let captured { undo.include(.init(files: [captured], root: undo.root)) }
                    guard appended, let captured else { throw CocoaError(.fileWriteUnknown) }
                    file = captured
                }
                undo.include(.init(files: [file], root: undo.root))
            }
        } catch {
            // Callers hold folder locks here; do not try to reacquire them.
            let original = error
            var skipped: [URL] = []
            for file in undo.files.reversed() {
                if try !restore(file) { skipped.append(file.url) }
            }
            if !skipped.isEmpty { throw RollbackError(original: original, skipped: skipped) }
            throw original
        }
        return undo
    }

    static func restore(_ file: VoiceFileUndo.File) throws -> Bool {
        if file.url.lastPathComponent == "events.jsonl" {
            return try EventLog.restore(file.data, ifCurrentIs: file.written, in: file.url.deletingLastPathComponent())
        }
        let restore = {
            let current: Data?
            do { current = try read(file.url) } catch { return false }
            guard current == file.written else { return false }
            try put(file.data, at: file.url)
            return true
        }
        if file.url.lastPathComponent == "meta.json" { return try MetaFile.withLock(restore) }
        return try restore()
    }

    static func put(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Patch only owned fields against the fresh metadata. Attendance changes
    /// are name deltas; a concurrent count or an unrelated field is preserved.
    static func metadataWrite(before: [String: Any], after: [String: Any], folder: URL) -> Write {
        .meta(folder) { fresh in
            if before["you"] as? String != after["you"] as? String { fresh["you"] = after["you"] }
            let oldWho = before["who_was_there"] as? [String: Any] ?? [:]
            let newWho = after["who_was_there"] as? [String: Any] ?? [:]
            let oldNames = oldWho["names"] as? [String] ?? []
            let newNames = newWho["names"] as? [String] ?? []
            if oldNames != newNames {
                var who = fresh["who_was_there"] as? [String: Any] ?? [:]
                var names = who["names"] as? [String] ?? []
                let removed = Set(oldNames.filter { !newNames.contains($0) }.map { $0.lowercased() })
                names.removeAll { removed.contains($0.lowercased()) }
                let oldKeys = Set(oldNames.map { $0.lowercased() })
                // A case-only rename still replaces the original spelling.
                let replacements = Set(oldNames.filter { !newNames.contains($0) }.map { $0.lowercased() })
                for name in newNames
                where !oldKeys.contains(name.lowercased()) || replacements.contains(name.lowercased()) {
                    if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                        names.append(name)
                    }
                }
                who["names"] = names
                fresh["who_was_there"] = who
            }
            let oldLabels = before["speaker_labels"] as? [String: Any] ?? [:]
            let newLabels = after["speaker_labels"] as? [String: Any] ?? [:]
            var labels = fresh["speaker_labels"] as? [String: Any] ?? [:]
            for key in ["names", "status", "file", "voices", "voices_estimated", "error"] {
                if !NSDictionary(dictionary: ["value": oldLabels[key] ?? NSNull()]).isEqual(to: [
                    "value": newLabels[key] ?? NSNull()
                ]) {
                    labels[key] = newLabels[key]
                }
            }
            if !newLabels.isEmpty { fresh["speaker_labels"] = labels }
        }
    }

    static func speakerWrites(
        _ result: SpeakerResult, lines: [TranscriptLine], meta: [String: Any], folder: URL,
        before: [String: Any]? = nil
    ) throws -> [Write] {
        var updated = meta
        var labels = meta["speaker_labels"] as? [String: Any] ?? [:]
        labels["names"] = result.voices.compactMap { result.names[$0.id] }
        updated["speaker_labels"] = labels
        let transcript = meta["transcript"] as? [String: Any] ?? [:]
        let rendered = SpeakerLabels.render(
            lines: lines, assigned: result.assigned, names: result.names,
            model: transcript["model"] as? String ?? "Qwen3-ASR", missing: transcript["missing_passages"] as? Int ?? 0)
        return [
            .file(folder.appendingPathComponent(SpeakerLabels.resultFileName), try JSONEncoder().encode(result)),
            .file(folder.appendingPathComponent(SpeakerLabels.fileName), Data(rendered.utf8)),
            metadataWrite(before: before ?? meta, after: updated, folder: folder),
        ]
    }
}

extension SpeakerLabels {
    /// Fold and renumber prints exactly as the saved labels were made. A
    /// mismatch yields no prints rather than teaching a different voice.
    public static func prints(of result: SpeakerResult, heard: VoicePrints, lines: [TranscriptLine]) -> [Int: [Float]] {
        guard lines.count == result.assigned.count else { return [:] }
        let found = max(1, result.count)
        let counts: [Int?] =
            result.estimated
            ? [nil]
            : result.folded.map { [$0] }
                ?? Array((found...max(found, Set(heard.turns.map(\.voice)).count)).reversed())
        for count in counts {
            let groups = VoiceFolding.fold(heard, count: count)
            let turns = heard.turns.map { VoiceTurn(start: $0.start, end: $0.end, voice: groups[$0.voice] ?? $0.voice) }
            let (raw, number) = numbered(lines: lines, turns: turns)
            guard raw.map({ $0.flatMap { number[$0] } }) == result.assigned else { continue }
            var sums: [Int: [Double]] = [:]
            for turn in heard.turns {
                guard let voice = number[groups[turn.voice] ?? turn.voice], let print = heard.prints[turn.voice],
                    VoiceStore.validPrint(print), turn.end > turn.start
                else { continue }
                let length = sqrt(print.reduce(Double(0)) { $0 + Double($1) * Double($1) })
                var sum = sums[voice] ?? Array(repeating: 0, count: VoiceStore.dimensions)
                for i in sum.indices { sum[i] += Double(print[i]) / length * (turn.end - turn.start) }
                sums[voice] = sum
            }
            return sums.compactMapValues { sum in
                let length = sqrt(sum.reduce(0) { $0 + $1 * $1 })
                return length > 0 ? sum.map { Float($0 / length) } : nil
            }
        }
        return [:]
    }

    public static func microphoneOnlyVoices(lines: [TranscriptLine], assigned: [Int?]) -> Set<Int> {
        var sides: [Int: [Side?]] = [:]
        for (line, voice) in zip(lines, assigned) {
            if let voice { sides[voice, default: []].append(line.side) }
        }
        // A second voice heard partly on the mic disqualifies the shortcut too.
        let microphone = sides.filter { $0.value.contains(.microphone) }
        guard microphone.count == 1, let entry = microphone.first,
            entry.value.allSatisfy({ $0 == .microphone })
        else { return [] }
        return [entry.key]
    }
}
