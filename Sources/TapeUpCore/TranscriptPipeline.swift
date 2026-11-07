import AVFoundation
import Accelerate
import Foundation

/// Finds speech in 16 kHz mono audio, fed in order. Times are seconds since
/// the detector's first sample.
public protocol VoiceDetector: AnyObject {
    func process(_ samples: [Float]) -> [VoiceEvent]
    /// Ends the stream: reports speech still open.
    func flush() -> [VoiceEvent]
}

public enum VoiceEvent: Sendable, Equatable {
    case started(Double)
    case ended(Double)
}

/// Turns one piece of 16 kHz speech into text.
public protocol SpeechRecognizer: AnyObject {
    func transcribe(_ samples: [Float], hints: String?) throws -> String
}

/// Which channel a line was heard on, when the two can be told apart.
public enum Side: String, Sendable, Equatable, Codable {
    case microphone
    case computer

    /// The panel's own words for the two sources.
    public var label: String { self == .microphone ? "Microphone" : "Computer audio" }
}

public struct TranscriptLine: Sendable, Equatable, Codable {
    /// Seconds from the start of `audio.m4a`.
    public var start: Double
    public var end: Double
    public var side: Side?
    public var text: String

    public init(start: Double, end: Double, side: Side? = nil, text: String) {
        self.start = start
        self.end = end
        self.side = side
        self.text = text
    }
}

/// One stretch of speech, cut at a pause or at the length limit.
struct Piece {
    var start: Double
    var end: Double
    var side: Side?
    var samples: [Float]
}

/// Cuts a stream into pieces of speech: at pauses the detector reports, and
/// at `maxSeconds` while speech runs on. Long pieces read as whole sentences;
/// pieces under a second were the source of most errors in testing.
final class PieceCutter {
    static let rate = 16_000

    let side: Side?
    /// Where this stream starts in the recording, in seconds.
    let offset: Double
    let maxSamples: Int
    private let detector: VoiceDetector
    private var buffer: [Float] = []
    /// Stream position of `buffer[0]`.
    private var bufferStart = 0
    private var received = 0
    private var speechStart: Int?

    init(detector: VoiceDetector, side: Side?, offset: Double, maxSeconds: Double = 20) {
        self.detector = detector
        self.side = side
        self.offset = offset
        maxSamples = Int(maxSeconds * Double(Self.rate))
    }

    /// The length limit is checked this often, whatever size chunks arrive in.
    static let step = rate / 4

    func feed(_ samples: [Float]) -> [Piece] {
        guard samples.count > Self.step else { return feedStep(samples) }
        return stride(from: 0, to: samples.count, by: Self.step).flatMap { start in
            feedStep(Array(samples[start..<min(samples.count, start + Self.step)]))
        }
    }

    private func feedStep(_ samples: [Float]) -> [Piece] {
        guard !samples.isEmpty else { return [] }
        buffer.append(contentsOf: samples)
        received += samples.count
        var pieces = handle(detector.process(samples))
        if let start = speechStart, received - start >= maxSamples {
            pieces += cut(from: start, to: received)
            speechStart = received
        }
        trim()
        return pieces
    }

    func finish() -> [Piece] {
        var pieces = handle(detector.flush())
        if let start = speechStart { pieces += cut(from: start, to: received) }
        speechStart = nil
        return pieces
    }

    private func handle(_ events: [VoiceEvent]) -> [Piece] {
        var pieces: [Piece] = []
        for event in events {
            switch event {
            case .started(let time):
                if speechStart == nil { speechStart = max(bufferStart, Int(time * Double(Self.rate))) }
            case .ended(let time):
                // After a cut at the length limit the detector still reports
                // the original start; the piece begins where the cut was.
                guard let start = speechStart else { continue }
                pieces += cut(from: start, to: min(received, Int(time * Double(Self.rate))))
                speechStart = nil
            }
        }
        return pieces
    }

