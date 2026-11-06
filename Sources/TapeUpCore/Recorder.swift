import AVFoundation
import CoreAudio
import Foundation

/// Records the default microphone (left) and all computer audio (right) into
/// one recording folder, following device changes without stopping.
public final class Recorder: @unchecked Sendable {
    public struct Options: Sendable {
        public var folder: URL
        public var sampleRate: Double = 48_000
        /// Audio is written this far behind real time so late callbacks still land.
        public var writeLatency: Double = 1.0
        /// A capture with no callbacks for this long is rebuilt.
        public var stallTimeout: Double = 2.0
        /// Device changes arriving within this window cause one rebuild.
        public var settleDelay: Double = 0.3
        public var systemAudioMode: String = "withOutput"

        public init(folder: URL) { self.folder = folder }
    }

    public struct Result: Sendable {
        public let folder: URL
        public let audio: URL
    }

    private enum Track { case microphone, computer }

    private let options: Options
    private let queue = DispatchQueue(label: "tapeup.recorder")
    private let log: EventLog
    private let clock: HostClock
    private let started = Date()
    private var microphoneTrack: TrackTimeline
    private var computerTrack: TrackTimeline
    private var microphone: MicrophoneCapture?
    private var computer: SystemAudioCapture?
    private var lastCallback: [Track: UInt64] = [:]
    private var pendingRebuild: [Track: DispatchWorkItem] = [:]
    private var file: AVAudioFile?
    private var timer: DispatchSourceTimer?
    private var inputsSeen: [String] = []
    private var outputsSeen: [String] = []
    private var stopped = false

    private var cafURL: URL { options.folder.appendingPathComponent("audio.caf") }
    private var m4aURL: URL { options.folder.appendingPathComponent("audio.m4a") }

    public init(options: Options) throws {
        self.options = options
        try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        log = EventLog(url: options.folder.appendingPathComponent("events.jsonl"))
        clock = HostClock(sampleRate: options.sampleRate)
        let tolerance = Int64(options.sampleRate * 0.03)
        microphoneTrack = TrackTimeline(toleranceFrames: tolerance)
        computerTrack = TrackTimeline(toleranceFrames: tolerance)
    }

