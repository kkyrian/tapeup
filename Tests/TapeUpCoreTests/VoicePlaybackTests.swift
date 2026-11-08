import AVFoundation
import Testing

@testable import TapeUpCore

struct VoicePlaybackTests {
    private func turn(_ start: Double, _ end: Double, _ voice: Int = 1) -> VoiceTurn {
        VoiceTurn(start: start, end: end, voice: voice)
    }

    private func pieces(_ playlist: VoicePlaylist) -> [[Double]] {
        playlist.pieces.map { [$0.start, $0.end] }
    }

    @Test func turnsPlayInOrderWithShortGapsJoined() {
        let playlist = VoicePlaylist(
            turns: [turn(10, 12), turn(2, 4), turn(4.1, 5), turn(5.5, 6)], length: 60)
        #expect(pieces(playlist) == [[2, 5], [5.5, 6], [10, 12]])
        #expect(playlist.seconds == 5.5)
    }

    @Test func turnsTooShortToTellAreLeftOut() {
        let playlist = VoicePlaylist(turns: [turn(1, 1.2), turn(3, 3.15), turn(3.3, 3.5), turn(8, 8.29)], length: 60)
        // The two short turns 0.15 s apart join into one long enough to hear.
        #expect(pieces(playlist) == [[3, 3.5]])
    }

    @Test func overlappingTurnsPlayOnce() {
        let playlist = VoicePlaylist(turns: [turn(1, 5), turn(2, 3), turn(4, 7)], length: 60)
        #expect(pieces(playlist) == [[1, 7]])
    }

    @Test func turnsAreCutToTheAudio() {
        let playlist = VoicePlaylist(turns: [turn(-1, 2), turn(8, 12), turn(15, 20)], length: 10)
        #expect(pieces(playlist) == [[0, 2], [8, 10]])
        #expect(VoicePlaylist(turns: [], length: 10).pieces.isEmpty)
        #expect(VoicePlaylist(turns: [turn(1, 2)], length: 0).pieces.isEmpty)
    }

    @Test func playedTimeMapsAcrossTheCutGaps() {
        let playlist = VoicePlaylist(turns: [turn(10, 12), turn(30, 35)], length: 60)
        #expect(playlist.time(at: 0) == 10)
        #expect(playlist.time(at: 1.5) == 11.5)
        #expect(playlist.time(at: 2) == 30)
        #expect(playlist.time(at: 6.5) == 34.5)
        #expect(playlist.time(at: 7) == nil)
        #expect(playlist.time(at: -1) == 10)
    }

    @Test func theQuoteFollowsTheLineBeingHeard() {
        let lines = [
            TranscriptLine(start: 0, end: 4, text: "Thanks for making time."),
            TranscriptLine(start: 4, end: 5, text: "Sure."),
            TranscriptLine(start: 5, end: 9, text: "We ran forty sessions."),
            TranscriptLine(start: 20, end: 24, text: "About a third."),
            TranscriptLine(start: 24, end: 26, text: ""),
        ]
        let assigned: [Int?] = [1, 2, 1, 1, 1]
        // One turn holds the first three lines, the other voice's "Sure." between.
        let playlist = VoicePlaylist(turns: [turn(0, 9), turn(20, 26)], length: 60)
        func quote(_ time: Double) -> String? {
            playlist.line(at: time, voice: 1, lines: lines, assigned: assigned)?.text
        }
        #expect(quote(0) == "Thanks for making time.")
        #expect(quote(4.5) == "Thanks for making time.")
        #expect(quote(6) == "We ran forty sessions.")
        #expect(quote(21) == "About a third.")
        // An empty line keeps the last words heard.
        #expect(quote(25) == "About a third.")
        // Only another voice's line in the turn: it is still what is heard.
        #expect(playlist.line(at: 4.5, voice: 3, lines: lines, assigned: assigned)?.text == "Sure.")
        #expect(VoicePlaylist(turns: [], length: 60).line(at: 1, voice: 1, lines: lines, assigned: assigned) == nil)
    }

    /// Twelve lines, five model voices: 3 sounds like 0, 0 also talks where
    /// no line was transcribed, and 4 talks only there.
    private func heard() -> (lines: [TranscriptLine], heard: VoicePrints) {
        let voices = [0, 1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 0]
        var lines: [TranscriptLine] = []
        var turns: [VoiceTurn] = []
        for (index, voice) in voices.enumerated() {
            let start = Double(index) * 10
            lines.append(TranscriptLine(start: start, end: start + 8, text: "Line \(index)"))
            turns.append(turn(start, start + 8, voice))
        }
        turns.append(turn(200, 260, 4))
        turns.append(turn(300, 310, 0))
        let prints: [Int: [Float]] = [
            0: [1, 0, 0, 0, 0], 1: [0, 1, 0, 0, 0], 2: [0, 0, 1, 0, 0], 3: [0.8, 0, 0, 0.6, 0], 4: [0, 0, 0, 0, 1],
        ]
        return (lines, VoicePrints(turns: turns, prints: prints))
    }

