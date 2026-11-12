import Foundation

/// Byte snapshots for a completed operation. Restore promptly, before other
/// edits to these files: undo deliberately restores the complete original bytes.
public struct VoiceFileUndo: Sendable {
    struct File: Sendable {
        var url: URL
        var data: Data?
    }
    var files: [File]
    public var fileCount: Int { files.count }

    public func restore() throws {
        try VoiceFiles.locked {
            _ = try VoiceFiles.apply(files.map { ($0.url, $0.data) })
        }
    }
}

/// All library voice operations serialize in this process. Callers must mark
/// recordings being written by other work as busy and serialize external edits.
enum VoiceFiles {
    private static let lock = NSRecursiveLock()

    static func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
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

    struct RollbackError: Error {
        var original: any Error
        var rollback: any Error
    }

    /// Snapshot all targets before the first write; rollback only written files.
    /// The hook lets tests exercise a real failure after earlier writes succeed.
    static func apply(
        _ writes: [(URL, Data?)], beforeWrite: (URL) throws -> Void = { _ in }
    ) throws -> VoiceFileUndo {
        let before = try writes.map { VoiceFileUndo.File(url: $0.0, data: try read($0.0)) }
        var written: [VoiceFileUndo.File] = []
        do {
            for (index, write) in writes.enumerated() {
                guard before[index].data != write.1 else { continue }
                try beforeWrite(write.0)
                try put(write.1, at: write.0)
                written.append(before[index])
            }
        } catch {
            let original = error
            var failure: (any Error)?
            for file in written.reversed() {
                do { try put(file.data, at: file.url) } catch { failure = error }
            }
            if let failure { throw RollbackError(original: original, rollback: failure) }
            throw original
        }
        return VoiceFileUndo(files: written)
    }

    private static func put(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func speakerWrites(_ result: SpeakerResult, lines: [TranscriptLine], meta: [String: Any], folder: URL) throws
        -> [(URL, Data?)]
    {
        var meta = meta
        var labels = meta["speaker_labels"] as? [String: Any] ?? [:]
        labels["names"] = result.voices.compactMap { result.names[$0.id] }
        meta["speaker_labels"] = labels
        let transcript = meta["transcript"] as? [String: Any] ?? [:]
        let rendered = SpeakerLabels.render(
            lines: lines, assigned: result.assigned, names: result.names,
            model: transcript["model"] as? String ?? "Qwen3-ASR", missing: transcript["missing_passages"] as? Int ?? 0)
        return [
            (folder.appendingPathComponent(SpeakerLabels.resultFileName), try JSONEncoder().encode(result)),
            (folder.appendingPathComponent(SpeakerLabels.fileName), Data(rendered.utf8)),
            (MetaFile.url(in: folder), try json(meta)),
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
