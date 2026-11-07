import Foundation

/// A stretch of audio the speaker model gave to one voice.
public struct VoiceTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var voice: Int

    public init(start: Double, end: Double, voice: Int) {
        self.start = start
        self.end = end
        self.voice = voice
    }
}

/// One voice as the card shows it: how long it talked and something it said.
public struct Voice: Sendable, Equatable, Identifiable, Codable {
    /// 1 for the voice that talked most, then in order of talk time.
    public var id: Int
    public var seconds: Double
    public var quote: String
}

/// Puts voices on transcript lines that already exist and writes the
/// labeled transcript beside `transcript.md`, which stays as it is.
public enum SpeakerLabels {
    public static let fileName = "transcript-with-speaker-labels.md"

    /// Each line's voice, numbered by talk time: the voice heard longest
    /// during the line, or nil when no voice overlaps it.
    public static func assign(lines: [TranscriptLine], turns: [VoiceTurn]) -> [Int?] {
        let raw = lines.map { line -> Int? in
            var heard: [Int: Double] = [:]
            for turn in turns {
                let overlap = min(line.end, turn.end) - max(line.start, turn.start)
                if overlap > 0 { heard[turn.voice, default: 0] += overlap }
            }
            return heard.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }
        var talk: [Int: Double] = [:]
        for (line, voice) in zip(lines, raw) {
            if let voice { talk[voice, default: 0] += line.end - line.start }
        }
        let order = talk.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
        let number = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0 + 1) })
        return raw.map { $0.flatMap { number[$0] } }
    }

    /// The voices found, most talk first, each with a line it said.
    public static func voices(lines: [TranscriptLine], assigned: [Int?]) -> [Voice] {
        var voices: [Int: Voice] = [:]
        for (line, voice) in zip(lines, assigned) {
            guard let voice else { continue }
            var entry = voices[voice] ?? Voice(id: voice, seconds: 0, quote: "")
            entry.seconds += line.end - line.start
            if score(line.text) > score(entry.quote) { entry.quote = line.text }
            voices[voice] = entry
        }
        return voices.values.sorted { $0.id < $1.id }
    }

    /// How well a line serves as a quote: long enough to recognize, short
    /// enough to read at a glance.
    private static func score(_ text: String) -> Double {
        let length = Double(text.count)
        return length == 0 ? -.infinity : -abs(length - 60)
    }

    public static func render(
        lines: [TranscriptLine], assigned: [Int?], names: [Int: String], model: String
    ) -> String {
        let long = (lines.last?.end ?? 0) >= 3600
        var text =
            "# Transcript with speaker labels\n\nMade on this Mac by TapeUp with \(model). Times are from the start of audio.m4a.\n"
        for (line, voice) in zip(lines, assigned) {
            let speaker = voice.map { names[$0].map { "\($0): " } ?? "Voice \($0): " } ?? ""
            text += "\n[\(TranscriptDocument.stamp(line.start, long: long))] \(speaker)\(line.text)\n"
        }
        return text
    }
}

/// A recording's speaker labels: what the model found and the names the
/// user gave. Kept hidden beside the labeled transcript so a rename rewrites
/// it without running the model again.
public struct SpeakerResult: Sendable, Equatable, Codable {
    /// Voices asked for with a tapped count, or estimated without one.
    public var count: Int
    public var estimated: Bool
    public var voices: [Voice]
    /// Each transcript line's voice, in line order.
    public var assigned: [Int?]
    public var names: [Int: String] = [:]

    public init(count: Int, estimated: Bool, voices: [Voice], assigned: [Int?]) {
        self.count = count
        self.estimated = estimated
        self.voices = voices
        self.assigned = assigned
    }
}

extension SpeakerLabels {
    static let resultFileName = ".speakers.json"

    public static func result(in folder: URL) -> SpeakerResult? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(resultFileName)) else { return nil }
        return try? JSONDecoder().decode(SpeakerResult.self, from: data)
    }

    /// Writes the labeled transcript and records it in `meta.json`.
    public static func save(_ result: SpeakerResult, lines: [TranscriptLine], in folder: URL) throws {
        let meta = MetaFile.read(folder) ?? [:]
        let model = (meta["transcript"] as? [String: Any])?["model"] as? String ?? "Qwen3-ASR"
        let text = render(lines: lines, assigned: result.assigned, names: result.names, model: model)
        try text.write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(result).write(to: folder.appendingPathComponent(resultFileName), options: .atomic)
        try mark("done", in: folder) { labels in
            labels["file"] = fileName
            labels["voices"] = result.count
            labels["voices_estimated"] = result.estimated
            labels["names"] = result.voices.compactMap { result.names[$0.id] }
        }
    }

    /// Records how far speaker labels have got: `finding`, `done` or `failed`.
    public static func mark(
        _ status: String, error: String? = nil, in folder: URL, _ more: (inout [String: Any]) -> Void = { _ in }
    ) throws {
        guard FileManager.default.fileExists(atPath: MetaFile.url(in: folder).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try MetaFile.update(folder) { meta in
            var labels: [String: Any] = ["status": status]
            if let error { labels["error"] = error }
            more(&labels)
            meta["speaker_labels"] = labels
        }
    }

    /// Gives a voice a name, or takes it away, and rewrites the labeled transcript.
    public static func name(_ voice: Int, _ name: String?, in folder: URL) throws {
        guard var result = result(in: folder), let lines = TranscriptDocument.lines(in: folder) else {
            throw CocoaError(.fileNoSuchFile)
        }
        result.names[voice] = name
        try save(result, lines: lines, in: folder)
    }
}
