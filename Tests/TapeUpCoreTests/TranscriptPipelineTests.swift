import Foundation
import Testing

@testable import TapeUpCore

/// Speech wherever the samples are loud: a stand-in for Silero that reports
/// a start at the first loud chunk and an end after `pause` quiet seconds.
private final class LoudnessDetector: VoiceDetector {
    let pause: Double
    private var position = 0
    private var speaking = false
    private var quietSince: Int?

    init(pause: Double = 0.8) { self.pause = pause }

    func process(_ samples: [Float]) -> [VoiceEvent] {
        var events: [VoiceEvent] = []
        for chunkStart in stride(from: 0, to: samples.count, by: 160) {
            let chunk = samples[chunkStart..<min(samples.count, chunkStart + 160)]
            let loud = (chunk.map(abs).max() ?? 0) > 0.1
            let time = Double(position) / 16_000
            if loud {
                quietSince = nil
                if !speaking {
                    speaking = true
                    events.append(.started(time))
                }
            } else if speaking {
                let since = quietSince ?? position
                quietSince = since
                if Double(position - since) / 16_000 >= pause {
                    speaking = false
                    quietSince = nil
                    events.append(.ended(Double(since) / 16_000))
                }
            }
            position += chunk.count
        }
        return events
    }

    func flush() -> [VoiceEvent] {
        guard speaking else { return [] }
        speaking = false
        return [.ended(Double(quietSince ?? position) / 16_000)]
    }
}

/// Answers with the piece's length, or a fixed reply.
private final class EchoRecognizer: SpeechRecognizer {
    var reply: (([Float]) -> String)?
    private(set) var hintsSeen: [String?] = []

    func transcribe(_ samples: [Float], hints: String?) throws -> String {
        hintsSeen.append(hints)
        return reply?(samples) ?? String(format: "%.1f s", Double(samples.count) / 16_000)
    }
}

private func tone(_ seconds: Double, rate: Int = 16_000) -> [Float] {
    (0..<Int(seconds * Double(rate))).map { sin(Float($0) * 0.05) * 0.5 }
}

private func silence(_ seconds: Double, rate: Int = 16_000) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * Double(rate)))
}

struct PieceCutterTests {
    @Test func cutsAtPausesWithTimesFromTheRecording() {
        let cutter = PieceCutter(detector: LoudnessDetector(), side: .microphone, offset: 10)
        var pieces = cutter.feed(silence(1) + tone(3) + silence(2) + tone(2))
        pieces += cutter.finish()
        #expect(pieces.count == 2)
        #expect(abs(pieces[0].start - 11) < 0.02)
        #expect(abs(pieces[0].end - 14) < 0.02)
        #expect(abs(pieces[1].start - 16) < 0.02)
        #expect(pieces.allSatisfy { $0.side == .microphone })
    }

    @Test func longSpeechIsCutAtTheLimitAndContinues() {
        let cutter = PieceCutter(detector: LoudnessDetector(), side: nil, offset: 0, maxSeconds: 20)
        var pieces: [Piece] = []
        // Fed in quarter seconds, as the recorder delivers it.
        let audio = tone(45) + silence(1)
        for start in stride(from: 0, to: audio.count, by: 4_000) {
            pieces += cutter.feed(Array(audio[start..<min(audio.count, start + 4_000)]))
        }
        pieces += cutter.finish()
        #expect(pieces.count == 3)
        #expect(pieces.map { ($0.end - $0.start).rounded() } == [20, 20, 5])
        // Each piece starts where the previous one stopped: no audio twice, none lost.
        #expect(abs(pieces[1].start - pieces[0].end) < 0.001)
        #expect(abs(pieces[2].start - pieces[1].end) < 0.001)
    }

    @Test func chunkSizeNeverChangesThePieces() {
        let audio = silence(1) + tone(45) + silence(2) + tone(3) + silence(1)
        func pieces(chunk: Int) -> [Double] {
            let cutter = PieceCutter(detector: LoudnessDetector(), side: nil, offset: 0)
            var found: [Piece] = []
            for start in stride(from: 0, to: audio.count, by: chunk) {
                found += cutter.feed(Array(audio[start..<min(audio.count, start + chunk)]))
            }
            return (found + cutter.finish()).map { ($0.start * 100).rounded() / 100 }
        }
        let live = pieces(chunk: 4_000)
        #expect(live.count == 4)
        #expect(pieces(chunk: 16_000 * 30) == live)
        #expect(pieces(chunk: audio.count) == live)
    }

    @Test func memoryStaysBoundedOverAnHourOfSilence() {
        let cutter = PieceCutter(detector: LoudnessDetector(), side: nil, offset: 0)
        let quiet = silence(10)
        for _ in 0..<360 { _ = cutter.feed(quiet) }
        let pieces = cutter.feed(tone(2) + silence(1)) + cutter.finish()
        #expect(pieces.count == 1)
        #expect(abs(pieces[0].start - 3600) < 0.02)
    }
}

