import Foundation

/// A stretch of audio the speaker model gave to one voice.
public struct VoiceTurn: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public var voice: Int

    public init(start: Double, end: Double, voice: Int) {
        self.start = start
        self.end = end
        self.voice = voice
    }
}

/// What the speaker model heard: its turns and a voice print for each voice
/// it found. Kept hidden beside the recording, so asking for another number
/// of voices takes a moment and no model.
public struct VoicePrints: Sendable, Equatable, Codable {
    public var turns: [VoiceTurn]
    /// Unit-length prints by voice; a voice with no usable audio has none.
    public var prints: [Int: [Float]]

    public init(turns: [VoiceTurn], prints: [Int: [Float]]) {
        self.turns = turns
        self.prints = prints
    }

    static let fileName = ".voice-prints.json"

    public static func read(in folder: URL) -> VoicePrints? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(VoicePrints.self, from: data)
    }

    public func save(in folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Folds the speaker model's voices into people. The model splits a long
/// talker into several voices, so voices that sound alike, or talk very
/// little, join the voice they sound most like. Rules and numbers were
/// tested on real meetings of one, two and four people.
public enum VoiceFolding {
    /// Prints at least this alike are one person.
    static let sameVoice: Float = 0.6
    /// A voice with less of the talk than this is a stray.
    static let strayShare = 0.03

    /// Each model voice's person. With `count`, the voice with the least talk
    /// joins the one it sounds most like until `count` remain; merging the
    /// two most alike first merged two real people in testing. Without one,
    /// the estimate rules above decide.
    public static func fold(_ heard: VoicePrints, count: Int?) -> [Int: Int] {
        var groups: [Int: (print: [Float]?, talk: Double)] = [:]
        for turn in heard.turns {
            groups[turn.voice, default: (heard.prints[turn.voice], 0)].talk += turn.end - turn.start
        }
        var into: [Int: Int] = [:]
        func merge(_ lost: Int, into keep: Int) {
            let kept = groups[keep]!
            let gone = groups[lost]!
            var print = kept.print ?? gone.print
            if let a = kept.print, let b = gone.print {
                let joined = zip(a, b).map { $0 * Float(kept.talk) + $1 * Float(gone.talk) }
                let length = sqrt(joined.reduce(0) { $0 + $1 * $1 })
                print = length > 0 ? joined.map { $0 / length } : a
            }
            groups[keep] = (print, kept.talk + gone.talk)
            groups[lost] = nil
            into[lost] = keep
        }
        func alike(_ a: Int, _ b: Int) -> Float {
            guard let x = groups[a]!.print, let y = groups[b]!.print else { return -1 }
            return zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
        }
        /// Least talk first; ties by number, so the result never depends on dictionary order.
        func smallestFirst() -> [Int] {
            groups.keys.sorted { (groups[$0]!.talk, $0) < (groups[$1]!.talk, $1) }
        }
        func nearest(to voice: Int) -> Int {
            groups.keys.filter { $0 != voice }.sorted().max { alike(voice, $0) < alike(voice, $1) }!
        }
        func join(_ voice: Int, _ other: Int) {
            if (groups[other]!.talk, -other) >= (groups[voice]!.talk, -voice) {
                merge(voice, into: other)
            } else {
                merge(other, into: voice)
            }
        }
        // A voice with no print joins the voice that talked most.
        func partner(of voice: Int) -> Int {
            groups[voice]!.print == nil ? smallestFirst().last { $0 != voice }! : nearest(to: voice)
        }
        if let count {
            while groups.count > max(1, count) {
                let voice = smallestFirst()[0]
                join(voice, partner(of: voice))
            }
        } else {
            let total = groups.values.reduce(0) { $0 + $1.talk }
            var changed = true
            while changed && groups.count > 1 {
                changed = false
                for voice in smallestFirst() {
                    let other = partner(of: voice)
                    let stray = total > 0 && groups[voice]!.talk / total < strayShare
                    if stray || groups[voice]!.print == nil || alike(voice, other) >= sameVoice {
                        join(voice, other)
                        changed = true
                        break
                    }
                }
            }
        }
        var person: [Int: Int] = [:]
        for voice in Set(heard.turns.map(\.voice)) {
            var root = voice
            while let next = into[root] { root = next }
            person[voice] = root
        }
        return person
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
    /// enough to fit the card's one line.
    private static func score(_ text: String) -> Double {
        let length = Double(text.count)
        return length == 0 ? -.infinity : -abs(length - 45)
    }

    /// Labels the lines from what the model heard, folded to `count` voices
    /// or to the estimate.
    public static func label(lines: [TranscriptLine], heard: VoicePrints, count: Int?) -> SpeakerResult {
        let person = VoiceFolding.fold(heard, count: count)
        let turns = heard.turns.map { VoiceTurn(start: $0.start, end: $0.end, voice: person[$0.voice] ?? $0.voice) }
        let assigned = assign(lines: lines, turns: turns)
        let voices = voices(lines: lines, assigned: assigned)
        return SpeakerResult(count: voices.count, estimated: count == nil, voices: voices, assigned: assigned)
    }

    /// Names from earlier labels, moved to whichever new voice holds most of
    /// a named voice's lines, so a recount keeps them on the same person.
    /// A name moves only where it covers most of the new voice's talk.
    public static func carry(
        _ names: [Int: String], from before: [Int?], to after: [Int?], lines: [TranscriptLine]
    ) -> [Int: String] {
        var shared: [Int: [Int: Double]] = [:]
        var talk: [Int: Double] = [:]
        for (line, (old, new)) in zip(lines, zip(before, after)) {
            guard let new else { continue }
            let seconds = line.end - line.start
            talk[new, default: 0] += seconds
            if let old, names[old] != nil { shared[new, default: [:]][old, default: 0] += seconds }
        }
        // At most one named voice holds most of a new voice's talk; each
        // name then goes to the new voice holding most of its lines.
        var best: [Int: (new: Int, seconds: Double)] = [:]
        for (new, olds) in shared.sorted(by: { $0.key < $1.key }) {
            for (old, seconds) in olds where seconds > (talk[new] ?? 0) / 2 {
                if seconds > best[old]?.seconds ?? 0 { best[old] = (new, seconds) }
            }
        }
        var carried: [Int: String] = [:]
        for (old, choice) in best { carried[choice.new] = names[old] }
        return carried
    }

    public static func render(
        lines: [TranscriptLine], assigned: [Int?], names: [Int: String], model: String, missing: Int = 0
    ) -> String {
        let long = (lines.last?.end ?? 0) >= 3600
        var text =
            "# Transcript with speaker labels\n\nMade on this Mac by TapeUp with \(model). Times are from the start of audio.m4a. Voices are told apart by how they sound; lines where two people talk at once are the most often wrong.\n"
        if missing > 0 {
            text +=
                "\(missing) passage\(missing == 1 ? "" : "s") could not be transcribed and \(missing == 1 ? "is" : "are") missing below.\n"
        }
        if lines.isEmpty { text += "\nNo speech was heard.\n" }
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
    /// Voices found: as many as the tapped count, or fewer when fewer were heard.
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
        let transcript = meta["transcript"] as? [String: Any]
        let text = render(
            lines: lines, assigned: result.assigned, names: result.names,
            model: transcript?["model"] as? String ?? "Qwen3-ASR", missing: transcript?["missing_passages"] as? Int ?? 0
        )
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
