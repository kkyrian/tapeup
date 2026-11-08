import AVFoundation
import AudioCommon
import Foundation
import MLX
import Qwen3ASR
import SpeechVAD
import TapeUpCore
import os

/// Where the models live and how they arrive: in TapeUp's own Application
/// Support folder, so macOS never clears them as it may clear caches.
public enum ModelStore {
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TapeUp", isDirectory: true)
    }

    static func directory(for id: String) throws -> URL {
        try HuggingFaceDownloader.getCacheDirectory(for: id, basePath: base)
    }

    private static let tokenizerFiles = ["vocab.json", "merges.txt", "tokenizer_config.json"]

    private static func marker(for model: SpeechModel) -> URL {
        base.appendingPathComponent("models/.\(model.rawValue)-complete")
    }

    public static func isDownloaded(_ model: SpeechModel) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: model).path)
    }

    /// Downloads the model and the voice detector, resuming any partial file;
    /// `progress` gets the bytes so far. Cancelling the task pauses it.
    public static func download(_ model: SpeechModel, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let speechBytes = model.downloadBytes - SpeechModel.voiceDetectorBytes
        try await HuggingFaceDownloader.downloadWeights(
            modelId: model.id, to: directory(for: model.id), additionalFiles: tokenizerFiles,
            progressHandler: { progress(Int64(Double(speechBytes) * $0)) })
        try await HuggingFaceDownloader.downloadWeights(
            modelId: SileroVADModel.defaultModelId, to: directory(for: SileroVADModel.defaultModelId),
            progressHandler: { progress(speechBytes + Int64(Double(SpeechModel.voiceDetectorBytes) * $0)) })
        try Data().write(to: marker(for: model))
    }
}

/// A loaded model. MLX is not thread safe, so all model work, loading
/// included and across engines, runs one piece at a time on `queue`.
public final class SpeechEngine: @unchecked Sendable {
    public let model: SpeechModel
    static let queue = DispatchQueue(label: "tapeup.speech", qos: .userInitiated)
    var queue: DispatchQueue { Self.queue }
    private let recognizer: QwenRecognizer

    private init(model: SpeechModel, recognizer: QwenRecognizer) {
        self.model = model
        self.recognizer = recognizer
    }

    public static func load(_ model: SpeechModel) async throws -> SpeechEngine {
        try await exclusively {
            let asr = try await Qwen3ASRModel.fromPretrained(
                modelId: model.id, cacheDir: ModelStore.directory(for: model.id), offlineMode: true)
            return SpeechEngine(model: model, recognizer: QwenRecognizer(model: asr))
        }
    }

    /// Runs async model work with `queue` held, so nothing else touches MLX
    /// meanwhile. The queue's thread waits; the work runs on its own.
    static func exclusively<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let done = DispatchSemaphore(value: 0)
                Task {
                    do { continuation.resume(returning: try await work()) } catch {
                        continuation.resume(throwing: error)
                    }
                    done.signal()
                }
                done.wait()
            }
        }
    }

    /// A new transcript, fed live or from a file. Each session has its own
    /// voice detectors, since a detector carries state from chunk to chunk.
    public func session(names: String?, microphone: Bool, computer: Bool) async throws -> TranscriptSession {
        let directory = try ModelStore.directory(for: SileroVADModel.defaultModelId)
        let detectors = try await Self.exclusively {
            var detectors: [SileroVADModel] = []
            for _ in 0..<2 {
                detectors.append(try await SileroVADModel.fromPretrained(cacheDir: directory, offlineMode: true))
            }
            return Detectors(models: detectors)
        }.models
        return TranscriptSession(
            engine: self, detectors: detectors, hints: model.takesHints ? names : nil, microphone: microphone,
            computer: computer)
    }

    fileprivate var speechRecognizer: SpeechRecognizer { recognizer }
}

private struct Detectors: @unchecked Sendable {
    let models: [SileroVADModel]
}