    /// Speech that ends just after a cut at the length limit leaves a
    /// sliver, a few samples long at times, which crashes the model.
    static let minSamples = rate * 3 / 10

    private func cut(from start: Int, to end: Int) -> [Piece] {
        let from = max(start, bufferStart)
        guard end - from >= Self.minSamples else { return [] }
        let samples = Array(buffer[(from - bufferStart)..<(end - bufferStart)])
        let seconds = { (sample: Int) in self.offset + Double(sample) / Double(Self.rate) }
        return [Piece(start: seconds(from), end: seconds(end), side: side, samples: samples)]
    }

    /// Keeps two seconds before the current speech, since the detector
    /// confirms a start a little after it happens.
    private func trim() {
        let keepFrom = max(bufferStart, (speechStart ?? received) - 2 * Self.rate)
        guard keepFrom - bufferStart > Self.rate * 4 else { return }
        buffer.removeFirst(keepFrom - bufferStart)
        bufferStart = keepFrom
    }
}

/// Lowers 48 kHz audio to 16 kHz with a low-pass filter, keeping state
/// between calls so a stream fed in chunks matches one fed at once.
final class Decimator {
    let factor: Int
    private let taps: [Float]
    private var history: [Float]

    init(factor: Int = 3) {
        self.factor = factor
        // Windowed sinc at 7 kHz: below the new Nyquist, above speech's useful band.
        let count = 48
        let cutoff = 7_000.0 / Double(16_000 * factor)
        taps = (0..<count).map { i in
            let x = Double(i) - Double(count - 1) / 2
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(count - 1))
            return Float(sinc * window)
        }
        history = [Float](repeating: 0, count: count - 1)
    }

    func process(_ samples: [Float]) -> [Float] {
        let input = history + samples
        let outputs = (input.count - taps.count) / factor + 1
        guard outputs > 0, input.count >= taps.count else {
            history = input
            return []
        }
        var result = [Float](repeating: 0, count: outputs)
        vDSP_desamp(input, vDSP_Stride(factor), taps, &result, vDSP_Length(outputs), vDSP_Length(taps.count))
        history = Array(input[(outputs * factor)...])
        return result
    }
}

/// Everything between the recorder's audio and the transcript's lines: picks
/// what to listen to, cuts pieces, transcribes and cleans them. Not thread
/// safe; its owner feeds it from one queue, the same one the models run on.
///
/// With headphones and both sources on, the two channels are transcribed
/// apart, so each line is known to come from the microphone or the computer.
/// With speakers the microphone also hears the call, so the channels are
/// mixed and lines carry no side.
public final class TranscriptPipeline {
    public static let fileRate = 48_000

    private let makeDetector: () -> VoiceDetector
    private let recognizer: SpeechRecognizer
    private let hints: String?
    private let hintWords: Set<String>
    private let microphone: Bool
    private let computer: Bool
    private var split: Bool?
    private var cutters: [(cutter: PieceCutter, decimator: Decimator, channel: Side?)] = []
    /// Frames fed so far, at the file's rate.
    private var frames = 0

    public private(set) var lines: [TranscriptLine] = []
    public private(set) var failures = 0
    public private(set) var pieces = 0

    public init(
        makeDetector: @escaping () -> VoiceDetector, recognizer: SpeechRecognizer, hints: String?,
        microphone: Bool, computer: Bool
    ) {
        self.makeDetector = makeDetector
        self.recognizer = recognizer
        self.hints = hints
        hintWords = Set(hints.map(TextGuard.words) ?? [])
        self.microphone = microphone
        self.computer = computer
    }