struct DecimatorTests {
    @Test func keepsSpeechAndRemovesWhatCannotBeKept() {
        func level(_ frequency: Float) -> Float {
            let decimator = Decimator()
            let input = (0..<48_000).map { sin(2 * .pi * frequency * Float($0) / 48_000) }
            // In uneven chunks, as the recorder delivers it.
            var output: [Float] = []
            var start = 0
            for size in [1_000, 7, 12_001, 30_000] where start < input.count {
                output += decimator.process(Array(input[start..<min(input.count, start + size)]))
                start += size
            }
            output += decimator.process(Array(input[min(start, input.count)...]))
            #expect(abs(output.count - 16_000) <= 16)
            return output.dropFirst(100).map(abs).max() ?? 0
        }
        #expect(level(1_000) > 0.9)
        #expect(level(12_000) < 0.05)
    }
}

struct TranscriptPipelineTests {
    private func pipeline(_ recognizer: EchoRecognizer, microphone: Bool = true, computer: Bool = true)
        -> TranscriptPipeline
    {
        TranscriptPipeline(
            makeDetector: { LoudnessDetector() }, recognizer: recognizer, hints: "Priya, Mei Lin",
            microphone: microphone, computer: computer)
    }

    @Test func headphonesTranscribeEachSideApart() {
        let recognizer = EchoRecognizer()
        let pipeline = pipeline(recognizer)
        // The microphone talks first, then the call answers.
        let left = tone(3, rate: 48_000) + silence(4, rate: 48_000)
        let right = silence(4, rate: 48_000) + tone(2, rate: 48_000) + silence(1, rate: 48_000)
        pipeline.feed(left: left, right: right, headphones: true)
        let lines = pipeline.finish()
        #expect(lines.map(\.side) == [.microphone, .computer])
        #expect(abs(lines[1].start - 4) < 0.05)
    }

    @Test func speakersMixBothSidesWithoutLabels() {
        let recognizer = EchoRecognizer()
        let pipeline = pipeline(recognizer)
        let left = tone(3, rate: 48_000) + silence(4, rate: 48_000)
        let right = silence(4, rate: 48_000) + tone(2, rate: 48_000) + silence(1, rate: 48_000)
        pipeline.feed(left: left, right: right, headphones: false)
        let lines = pipeline.finish()
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.side == nil })
    }

    @Test func switchingToSpeakersMidwayKeepsEveryLineInOrder() {
        let recognizer = EchoRecognizer()
        let pipeline = pipeline(recognizer)
        let speech = tone(2, rate: 48_000) + silence(2, rate: 48_000)
        pipeline.feed(left: speech, right: silence(4, rate: 48_000), headphones: true)
        pipeline.feed(left: speech, right: silence(4, rate: 48_000), headphones: false)
        let lines = pipeline.finish()
        #expect(lines.map(\.side) == [.microphone, nil])
        #expect(abs(lines[1].start - 4) < 0.05)
    }

    @Test func oneSourceListensOnlyToItsChannel() {
        let recognizer = EchoRecognizer()
        let pipeline = pipeline(recognizer, microphone: false)
        // The silent microphone channel must not halve the computer audio.
        pipeline.feed(
            left: silence(3, rate: 48_000), right: tone(2, rate: 48_000) + silence(1, rate: 48_000), headphones: true)
        let lines = pipeline.finish()
        #expect(lines.count == 1)
        #expect(lines[0].side == nil)
    }

    @Test func hintEchoesAndEmptyPiecesAreDropped() {
        let recognizer = EchoRecognizer()
        var replies = ["Priya, Mei Lin.", "  ", "Mei said hello."]
        recognizer.reply = { _ in replies.removeFirst() }
        let pipeline = pipeline(recognizer, computer: false)
        let speech = tone(1, rate: 48_000) + silence(2, rate: 48_000)
        pipeline.feed(left: speech + speech + speech, right: silence(9, rate: 48_000), headphones: false)
        let lines = pipeline.finish()
        #expect(lines.map(\.text) == ["Mei said hello."])
        #expect(recognizer.hintsSeen.allSatisfy { $0 == "Priya, Mei Lin" })
    }

    @Test func aFailingModelIsCounted() {
        final class Broken: SpeechRecognizer {
            func transcribe(_ samples: [Float], hints: String?) throws -> String {
                throw CocoaError(.featureUnsupported)
            }
        }
        let pipeline = TranscriptPipeline(
            makeDetector: { LoudnessDetector() }, recognizer: Broken(), hints: nil, microphone: true, computer: false)
        pipeline.feed(
            left: tone(1, rate: 48_000) + silence(2, rate: 48_000), right: silence(3, rate: 48_000), headphones: false)
        _ = pipeline.finish()
        #expect(pipeline.failures == 1)
        #expect(pipeline.pieces == 1)
    }
}

