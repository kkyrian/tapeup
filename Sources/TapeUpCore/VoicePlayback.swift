import AVFoundation
import Foundation

/// What plays to hear one voice: its turns from `audio.m4a`, back to back,
/// the talk of others between them left out.
public struct VoicePlaylist: Sendable, Equatable {
    /// A stretch of the recording, in seconds from its start.
    public struct Piece: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }

        public var seconds: Double { end - start }
    }

    /// Turns closer than this play as one, so a breath is not cut out.
    static let joined = 0.25
    /// Shorter pieces are left out: too short to tell who it is.
    static let shortest = 0.3

    public let pieces: [Piece]

    /// The voice's turns, cut to the `length` of the audio.
    public init(turns: [VoiceTurn], length: Double) {
        var pieces: [Piece] = []
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            let start = max(0, turn.start)
            let end = min(length, turn.end)
            guard end > start else { continue }
            if let last = pieces.last, start - last.end < Self.joined {
                pieces[pieces.count - 1].end = max(last.end, end)
            } else {
                pieces.append(Piece(start: start, end: end))
            }
        }
        self.pieces = pieces.filter { $0.seconds >= Self.shortest }
    }

    public var seconds: Double { pieces.reduce(0) { $0 + $1.seconds } }

    /// The time in the recording `played` seconds into the playlist, or nil
    /// once it has all played.
    public func time(at played: Double) -> Double? {
        var left = max(0, played)
        for piece in pieces {
            if left < piece.seconds { return piece.start + left }
            left -= piece.seconds
        }
        return nil
    }

    /// The line being heard at `time` in the recording: of the lines in the
    /// piece playing, the last one begun by then, the voice's own first.
    public func line(at time: Double, voice: Int, lines: [TranscriptLine], assigned: [Int?]) -> TranscriptLine? {
        guard let piece = pieces.last(where: { $0.start <= time }) ?? pieces.first else { return nil }
        let heard = lines.indices.filter {
            lines[$0].end > piece.start && lines[$0].start < piece.end && !lines[$0].text.isEmpty
        }
        let own = heard.filter { $0 < assigned.count && assigned[$0] == voice }
        let pool = own.isEmpty ? heard : own
        return (pool.last { lines[$0].start <= time } ?? pool.first).map { lines[$0] }
    }
}

extension SpeakerLabels {
    /// Each numbered voice's turns: the model's turns folded as `result` was
    /// folded, or, when no fold gives its labels, the voice's own lines.
    public static func turns(of result: SpeakerResult, heard: VoicePrints?, lines: [TranscriptLine]) -> [Int:
        [VoiceTurn]]
    {
        if let heard, lines.count == result.assigned.count {
            // A count asks for at most that many voices and may find fewer,
            // so the count tapped may be any from the voices found up.
            let found = max(1, result.count)
            let counts: [Int?] =
                result.estimated ? [nil] : Array(found...max(found, Set(heard.turns.map(\.voice)).count))
            for count in counts {
                let person = VoiceFolding.fold(heard, count: count)
                let folded = heard.turns.map {
                    VoiceTurn(start: $0.start, end: $0.end, voice: person[$0.voice] ?? $0.voice)
                }
                let (raw, number) = numbered(lines: lines, turns: folded)
                guard raw.map({ $0.flatMap { number[$0] } }) == result.assigned else { continue }
                var turns: [Int: [VoiceTurn]] = [:]
                for turn in folded {
                    guard let voice = number[turn.voice] else { continue }
                    turns[voice, default: []].append(VoiceTurn(start: turn.start, end: turn.end, voice: voice))
                }
                return turns
            }
        }
        var turns: [Int: [VoiceTurn]] = [:]
        for (line, voice) in zip(lines, result.assigned) {
            guard let voice else { continue }
            turns[voice, default: []].append(VoiceTurn(start: line.start, end: line.end, voice: voice))
        }
        return turns
    }
}

/// Plays pieces of a recording back to back, mixed to mono: the file keeps
/// the microphone left and the computer right, and a voice from either
/// side is heard in both ears.
public enum VoiceAudio {
    /// Attaches a player to `engine` with `pieces` of `file` queued one after
    /// another. `done` runs on an audio thread once the last has played, or
    /// when the player stops first.
    public static func queue(
        _ pieces: [VoicePlaylist.Piece], of file: AVAudioFile, on engine: AVAudioEngine,
        done: @escaping @Sendable () -> Void
    ) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        let mono = AVAudioMixerNode()
        engine.attach(player)
        engine.attach(mono)
        let format = file.processingFormat
        engine.connect(player, to: mono, format: format)
        engine.connect(
            mono, to: engine.mainMixerNode,
            format: AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1))
        let rate = format.sampleRate
        let ranges = pieces.compactMap { piece -> (AVAudioFramePosition, AVAudioFrameCount)? in
            let start = AVAudioFramePosition((piece.start * rate).rounded())
            let end = min(file.length, AVAudioFramePosition((piece.end * rate).rounded()))
            return end > start ? (start, AVAudioFrameCount(end - start)) : nil
        }
        for (index, (start, count)) in ranges.enumerated() {
            player.scheduleSegment(
                file, startingFrame: start, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack,
                completionHandler: index == ranges.count - 1 ? { _ in done() } : nil)
        }
        return player
    }
}