/// One transcript in the making. Feed it from any thread; the work happens
/// in order on the engine's queue.
public final class TranscriptSession: @unchecked Sendable {
    public struct Outcome: Sendable {
        public let lines: [TranscriptLine]
        /// Pieces the model failed on, out of all pieces heard.
        public let failures: Int
        public let pieces: Int
    }

    private let engine: SpeechEngine
    private let pipeline: TranscriptPipeline
    private let latestLines = OSAllocatedUnfairLock(initialState: [TranscriptLine]())
    private let backlog = OSAllocatedUnfairLock(initialState: Backlog())

    private struct Backlog {
        var frames = 0
        var overloaded = false
    }

    /// Live audio waiting for the model, at most two minutes behind; past
    /// that the session gives up and the transcript is made from the file.
    private static let backlogLimit = 48_000 * 120

    fileprivate init(
        engine: SpeechEngine, detectors: [SileroVADModel], hints: String?, microphone: Bool, computer: Bool
    ) {
        self.engine = engine
        var pool = detectors
        // At most two detectors are in use at once (one per side); a mode
        // change finishes the old ones before making new ones.
        pipeline = TranscriptPipeline(
            makeDetector: {
                let model = pool.removeFirst()
                pool.append(model)
                return SileroDetector(model: model)
            }, recognizer: engine.speechRecognizer, hints: hints, microphone: microphone, computer: computer)
    }

    public var model: SpeechModel { engine.model }

    /// The last two lines heard, for the panel while recording.
    public var latest: [TranscriptLine] { latestLines.withLock { $0 } }

    public func feed(left: [Float], right: [Float], headphones: Bool) {
        let frames = left.count
        let accepted = backlog.withLock { backlog in
            if backlog.frames > Self.backlogLimit { backlog.overloaded = true }
            if backlog.overloaded { return false }
            backlog.frames += frames
            return true
        }
        guard accepted else { return }
        engine.queue.async { [self] in
            defer { backlog.withLock { $0.frames -= frames } }
            guard !overloaded else { return }
            pipeline.feed(left: left, right: right, headphones: headphones)
            let last = Array(pipeline.lines.suffix(2))
            latestLines.withLock { $0 = last }
        }
    }

    /// True once the live audio fell too far behind; what was heard is
    /// then incomplete, and the queued audio is skipped.
    public var overloaded: Bool { backlog.withLock { $0.overloaded } }

    /// Seconds of live audio waiting for the model.
    public var behind: Double { Double(backlog.withLock { $0.frames }) / 48_000 }

    /// Stops work on audio still queued, for a session that will not be finished.
    public func abandon() { backlog.withLock { $0.overloaded = true } }

    public func finish() async -> Outcome {
        await withCheckedContinuation { continuation in
            engine.queue.async { [self] in
                let lines = pipeline.finish()
                continuation.resume(
                    returning: Outcome(lines: lines, failures: pipeline.failures, pieces: pipeline.pieces))
            }
        }
    }