struct TextGuardTests {
    private let hints: Set<String> = ["priya", "ana", "josé", "ortiz", "lsat"]

    @Test func repeatedHintListIsDropped() {
        #expect(TextGuard.clean("Priya, Ana, José Ortiz, LSAT.", hintWords: hints) == nil)
        #expect(TextGuard.clean("PRIYA, PRIYA, PRIYA, PRIYA, PRIYA, PRIYA", hintWords: hints) == nil)
    }

    @Test func realSpeechWithNamesStays() {
        #expect(TextGuard.clean("José Ortiz", hintWords: hints) == "José Ortiz")
        #expect(TextGuard.clean("Priya, can you send it to José?", hintWords: hints) != nil)
    }

    @Test func loopsCollapseAndFillersStay() {
        #expect(
            TextGuard.clean("I think, I think, I think, I think, I think, I think so", hintWords: [])
                == "I think, I think so")
        #expect(TextGuard.clean("对对对对对对，所以", hintWords: []) == "对对对对对对，所以")
        #expect(
            TextGuard.clean("ten minute, ten minute, ten minute.", hintWords: [])
                == "ten minute, ten minute, ten minute.")
    }
}

struct NameHintsTests {
    @Test func namesFirstThenDistinctiveTitleWords() {
        let hints = NameHints.make(
            names: ["Priya", "Mei Lin", "priya"], titles: ["Lab sync", "LSAT call with NorthStar", "Weekly Tidepool"])
        #expect(hints == "Priya, Mei Lin, LSAT, NorthStar, Tidepool")
    }

    @Test func nothingKnownGivesNoHints() {
        #expect(NameHints.make(names: [], titles: ["Lab sync"]) == nil)
    }
}

struct TranscriptDocumentTests {
    @Test func labeledLinesNameTheirSide() {
        let text = TranscriptDocument.render(
            lines: [
                .init(start: 3.4, end: 5, side: .microphone, text: "Hello."),
                .init(start: 65, end: 70, side: .computer, text: "Hi there."),
            ], labeled: true, model: "Qwen3-ASR 1.7B")
        #expect(text.contains("[00:03] Microphone: Hello."))
        #expect(text.contains("[01:05] Computer audio: Hi there."))
        #expect(text.contains("Either side can be more than one person"))
    }

    @Test func unlabeledAndLongRecordingsUseHours() {
        let text = TranscriptDocument.render(
            lines: [.init(start: 3725, end: 3730, side: .microphone, text: "Late.")], labeled: false,
            model: "Qwen3-ASR 0.6B")
        #expect(text.contains("[1:02:05] Late."))
        #expect(!text.contains("Microphone"))
    }

    @Test func sidesNeedBothSourcesAndHeadphonesThroughout() {
        let both = ["microphone", "computer audio"]
        #expect(TranscriptDocument.sidesKnown(meta: ["sources": both, "output_headphones": true]))
        #expect(!TranscriptDocument.sidesKnown(meta: ["sources": both, "output_headphones": false]))
        #expect(!TranscriptDocument.sidesKnown(meta: ["sources": both]))
        #expect(!TranscriptDocument.sidesKnown(meta: ["sources": ["microphone"], "output_headphones": true]))
    }

    @Test func missingPassagesAreSaidInFileAndMeta() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try MetaFile.update(folder) { $0["status"] = "recorded" }
        try TranscriptDocument.save(
            lines: [.init(start: 1, end: 2, side: nil, text: "Hello.")], failures: 2, pieces: 5, model: .large,
            in: folder)
        let text = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(text.contains("2 passages could not be transcribed"))
        let meta = try #require(MetaFile.read(folder))
        #expect((meta["transcript"] as? [String: Any])?["missing_passages"] as? Int == 2)
        #expect(meta["status"] as? String == "transcribed")
    }

    @Test func aRecordingThatFailedToEncodeKeepsItsStatus() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try MetaFile.update(folder) { $0["status"] = "recording" }
        try TranscriptDocument.save(lines: [], failures: 0, pieces: 0, model: .small, in: folder)
        let meta = try #require(MetaFile.read(folder))
        #expect(meta["status"] as? String == "recording")
        #expect((meta["transcript"] as? [String: Any])?["missing_passages"] == nil)
    }
}

struct SpeechModelTests {
    @Test func memoryAndPowerChooseTheModel() {
        let gb: UInt64 = 1 << 30
        #expect(SpeechModel.choose(memoryBytes: 8 * gb, onBattery: false) == .small)
        #expect(SpeechModel.choose(memoryBytes: 16 * gb, onBattery: false) == .large)
        #expect(SpeechModel.choose(memoryBytes: 16 * gb, onBattery: true) == .small)
        #expect(SpeechModel.choose(memoryBytes: 48 * gb, onBattery: false) == .large)
    }
}
