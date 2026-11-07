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
public struct Voice: Sendable, Equatable, Identifiable {
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