    /// Frames as written to the file, left (microphone) and right (computer
    /// audio), at 48 kHz. `headphones` says whether the computer audio was
    /// playing into headphones for these frames.
    public func feed(left: [Float], right: [Float], headphones: Bool) {
        let count = min(left.count, right.count)
        guard count > 0 else { return }
        let wantSplit = microphone && computer && headphones
        if split != wantSplit {
            finishCutters()
            split = wantSplit
            let offset = Double(frames) / Double(Self.fileRate)
            if wantSplit {
                cutters = [Side.microphone, .computer].map {
                    (PieceCutter(detector: makeDetector(), side: $0, offset: offset), Decimator(), $0)
                }
            } else {
                cutters = [(PieceCutter(detector: makeDetector(), side: nil, offset: offset), Decimator(), nil)]
            }
        }
        frames += count
        for entry in cutters {
            let source: [Float]
            switch entry.channel {
            case .microphone: source = Array(left.prefix(count))
            case .computer: source = Array(right.prefix(count))
            case nil: source = mix(left, right, count)
            }
            recognize(entry.cutter.feed(entry.decimator.process(source)))
        }
    }

    /// Transcribes what is left and returns every line, in time order.
    public func finish() -> [TranscriptLine] {
        finishCutters()
        return lines
    }

    private func finishCutters() {
        for entry in cutters { recognize(entry.cutter.finish()) }
        cutters = []
        lines.sort { $0.start < $1.start }
    }

    private func mix(_ left: [Float], _ right: [Float], _ count: Int) -> [Float] {
        if microphone && !computer { return Array(left.prefix(count)) }
        if computer && !microphone { return Array(right.prefix(count)) }
        var mixed = [Float](repeating: 0, count: count)
        vDSP_vasm(left, 1, right, 1, [0.5], &mixed, 1, vDSP_Length(count))
        return mixed
    }

    private func recognize(_ found: [Piece]) {
        for piece in found {
            pieces += 1
            do {
                let text = try recognizer.transcribe(piece.samples, hints: hints)
                guard let clean = TextGuard.clean(text, hintWords: hintWords) else { continue }
                lines.append(TranscriptLine(start: piece.start, end: piece.end, side: piece.side, text: clean))
            } catch {
                failures += 1
            }
        }
    }
}

/// Removes what the model makes up rather than hears.
public enum TextGuard {
    /// Nil when nothing real is left: an empty piece, or one that only
    /// repeats the name hints back.
    public static func clean(_ text: String, hintWords: Set<String>) -> String? {
        // Checked before collapsing, so a loop of one name is caught too.
        let found = words(text)
        if found.count >= 3, found.allSatisfy(hintWords.contains) { return nil }
        let result = collapseLoops(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// A stretch of text repeated five or more times in a row is kept once.
    static func collapseLoops(_ text: String) -> String {
        text.replacing(/(.{2,120}?)\1{4,}/.dotMatchesNewlines()) { match in String(match.output.1) }
    }

    /// Lowercased words, splitting on anything but letters and digits.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// The names and terms given to the model, so it spells them as the user does.
public enum NameHints {
    /// A plain comma-separated list: in testing a sentence ("People: …") was
    /// copied into the transcript, a list was not.
    public static func make(names: [String], titles: [String], limit: Int = 40) -> String? {
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard trimmed.count >= 2, terms.count < limit, seen.insert(trimmed.lowercased()).inserted else { return }
            terms.append(trimmed)
        }
        names.forEach(add)
        for title in titles {
            for (index, word) in title.split(separator: " ").enumerated() where distinctive(word, first: index == 0) {
                add(String(word))
            }
        }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// Words worth spelling for the model: acronyms (IRB), inner capitals
    /// (NorthStar), and capitalized words not at a title's start.
    static func distinctive(_ word: Substring, first: Bool) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, letters.allSatisfy({ $0.isASCII }) else { return false }
        if letters.allSatisfy(\.isUppercase) { return true }
        if letters.dropFirst().contains(where: \.isUppercase) { return true }
        return !first && letters.first?.isUppercase == true
    }
}

/// `transcript.md`: one paragraph per piece, its time first.
public enum TranscriptDocument {
    public static let fileName = "transcript.md"
    /// The lines with their times, kept for speaker labels; hidden, since
    /// `transcript.md` is the file for people and agents.
    public static let linesFileName = ".transcript-lines.json"

    public static func lines(in folder: URL) -> [TranscriptLine]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(linesFileName)) else { return nil }
        return try? JSONDecoder().decode([TranscriptLine].self, from: data)
    }

