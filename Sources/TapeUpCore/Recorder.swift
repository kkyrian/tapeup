import AVFoundation
import CoreAudio
import Foundation
import os

/// Records the default microphone (left) and all computer audio (right) into
/// one recording folder, following device changes without stopping.
///
/// Two queues keep a slow device rebuild from delaying audio: `control` owns
/// the captures, listeners and rebuilds; `data` owns the timelines and the file.
public final class Recorder: @unchecked Sendable {
    public struct Options: Sendable {
        public var folder: URL
        public var sampleRate: Double = 48_000
        /// Audio is written this far behind real time so late callbacks still land.
        public var writeLatency: Double = 1.0
        /// A capture that has delivered audio and then goes quiet this long is rebuilt.
        public var stallTimeout: Double = 1.0
        /// A new capture gets this long to deliver its first audio.
        public var firstAudioGrace: Double = 3.0
        /// After this many microphone starts in a row deliver nothing, the
        /// built-in microphone is used until the default input changes.
        public var failuresBeforeFallback: Int = 3
        /// Device changes arriving within this window cause one rebuild.
        public var settleDelay: Double = 0.3

        public init(folder: URL) { self.folder = folder }
    }

    public struct Result: Sendable {
        public let folder: URL
        public let audio: URL
    }

    public struct EncodeFailure: Error, CustomStringConvertible {
        public let detail: String
        public var description: String { "encoding audio.m4a failed: \(detail); audio.caf was kept" }
    }

    private enum Track: String { case microphone, computer }

    private let options: Options
    private let log: EventLog
    private let clock: HostClock
    private let started = Date()

    // MARK: control queue state
    private let control = DispatchQueue(label: "tapeup.recorder.control")
    private var microphone: MicrophoneCapture?
    private var computer: SystemAudioCapture?
    private var listeners: [Track: [CoreAudioSystem.Listener]] = [:]
    private var defaultListeners: [CoreAudioSystem.Listener] = []
    private var pendingRebuild: [Track: DispatchWorkItem] = [:]
    private var startedAt: [Track: UInt64] = [:]
    private var generation: [Track: Int] = [:]
    private var microphoneFailures = 0
    private var usingFallback = false
    private var stallTimer: DispatchSourceTimer?
    private var inputsSeen: [String] = []
    private var outputsSeen: [String] = []
    private var stopping = false

    /// Last host time each track delivered samples, keyed by capture generation.
    private let lastAudio = OSAllocatedUnfairLock(initialState: [Track: (generation: Int, host: UInt64)]())

    // MARK: data queue state
    private let data = DispatchQueue(label: "tapeup.recorder.data", qos: .userInitiated)
    private var microphoneTrack: TrackTimeline
    private var computerTrack: TrackTimeline
    private var file: AVAudioFile?
    private var writeTimer: DispatchSourceTimer?
    private var writeErrors = 0
    private var accepting = true

    private var cafURL: URL { options.folder.appendingPathComponent("audio.caf") }
    private var m4aURL: URL { options.folder.appendingPathComponent("audio.m4a") }

    public init(options: Options) throws {
        self.options = options
        try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
        log = EventLog(url: options.folder.appendingPathComponent("events.jsonl"))
        clock = HostClock(sampleRate: options.sampleRate)
        let tolerance = Int64(options.sampleRate * 0.03)
        let maxGap = Int64(options.sampleRate * (options.writeLatency + 5))
        microphoneTrack = TrackTimeline(toleranceFrames: tolerance, maxGapFrames: maxGap)
        computerTrack = TrackTimeline(toleranceFrames: tolerance, maxGapFrames: maxGap)
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
        let leftovers = CoreAudioSystem.removeLeftovers()
        if leftovers > 0 { log.record("removed leftover devices", ["count": leftovers]) }
        log.record("start", ["sample_rate": options.sampleRate])

        control.sync {
            writeMeta(status: "recording")
            startMicrophone(reason: "start")
            startComputer(reason: "start")
            defaultListeners = [
                CoreAudioSystem.Listener(
                    object: CoreAudioSystem.system, selector: kAudioHardwarePropertyDefaultInputDevice,
                    queue: control
                ) { [weak self] in
                    self?.microphoneFailures = 0
                    self?.usingFallback = false
                    self?.scheduleRebuild(.microphone, reason: "default input changed")
                },
                CoreAudioSystem.Listener(
                    object: CoreAudioSystem.system, selector: kAudioHardwarePropertyDefaultOutputDevice,
                    queue: control
                ) { [weak self] in self?.scheduleRebuild(.computer, reason: "default output changed") },
            ]
            stallTimer = repeating(on: control) { [weak self] in self?.checkStalls() }
        }
        data.sync {
            writeTimer = repeating(on: data) { [weak self] in
                guard let self else { return }
                write(upTo: clock.nowFrame() - Int64(options.writeLatency * options.sampleRate))
            }
        }
    }

