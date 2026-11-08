import AVFoundation
import Observation
import TapeUpCore

/// Plays one voice of a recording so the user can tell who it is: its turns
/// from `audio.m4a`, back to back, through the default output. Nothing is
/// recorded and no device is changed; the engine exists only while playing.
@MainActor @Observable
final class VoicePlayer {
    struct Playing: Equatable {
        var stamp: String
        var voice: Int
    }

    private(set) var playing: Playing?
    /// The line being heard, shown as the voice's quote.
    private(set) var line: String?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watch: NSObjectProtocol?
    /// Counts plays, so a late end from an earlier one is ignored.
    @ObservationIgnored private var plays = 0

    func isPlaying(_ voice: Int, in entry: RecordingEntry) -> Bool {
        playing == Playing(stamp: RecordingLibrary.stamp(of: entry.folder), voice: voice)
    }

    /// Plays the voice, or stops it when it is the one playing. Another
    /// voice playing stops first.
    func toggle(_ voice: Int, in entry: RecordingEntry, result: SpeakerResult) {
        let wanted = Playing(stamp: RecordingLibrary.stamp(of: entry.folder), voice: voice)
        let was = playing
        stop()
        guard was != wanted, let file = try? AVAudioFile(forReading: entry.audio),
            let lines = TranscriptDocument.lines(in: entry.folder)
        else { return }
        let turns = SpeakerLabels.turns(of: result, heard: VoicePrints.read(in: entry.folder), lines: lines)
        let playlist = VoicePlaylist(
            turns: turns[voice] ?? [], length: Double(file.length) / file.processingFormat.sampleRate)
        guard let first = playlist.pieces.first else { return }
        let engine = AVAudioEngine()
        let play = plays
        let node = VoiceAudio.queue(playlist.pieces, of: file, on: engine) { [weak self] in
            Task { @MainActor in
                if self?.plays == play { self?.stop() }
            }
        }
        do { try engine.start() } catch { return }
        node.play()
        self.engine = engine
        self.node = node
        playing = wanted
        let assigned = result.assigned
        line = playlist.line(at: first.start, voice: voice, lines: lines, assigned: assigned)?.text
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let played = self.playedSeconds(), let time = playlist.time(at: played) else {
                    return
                }
                let text = playlist.line(at: time, voice: voice, lines: lines, assigned: assigned)?.text
                if text != self.line { self.line = text }
            }
        }
        // Common modes, so the quote follows while the name menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The output changed (headphones in or out): the engine has stopped.
        watch = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        plays += 1
        timer?.invalidate()
        timer = nil
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        if playing != nil { playing = nil }
        if line != nil { line = nil }
    }

    /// Seconds of the voice heard so far, while playing.
    func playedSeconds() -> Double? {
        guard let node, let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else {
            return nil
        }
        return Double(time.sampleTime) / time.sampleRate
    }
}
