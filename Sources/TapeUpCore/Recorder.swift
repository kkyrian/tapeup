import AVFoundation
import Accelerate
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
        /// The user's name, recorded in `meta.json` so agents know whose mic the left channel is.
        public var you: String?

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

    /// What the panel shows while recording: each track's peak since the last
    /// read (0...1) and the devices in use.
    public struct Live: Sendable {
        public var microphoneLevel: Float = 0
        public var computerLevel: Float = 0
        public var microphone = ""
        public var output = ""
    }

    private enum Track: String { case microphone, computer }

    public let options: Options
    private let log: EventLog
    private let clock: HostClock
    public let started = Date()
    private let live = OSAllocatedUnfairLock(initialState: Live())

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
    private var folderLock: FolderLock?

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
    /// The frame of the first audio from either track; the file starts here.
    private var origin: Int64?

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
        folderLock = FolderLock(folder: options.folder)
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
        defer { folderLock?.release() }
        do {
            try Self.encode(caf: cafURL, to: m4aURL)
        } catch {
            if FileManager.default.fileExists(atPath: cafURL.path) { try? FileManager.default.removeItem(at: m4aURL) }
            let failure = EncodeFailure(detail: "\(error)")
            log.record("encode failed", ["error": failure.detail])
            control.sync { writeMeta(status: "recorded", audio: "audio.caf", stats: stats) }
            throw failure
        }
        // Name the finished file before removing the raw one, so no moment
        // leaves meta.json pointing at a file that is gone.
        control.sync { writeMeta(status: "recorded", audio: "audio.m4a", stats: stats) }
        try? FileManager.default.removeItem(at: cafURL)
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
            let peak = vDSP.maximumMagnitude(samples)
            live.withLock {
                switch track {
                case .microphone: $0.microphoneLevel = max($0.microphoneLevel, peak)
                case .computer: $0.computerLevel = max($0.computerLevel, peak)
                }
            }
            let frame = host.map { clock.frame(atHostTime: $0) }
            data.async { [self] in
                guard accepting else { return }
                if origin == nil {
                    // The file starts at the first audio with a timestamp;
                    // anything untimed before it has no place yet.
                    guard let frame else { return }
                    origin = frame
                    microphoneTrack.begin(at: frame)
                    computerTrack.begin(at: frame)
                }
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
        guard let file, origin != nil, frame > microphoneTrack.writtenUpTo else { return }
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
            "duration_seconds": (Double(microphoneTrack.writtenUpTo - (origin ?? 0)) / options.sampleRate * 10)
                .rounded() / 10,
            "write_errors": writeErrors,
            "microphone": stats(microphoneTrack),
            "computer_audio": stats(computerTrack),
        ]
    }

    // MARK: - Metadata (on `control`)

    private func note(input: String) {
        live.withLock { $0.microphone = input }
        if !inputsSeen.contains(input) { inputsSeen.append(input) }
    }

    private func note(output: String) {
        live.withLock { $0.output = output }
        if !outputsSeen.contains(output) { outputsSeen.append(output) }
    }

    /// Levels since the last call, and the devices in use now.
    public func takeLive() -> Live {
        live.withLock { state in
            let current = state
            state.microphoneLevel = 0
            state.computerLevel = 0
            return current
        }
    }

    /// Updates the fields the recorder owns and keeps everything else, such
    /// as who was there, which the card may have saved meanwhile.
    private func writeMeta(status: String, audio: String = "audio.caf", stats: [String: Any]? = nil) {
        let started = ISO8601DateFormatter().string(from: started)
        let devices = ["inputs": inputsSeen, "outputs": outputsSeen]
        let you = options.you
        do {
            try MetaFile.update(options.folder) { meta in
                meta["format"] = "tapeup-recording/0"
                meta["status"] = status
                meta["started"] = started
                meta["audio"] = audio
                meta["channels"] = ["left": "microphone", "right": "computer audio"]
                meta["devices"] = devices
                if let you { meta["you"] = you }
                if let stats {
                    meta["duration_seconds"] = stats["duration_seconds"]
                    meta["write_errors"] = stats["write_errors"]
                    meta["timeline"] = ["microphone": stats["microphone"], "computer_audio": stats["computer_audio"]]
                }
            }
        } catch {
            log.record("meta write failed", ["error": "\(error)"])
        }
    }

    /// Finishes a recording a crash left behind: encodes its `audio.caf` and
    /// marks it recorded. Returns false when the folder needs nothing.
    /// Only recordings started before `cutoff` are touched, so one this
    /// process is making now is never mistaken for a crashed one.
    public static func recover(folder: URL, startedBefore cutoff: Date = .distantFuture) throws -> Bool {
        let caf = folder.appendingPathComponent("audio.caf")
        let m4a = folder.appendingPathComponent("audio.m4a")
        guard let meta = MetaFile.read(folder), meta["status"] as? String == "recording",
            let startedText = meta["started"] as? String,
            let started = ISO8601DateFormatter().date(from: startedText), started < cutoff,
            let lock = FolderLock(folder: folder)
        else { return false }
        defer { lock.release() }
        let fileManager = FileManager.default
        var duration = meta["duration_seconds"] as? Double
        if fileManager.fileExists(atPath: caf.path) {
            let source = try AVAudioFile(forReading: caf)
            duration = Double(source.length) / source.fileFormat.sampleRate
            try? fileManager.removeItem(at: m4a)
            try encode(caf: caf, to: m4a)
        } else if !fileManager.fileExists(atPath: m4a.path) {
            return false
        }
        try MetaFile.update(folder) { meta in
            meta["status"] = "recorded"
            meta["audio"] = "audio.m4a"
            meta["recovered"] = true
            if let duration { meta["duration_seconds"] = (duration * 10).rounded() / 10 }
        }
        try? fileManager.removeItem(at: caf)
        return true
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