    @Test(arguments: [nil, 1, 2, 3, 4, 5] as [Int?])
    func eachVoicePlaysTheTurnsItsLinesCameFrom(count: Int?) {
        let (lines, heard) = heard()
        let result = SpeakerLabels.label(lines: lines, heard: heard, count: count)
        let turns = SpeakerLabels.turns(of: result, heard: heard, lines: lines)
        #expect(Set(turns.keys) == Set(result.voices.map(\.id)))
        // Every line's voice is the one whose turns cover it.
        for (line, voice) in zip(lines, result.assigned) {
            let owner = turns.first { $0.value.contains { $0.start <= line.start && $0.end >= line.end } }?.key
            #expect(owner == voice, "count \(String(describing: count)), \(line.text)")
        }
        // The model's own turns, not the lines: talk with no line plays too.
        #expect(turns[result.assigned[0] ?? 0]?.contains { $0.start == 300 } == true)
    }

    @Test func aCountAboveTheVoicesFoundKeepsTheirTurns() {
        let (lines, heard) = heard()
        // Five voices asked for, four heard on lines: folding to four would
        // join two of them, so the fold of five is found, and the fifth's
        // turn is not played as anyone's.
        let result = SpeakerLabels.label(lines: lines, heard: heard, count: 5)
        #expect(result.count == 4)
        #expect(SpeakerLabels.label(lines: lines, heard: heard, count: 4).assigned != result.assigned)
        let turns = SpeakerLabels.turns(of: result, heard: heard, lines: lines)
        #expect(!turns.values.joined().contains { $0.start == 200 })
        #expect(turns[result.assigned[0] ?? 0]?.contains { $0.start == 300 } == true)
    }

    @Test func withoutWhatTheModelHeardEachVoicePlaysItsLines() {
        let (lines, heard) = heard()
        var result = SpeakerLabels.label(lines: lines, heard: heard, count: 2)
        let fromLines = SpeakerLabels.turns(of: result, heard: nil, lines: lines)
        #expect(fromLines[1]?.count == result.assigned.filter { $0 == 1 }.count)
        #expect(fromLines[1]?.first == VoiceTurn(start: 0, end: 8, voice: 1))
        // Labels no fold gives, as from a hand-edited file, fall back the same way.
        result.assigned = result.assigned.map { $0 == 1 ? 2 : 1 }
        #expect(SpeakerLabels.turns(of: result, heard: heard, lines: lines)[2]?.first?.end == 8)
    }

    @Test func queuedPiecesPlayBackToBackInBothEars() throws {
        let rate = 8000.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-voice-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // One second: the microphone (left) at 0.4 from 0.2 s to 0.4 s, the
        // computer (right) at 0.2 from 0.6 s to 0.7 s, silence elsewhere.
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            let left = try #require(buffer.floatChannelData?[0])
            let right = try #require(buffer.floatChannelData?[1])
            for frame in 0..<8000 {
                left[frame] = (1600..<3200).contains(frame) ? 0.4 : 0
                right[frame] = (4800..<5600).contains(frame) ? 0.2 : 0
            }
            try file.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = VoiceAudio.queue(
            [.init(start: 0.2, end: 0.4), .init(start: 0.6, end: 0.7)], of: file, on: engine, done: {})
        try engine.start()
        player.play()
        let out = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        #expect(try engine.renderOffline(4096, to: out) == .success)
        engine.stop()
        let outLeft = try #require(out.floatChannelData?[0])
        let outRight = try #require(out.floatChannelData?[1])
        let first = outLeft[0]
        #expect(first > 0.05)
        for frame in 0..<Int(out.frameLength) {
            let expected: Float = frame < 1600 ? first : frame < 2400 ? first / 2 : 0
            #expect(abs(outLeft[frame] - expected) < 1e-4, "left at \(frame): \(outLeft[frame])")
            #expect(abs(outRight[frame] - outLeft[frame]) < 1e-4, "both ears at \(frame)")
            if abs(outLeft[frame] - expected) >= 1e-4 || abs(outRight[frame] - outLeft[frame]) >= 1e-4 { break }
        }
    }
}