    public func start() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(
            forWriting: cafURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        writeMeta(status: "recording")
        log.record("start", ["sample_rate": options.sampleRate, "system_audio_mode": options.systemAudioMode])

        queue.sync {
            startMicrophone(reason: "start")
            startComputer(reason: "start")
        }
        CoreAudioSystem.onDefaultChange(kAudioHardwarePropertyDefaultInputDevice, queue: queue) { [weak self] in
            self?.scheduleRebuild(.microphone, reason: "default input changed")
        }
        CoreAudioSystem.onDefaultChange(kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in
            self?.scheduleRebuild(.computer, reason: "default output changed")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Stops capture, finalizes `audio.m4a` and `meta.json`, and returns the paths.
    public func stop() throws -> Result {
        try queue.sync {
            stopped = true
            timer?.cancel()
            microphone?.stop()
            computer?.stop()
            microphone = nil
            computer = nil
            write(upTo: max(microphoneTrack.end, computerTrack.end))
            file = nil
            log.record("stop", trackStats())
        }
        try Self.encode(caf: cafURL, to: m4aURL)
        try FileManager.default.removeItem(at: cafURL)
        writeMeta(status: "recorded")
        log.record("finalized", ["audio": m4aURL.lastPathComponent])
        return Result(folder: options.folder, audio: m4aURL)
    }

    // MARK: - Capture lifecycle (on `queue`)

    private func startMicrophone(reason: String) {
        let capture = MicrophoneCapture(
            sampleRate: options.sampleRate,
            sink: { [weak self] host, samples in self?.receive(.microphone, host: host, samples: samples) },
            onConfigurationChange: { [weak self] in
                self?.queue.async { self?.scheduleRebuild(.microphone, reason: "engine configuration changed") }
            })
        do {
            try capture.start()
            microphone = capture
            lastCallback[.microphone] = AudioGetCurrentHostTime()
            note(input: capture.inputName)
            log.record("microphone started", ["device": capture.inputName, "reason": reason])
        } catch {
            microphone = nil
            log.record("microphone failed", ["error": "\(error)", "reason": reason])
        }
    }

    private func startComputer(reason: String) {
        let mode = SystemAudioCapture.Mode(rawValue: options.systemAudioMode) ?? .withOutput
        let capture = SystemAudioCapture(mode: mode, sampleRate: options.sampleRate) { [weak self] host, samples in
            self?.receive(.computer, host: host, samples: samples)
        }
        do {
            try capture.start()
            computer = capture
            lastCallback[.computer] = AudioGetCurrentHostTime()
            note(output: capture.outputName)
            log.record("computer audio started", ["output": capture.outputName, "reason": reason])
        } catch {
            computer = nil
            log.record("computer audio failed", ["error": "\(error)", "reason": reason])
        }
    }

    private func scheduleRebuild(_ track: Track, reason: String) {
        guard !stopped else { return }
        pendingRebuild[track]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(track, reason: reason) }
        pendingRebuild[track] = work
        queue.asyncAfter(deadline: .now() + options.settleDelay, execute: work)
    }

    private func rebuild(_ track: Track, reason: String) {
        guard !stopped else { return }
        pendingRebuild[track] = nil
        switch track {
        case .microphone:
            microphone?.stop()
            microphone = nil
            startMicrophone(reason: reason)
        case .computer:
            computer?.stop()
            computer = nil
            startComputer(reason: reason)
        }
    }

    private func receive(_ track: Track, host: UInt64, samples: [Float]) {
        queue.async { [self] in
            guard !stopped else { return }
            lastCallback[track] = AudioGetCurrentHostTime()
            let frame = clock.frame(atHostTime: host)
            switch track {
            case .microphone: microphoneTrack.append(startFrame: frame, samples: samples)
            case .computer: computerTrack.append(startFrame: frame, samples: samples)
            }
        }
    }

    private func tick() {
        guard !stopped else { return }
        write(upTo: clock.nowFrame() - Int64(options.writeLatency * options.sampleRate))
        let now = AudioGetCurrentHostTime()
        for track in [Track.microphone, .computer] where pendingRebuild[track] == nil {
            let silentFor =
                Double(clock.frame(atHostTime: now) - clock.frame(atHostTime: lastCallback[track] ?? now))
                / options.sampleRate
            if silentFor > options.stallTimeout {
                lastCallback[track] = now
                rebuild(track, reason: "no audio for \(Int(silentFor * 1000)) ms")
            }
        }
    }

    private func write(upTo frame: Int64) {
        guard let file, frame > microphoneTrack.writtenUpTo else { return }
        let left = microphoneTrack.take(upTo: frame)
        let right = computerTrack.take(upTo: frame)
        let count = min(left.count, right.count)
        guard count > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
        right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: count) }
        do {
            try file.write(from: buffer)
        } catch {
            log.record("write failed", ["error": "\(error)"])
        }
    }

    // MARK: - Metadata

    private func note(input: String) { if !inputsSeen.contains(input) { inputsSeen.append(input) } }
    private func note(output: String) { if !outputsSeen.contains(output) { outputsSeen.append(output) } }

    private func trackStats() -> [String: Any] {
        func stats(_ track: TrackTimeline) -> [String: Any] {
            [
                "inserted_silence_seconds": Double(track.insertedSilenceFrames) / options.sampleRate,
                "dropped_seconds": Double(track.droppedFrames) / options.sampleRate,
                "corrections": track.corrections,
            ]
        }
        return ["microphone": stats(microphoneTrack), "computer_audio": stats(computerTrack)]
    }

    private func writeMeta(status: String) {
        var meta: [String: Any] = [
            "format": "tapeup-recording/0",
            "status": status,
            "started": ISO8601DateFormatter().string(from: started),
            "audio": status == "recording" ? "audio.caf" : "audio.m4a",
            "channels": ["left": "microphone", "right": "computer audio"],
            "devices": ["inputs": inputsSeen, "outputs": outputsSeen],
        ]
        if status != "recording" {
            meta["duration_seconds"] = (Double(microphoneTrack.writtenUpTo) / options.sampleRate * 10).rounded() / 10
            meta["timeline"] = trackStats()
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        try? data.write(to: options.folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func encode(caf: URL, to m4a: URL) throws {
        let source = try AVAudioFile(forReading: caf)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.fileFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let target = try AVAudioFile(
            forWriting: m4a, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 48_000) else { return }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try target.write(from: buffer)
        }
    }
}