    /// Stops capture, finalizes `audio.m4a` and `meta.json`, and returns the paths.
    public func stop() throws -> Result {
        control.sync {
            stopping = true
            stallTimer?.cancel()
            for work in pendingRebuild.values { work.cancel() }
            pendingRebuild = [:]
            for listener in defaultListeners { listener.remove() }
            stopCapture(.microphone)
            stopCapture(.computer)
        }
        // Captures are stopped and their queues drained, so every chunk they
        // delivered is already queued on `data` ahead of this.
        let stats: [String: Any] = data.sync {
            accepting = false
            writeTimer?.cancel()
            write(upTo: max(microphoneTrack.end, computerTrack.end))
            file?.close()
            file = nil
            return trackStats()
        }
        log.record("stop", stats)
        do {
            try Self.encode(caf: cafURL, to: m4aURL)
        } catch {
            try? FileManager.default.removeItem(at: m4aURL)
            let failure = EncodeFailure(detail: "\(error)")
            log.record("encode failed", ["error": failure.detail])
            control.sync { writeMeta(status: "recorded", audio: "audio.caf", stats: stats) }
            throw failure
        }
        try FileManager.default.removeItem(at: cafURL)
        control.sync { writeMeta(status: "recorded", audio: "audio.m4a", stats: stats) }
        log.record("finalized", ["audio": m4aURL.lastPathComponent])
        return Result(folder: options.folder, audio: m4aURL)
    }

    // MARK: - Capture lifecycle (on `control`)

    private func startMicrophone(reason: String) {
        var device = CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        if usingFallback, let builtIn = CoreAudioSystem.builtInInput() { device = builtIn }
        guard device != kAudioObjectUnknown else {
            log.record("microphone failed", ["error": "no input device", "reason": reason])
            begin(.microphone)
            return
        }
        let capture = MicrophoneCapture(device: device)
        let generation = begin(.microphone)
        do {
            try capture.start(
                sampleRate: options.sampleRate,
                sink: sink(.microphone, generation: generation),
                issue: issueLogger(.microphone))
            microphone = capture
            listeners[.microphone] = [
                listener(device, kAudioDevicePropertyNominalSampleRate, .microphone, "input rate changed"),
                listener(device, kAudioDevicePropertyDeviceIsAlive, .microphone, "input device went away"),
                listener(device, kAudioDevicePropertyStreamConfiguration, .microphone, "input streams changed"),
            ]
            note(input: capture.name)
            log.record(
                "microphone started",
                ["device": capture.name, "reason": reason, "fallback": usingFallback, "generation": generation])
        } catch {
            log.record("microphone failed", ["device": capture.name, "error": "\(error)", "reason": reason])
        }
    }

    private func startComputer(reason: String) {
        let capture = SystemAudioCapture()
        let generation = begin(.computer)
        do {
            try capture.start(
                sampleRate: options.sampleRate,
                sink: sink(.computer, generation: generation),
                issue: issueLogger(.computer))
            computer = capture
            listeners[.computer] = [
                listener(capture.tapID, kAudioTapPropertyFormat, .computer, "tap format changed"),
                listener(capture.aggregateID, kAudioDevicePropertyNominalSampleRate, .computer, "tap rate changed"),
            ]
            note(output: capture.outputName)
            log.record(
                "computer audio started", ["output": capture.outputName, "reason": reason, "generation": generation])
        } catch {
            log.record("computer audio failed", ["error": "\(error)", "reason": reason])
        }
    }

    /// Starts a new generation for a track; callbacks from older ones are ignored.
    @discardableResult
    private func begin(_ track: Track) -> Int {
        let next = (generation[track] ?? 0) + 1
        generation[track] = next
        startedAt[track] = AudioGetCurrentHostTime()
        return next
    }

    private func stopCapture(_ track: Track) {
        for listener in listeners[track] ?? [] { listener.remove() }
        listeners[track] = nil
        switch track {
        case .microphone:
            microphone?.stop()
            microphone = nil
        case .computer:
            computer?.stop()
            computer = nil
        }
    }

    private func listener(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ track: Track, _ reason: String
    ) -> CoreAudioSystem.Listener {
        CoreAudioSystem.Listener(object: object, selector: selector, queue: control) { [weak self] in
            self?.scheduleRebuild(track, reason: reason)
        }
    }