    public static func render(lines: [TranscriptLine], labeled: Bool, model: String, missing: Int = 0) -> String {
        let long = (lines.last?.end ?? 0) >= 3600
        var text = "# Transcript\n\nMade on this Mac by TapeUp with \(model). Times are from the start of audio.m4a.\n"
        if missing > 0 {
            text +=
                "\(missing) passage\(missing == 1 ? "" : "s") could not be transcribed and \(missing == 1 ? "is" : "are") missing below.\n"
        }
        if labeled {
            text +=
                "Lines are labeled by side: Microphone is what this Mac's microphone heard, Computer audio is what the Mac played. Either side can be more than one person.\n"
        }
        for line in lines {
            let side = labeled ? line.side.map { "\($0.label): " } ?? "" : ""
            text += "\n[\(stamp(line.start, long: long))] \(side)\(line.text)\n"
        }
        if lines.isEmpty { text += "\nNo speech was heard.\n" }
        return text
    }

    static func stamp(_ seconds: Double, long: Bool) -> String {
        let total = Int(seconds)
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return long ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", total / 60, s)
    }
}

extension TranscriptDocument {
    /// Whether a recording's lines can carry sides: both sources recorded,
    /// and headphones the whole time (`output_headphones` in `meta.json`).
    public static func sidesKnown(meta: [String: Any]) -> Bool {
        let sources = meta["sources"] as? [String] ?? []
        return sources.contains("microphone") && sources.contains("computer audio")
            && meta["output_headphones"] as? Bool == true
    }

    /// Writes `transcript.md` and records it in `meta.json`. A transcript
    /// where every piece failed is not written; that is a failure.
    public static func save(
        lines: [TranscriptLine], failures: Int, pieces: Int, model: SpeechModel, in folder: URL
    ) throws {
        if pieces > 0, failures == pieces {
            try RecordingLibrary.markTranscript(
                "failed", model: model.name, error: "the model failed on every piece", in: folder)
            return
        }
        let labeled = sidesKnown(meta: MetaFile.read(folder) ?? [:])
        let text = render(lines: lines, labeled: labeled, model: model.name, missing: failures)
        try text.write(to: folder.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(linesFileName), options: .atomic)
        try RecordingLibrary.markTranscript(
            "done", model: model.name, sideLabels: labeled, missing: failures, in: folder)
    }
}

/// A saved recording as 16 kHz mono, both sides mixed, for the speaker model.
public enum SpeechAudio {
    public static func mono(file: URL, microphone: Bool, computer: Bool) throws -> [Float] {
        let source = try AVAudioFile(forReading: file)
        guard Int(source.processingFormat.sampleRate) == TranscriptPipeline.fileRate,
            source.processingFormat.channelCount == 2,
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 48_000 * 30)
        else { throw CocoaError(.fileReadCorruptFile) }
        let decimator = Decimator()
        var samples: [Float] = []
        samples.reserveCapacity(Int(source.length / 3) + 1)
        while source.framePosition < source.length {
            try source.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            let left = UnsafeBufferPointer(start: data[0], count: count)
            let right = UnsafeBufferPointer(start: data[1], count: count)
            var mixed = [Float](repeating: 0, count: count)
            if microphone && !computer {
                mixed = Array(left)
            } else if computer && !microphone {
                mixed = Array(right)
            } else {
                vDSP_vasm(left.baseAddress!, 1, right.baseAddress!, 1, [0.5], &mixed, 1, vDSP_Length(count))
            }
            samples += decimator.process(mixed)
        }
        return samples
    }
}