    /// Transcribes a finished recording, a slice at a time so a live
    /// recording sharing the queue is never held up for long.
    /// `progress` gets how far through the file it is, 0 to 1, and the
    /// latest line heard, after each slice.
    public func transcribe(
        file: URL, headphones: Bool, progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws -> Outcome {
        let source = try AVAudioFile(forReading: file)
        guard Int(source.processingFormat.sampleRate) == TranscriptPipeline.fileRate,
            source.processingFormat.channelCount == 2,
            let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 48_000 * 30)
        else { throw CocoaError(.fileReadCorruptFile) }
        let reader = FileSlices(source: source, buffer: buffer)
        while true {
            let more: Bool = try await withCheckedThrowingContinuation { continuation in
                engine.queue.async { [self] in
                    do {
                        guard let (left, right) = try reader.next() else {
                            return continuation.resume(returning: false)
                        }
                        pipeline.feed(left: left, right: right, headphones: headphones)
                        progress?(reader.fraction, pipeline.lines.last?.text)
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            guard more else { break }
        }
        return await finish()
    }
}

/// Reads a stereo file thirty seconds at a time.
private final class FileSlices: @unchecked Sendable {
    let source: AVAudioFile
    let buffer: AVAudioPCMBuffer

    init(source: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.source = source
        self.buffer = buffer
    }

    var fraction: Double { source.length > 0 ? Double(source.framePosition) / Double(source.length) : 1 }

    func next() throws -> ([Float], [Float])? {
        guard source.framePosition < source.length else { return nil }
        try source.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return nil }
        return (
            Array(UnsafeBufferPointer(start: data[0], count: count)),
            Array(UnsafeBufferPointer(start: data[1], count: count))
        )
    }
}

final class QwenRecognizer: SpeechRecognizer {
    private let model: Qwen3ASRModel

    init(model: Qwen3ASRModel) { self.model = model }

    func transcribe(_ samples: [Float], hints: String?) throws -> String {
        try model.transcribeThrowing(audio: samples, sampleRate: 16_000, options: Qwen3DecodingOptions(context: hints))
    }
}

/// Silero voice detection, set to cut only at pauses of 0.8 s or more and to
/// skip sounds shorter than half a second, as tested on real meetings.
final class SileroDetector: VoiceDetector {
    static let config = VADConfig(
        onset: 0.5, offset: 0.35, minSpeechDuration: 0.5, minSilenceDuration: 0.8, windowDuration: 0.032,
        stepRatio: 1.0)

    private let processor: StreamingVADProcessor

    init(model: SileroVADModel) {
        model.resetState()
        processor = StreamingVADProcessor(model: model, config: Self.config)
    }

    func process(_ samples: [Float]) -> [VoiceEvent] { processor.process(samples: samples).map(Self.event) }

    func flush() -> [VoiceEvent] { processor.flush().map(Self.event) }

    private static func event(_ event: VADEvent) -> VoiceEvent {
        switch event {
        case .speechStarted(let time): .started(Double(time))
        case .speechEnded(let segment): .ended(Double(segment.endTime))
        }
    }
}

/// Transcribes a recording that is already saved: made before the model
/// arrived, interrupted, retried after a failure, or asked for later.
public enum FolderTranscriber {
    public static func run(folder: URL, engine: SpeechEngine, names: String?) async throws {
        let outcome = try await transcribe(folder: folder, engine: engine, names: names)
        try TranscriptDocument.save(
            lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: engine.model,
            in: folder)
    }

    /// The lines heard, without saving them: the folder may be renamed while
    /// this runs, so the caller looks it up again to save.
    public static func transcribe(
        folder: URL, engine: SpeechEngine, names: String?,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws -> TranscriptSession.Outcome {
        guard let meta = MetaFile.read(folder) else { throw CocoaError(.fileNoSuchFile) }
        let sources = meta["sources"] as? [String] ?? ["microphone", "computer audio"]
        let audio = folder.appendingPathComponent(meta["audio"] as? String ?? "audio.m4a")
        try RecordingLibrary.markTranscript("transcribing", model: engine.model.name, in: folder)
        let session = try await engine.session(
            names: names, microphone: sources.contains("microphone"), computer: sources.contains("computer audio"))
        return try await session.transcribe(
            file: audio, headphones: meta["output_headphones"] as? Bool == true, progress: progress)
    }
}

/// Finds who spoke when: Nemotron 3 diarization, then a WeSpeaker voice print
/// for each voice it found, so voices can be folded into people afterwards.
/// Chosen on real meetings for its accuracy and speed (about 8 s for 100
/// minutes on an M4 Max) at under 3 GB.
public enum SpeakerFinder {
    static let diarizerId = Nemotron3Diarizer.defaultMLXModelId
    static let printsId = WeSpeakerModel.defaultModelId
    public static let downloadBytes: Int64 = 128_000_000

    private static var marker: URL { ModelStore.base.appendingPathComponent("models/.speakers-complete") }

    public static func isDownloaded() -> Bool { FileManager.default.fileExists(atPath: marker.path) }

    /// Downloads both models without loading them, resuming any partial
    /// file; `progress` gets 0 to 1.
    public static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await HuggingFaceDownloader.downloadWeights(
            modelId: diarizerId, to: ModelStore.directory(for: diarizerId),
            additionalFiles: ["model.safetensors", "config.json"], progressHandler: { progress($0 * 0.8) })
        try await HuggingFaceDownloader.downloadWeights(
            modelId: printsId, to: ModelStore.directory(for: printsId), progressHandler: { progress(0.8 + $0 * 0.2) })
        try Data().write(to: marker)
    }

    /// The voices in a saved recording. Both models load for this and are
    /// let go afterwards; nothing else runs on the models meanwhile.
    public static func listen(folder: URL) async throws -> VoicePrints {
        guard let meta = MetaFile.read(folder) else { throw CocoaError(.fileNoSuchFile) }
        let sources = meta["sources"] as? [String] ?? ["microphone", "computer audio"]
        let file = folder.appendingPathComponent(meta["audio"] as? String ?? "audio.m4a")
        let diarizerDirectory = try ModelStore.directory(for: diarizerId)
        let printsDirectory = try ModelStore.directory(for: printsId)
        // Decoded before taking the queue, which live transcription shares.
        let audio = try SpeechAudio.mono(
            file: file, microphone: sources.contains("microphone"), computer: sources.contains("computer audio"))
        return try await SpeechEngine.exclusively {
            let previousLimit = MLX.Memory.cacheLimit
            MLX.Memory.cacheLimit = 256 * 1_048_576
            defer {
                MLX.Memory.cacheLimit = previousLimit
                MLX.Memory.clearCache()
            }
            let diarizer = try await Nemotron3Diarizer.fromMLXPretrained(
                cacheDir: diarizerDirectory, offlineMode: true)
            let turns = try diarizer.diarize(audio: audio, sampleRate: 16_000).segments.map {
                VoiceTurn(start: Double($0.startTime), end: Double($0.endTime), voice: $0.speakerId)
            }
            let embedder = try await WeSpeakerModel.fromPretrained(cacheDir: printsDirectory, offlineMode: true)
            var prints: [Int: [Float]] = [:]
            for voice in Set(turns.map(\.voice)) {
                prints[voice] = voicePrint(of: turns.filter { $0.voice == voice }, in: audio, embedder: embedder)
            }
            return VoicePrints(turns: turns, prints: prints)
        }
    }

    /// The talk-weighted mean print of a voice's 30 longest turns, each
    /// heard for at most 8 s; nil when it has no turn long enough to judge.
    private static func voicePrint(of turns: [VoiceTurn], in audio: [Float], embedder: WeSpeakerModel) -> [Float]? {
        let longest = turns.sorted { $0.end - $0.start > $1.end - $1.start }
        var pieces = Array(longest.filter { $0.end - $0.start >= 1 }.prefix(30))
        if pieces.isEmpty, let first = longest.first { pieces = [first] }
        var sum: [Float] = []
        for piece in pieces {
            let start = max(0, Int(piece.start * 16_000))
            let end = min(audio.count, Int(min(piece.end, piece.start + 8) * 16_000))
            guard end - start >= 4_800 else { continue }
            let print = embedder.embed(audio: Array(audio[start..<end]), sampleRate: 16_000)
            if sum.isEmpty { sum = [Float](repeating: 0, count: print.count) }
            let weight = Float(end - start)
            for index in sum.indices where index < print.count { sum[index] += print[index] * weight }
        }
        let length = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? sum.map { $0 / length } : nil
    }
}