    private func scheduleRebuild(_ track: Track, reason: String) {
        guard !stopping else { return }
        pendingRebuild[track]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(track, reason: reason) }
        pendingRebuild[track] = work
        control.asyncAfter(deadline: .now() + options.settleDelay, execute: work)
    }

    private func rebuild(_ track: Track, reason: String) {
        guard !stopping else { return }
        pendingRebuild[track] = nil
        stopCapture(track)
        switch track {
        case .microphone: startMicrophone(reason: reason)
        case .computer: startComputer(reason: reason)
        }
        writeMeta(status: "recording")
    }

    private func checkStalls() {
        guard !stopping else { return }
        let now = AudioGetCurrentHostTime()
        let heard = lastAudio.withLock { $0 }
        for track in [Track.microphone, .computer] where pendingRebuild[track] == nil {
            let current = generation[track] ?? 0
            if let last = heard[track], last.generation == current {
                let quiet = clock.seconds(atHostTime: now) - clock.seconds(atHostTime: last.host)
                if track == .microphone { microphoneFailures = 0 }
                if quiet > options.stallTimeout {
                    rebuild(track, reason: "no audio for \(Int(quiet * 1000)) ms")
                }
            } else {
                let waited = clock.seconds(atHostTime: now) - clock.seconds(atHostTime: startedAt[track] ?? now)
                guard waited > options.firstAudioGrace else { continue }
                if track == .microphone {
                    microphoneFailures += 1
                    if !usingFallback, microphoneFailures >= options.failuresBeforeFallback,
                        CoreAudioSystem.builtInInput() != nil
                    {
                        usingFallback = true
                        log.record("microphone fallback", ["failures": microphoneFailures])
                    }
                }
                rebuild(track, reason: "no audio \(Int(waited * 1000)) ms after start")
            }
        }
    }

    private func sink(_ track: Track, generation: Int) -> DeviceInputReader.Sink {
        { [weak self] host, samples in
            guard let self, !samples.isEmpty else { return }
            lastAudio.withLock { $0[track] = (generation, AudioGetCurrentHostTime()) }
            let frame = host.map { clock.frame(atHostTime: $0) }
            data.async { [self] in
                guard accepting else { return }
                switch track {
                case .microphone: microphoneTrack.append(startFrame: frame, samples: samples)
                case .computer: computerTrack.append(startFrame: frame, samples: samples)
                }
            }
        }
    }

    private func issueLogger(_ track: Track) -> @Sendable (String) -> Void {
        let log = self.log
        return { log.record("\(track.rawValue) issue", ["detail": $0]) }
    }

    private func repeating(on queue: DispatchQueue, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    // MARK: - Writing (on `data`)

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
            writeErrors += 1
            if writeErrors <= 3 { log.record("write failed", ["error": "\(error)", "count": writeErrors]) }
        }
    }

    private func trackStats() -> [String: Any] {
        func stats(_ track: TrackTimeline) -> [String: Any] {
            [
                "inserted_silence_seconds": Double(track.insertedSilenceFrames) / options.sampleRate,
                "dropped_seconds": Double(track.droppedFrames) / options.sampleRate,
                "corrections": track.corrections,
                "untrusted_timestamps": track.untrustedTimestamps,
            ]
        }
        return [
            "duration_seconds": (Double(microphoneTrack.writtenUpTo) / options.sampleRate * 10).rounded() / 10,
            "write_errors": writeErrors,
            "microphone": stats(microphoneTrack),
            "computer_audio": stats(computerTrack),
        ]
    }

    // MARK: - Metadata (on `control`)

    private func note(input: String) { if !inputsSeen.contains(input) { inputsSeen.append(input) } }
    private func note(output: String) { if !outputsSeen.contains(output) { outputsSeen.append(output) } }

    private func writeMeta(status: String, audio: String = "audio.caf", stats: [String: Any]? = nil) {
        var meta: [String: Any] = [
            "format": "tapeup-recording/0",
            "status": status,
            "started": ISO8601DateFormatter().string(from: started),
            "audio": audio,
            "channels": ["left": "microphone", "right": "computer audio"],
            "devices": ["inputs": inputsSeen, "outputs": outputsSeen],
        ]
        if let stats {
            meta["duration_seconds"] = stats["duration_seconds"]
            meta["write_errors"] = stats["write_errors"]
            meta["timeline"] = ["microphone": stats["microphone"], "computer_audio": stats["computer_audio"]]
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        do {
            try data.write(to: options.folder.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            log.record("meta write failed", ["error": "\(error)"])
        }
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 48_000) else {
            throw EncodeFailure(detail: "could not allocate a buffer")
        }
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try target.write(from: buffer)
        }
        target.close()
        // AAC adds a little priming; anything shorter than the source means frames were lost.
        let written = try AVAudioFile(forReading: m4a).length
        guard written >= source.length else {
            throw EncodeFailure(detail: "m4a has \(written) frames, source has \(source.length)")
        }
    }
}
