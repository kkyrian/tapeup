import AppKit
import Observation
import TapeUpCore
import TapeUpSpeech

/// Transcripts: getting the model, transcribing while recording, and
/// transcribing saved recordings that still need it, one at a time.
@MainActor @Observable
final class Transcription {
    enum Download: Equatable {
        case downloading(Int64)
        /// The switch was turned off part way.
        case paused(Int64)
        /// The network failed; it tries again on its own.
        case retrying(Int64)
        case ready
    }

    /// Whether new recordings are transcribed. Off means audio only.
    private(set) var enabled = UserDefaults.standard.object(forKey: "transcribe") as? Bool ?? true
    /// The model this Mac's memory allows; downloaded first.
    let model = SpeechModel.forThisMac()
    private(set) var download: Download
    /// Stamps of recordings being transcribed now or waiting their turn.
    private(set) var working: Set<String> = []
    /// The last lines heard in the recording running now.
    private(set) var latest: [TranscriptLine] = []
    /// True while the recording running now is transcribed as it goes.
    private(set) var liveRunning = false

    /// Called with a recording's stamp when its transcript is written or fails.
    var finished: (String) -> Void = { _ in }
    /// The names to give the model: people, participants, title words.
    var names: () -> String? = { nil }
    var library: RecordingLibrary

    private var downloadTask: Task<Void, Never>?
    private var lighterTask: Task<Void, Never>?
    private var engine: (model: SpeechModel, task: Task<SpeechEngine, Error>)?
    private var unload: Task<Void, Never>?
    /// Saved recordings waiting for a file transcription, oldest first.
    private var queue: [String] = []
    private var processing = false
    /// The recording whose file is being transcribed now.
    private(set) var current: String?
    /// How far the recording running now has come, once it has started.
    private(set) var progress: Progress?

    struct Progress: Equatable {
        var fraction: Double
        /// The latest line heard, for a glimpse of what is coming.
        var line: String?
        /// Where the estimate starts: after the model has loaded.
        var first: (fraction: Double, at: Date)

        static func == (a: Self, b: Self) -> Bool { a.fraction == b.fraction && a.line == b.line }

        /// Seconds left at the pace so far, once there is a pace to go by.
        func remaining(now: Date = .now) -> TimeInterval? {
            let done = fraction - first.fraction
            let elapsed = now.timeIntervalSince(first.at)
            guard done > 0.02, elapsed > 2 else { return nil }
            return elapsed / done * (1 - fraction)
        }
    }
    private var live: (stamp: String, feed: LiveFeed)?
    /// Live transcripts still finishing after their recording stopped.
    private var finishing = 0
    /// Recordings asked for by a click, made even while transcripts are off.
    private var explicit: Set<String> = []

    init(library: RecordingLibrary) {
        self.library = library
        download = ModelStore.isDownloaded(SpeechModel.forThisMac()) ? .ready : .downloading(0)
    }

    /// Starts the download if the model is missing, and picks up recordings
    /// left waiting: made before the model arrived, or cut off by a quit.
    func start(pending: [RecordingEntry]) {
        if enabled { fetchIfNeeded() }
        for entry in pending.reversed() where entry.transcript == .pending {
            enqueue(RecordingLibrary.stamp(of: entry.folder))
        }
    }

    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "transcribe")
        if enabled {
            fetchIfNeeded()
            processQueue()
        } else if explicit.isEmpty {
            downloadTask?.cancel()
        }
    }

    /// The model is wanted for new recordings, or for one the user clicked.
    private var wantsModel: Bool { enabled || !explicit.isEmpty }

    // MARK: - Download

    private func fetchIfNeeded() {
        guard !staged, downloadTask == nil else { return }
        if ModelStore.isDownloaded(model) {
            download = .ready
            return fetchLighterIfUseful()
        }
        let model = model
        let start: Int64 =
            switch download {
            case .downloading(let bytes), .paused(let bytes), .retrying(let bytes): bytes
            case .ready: 0
            }
        download = .downloading(start)
        downloadTask = Task { [weak self] in
            let reporter = ProgressReporter { bytes in Task { @MainActor in self?.progress(bytes) } }
            do {
                try await ModelStore.download(model, progress: reporter.report)
                self?.downloaded()
            } catch {
                self?.downloadFailed(cancelled: Task.isCancelled)
            }
        }
    }

    private func progress(_ bytes: Int64) {
        if case .downloading = download { download = .downloading(bytes) }
    }

    private func downloaded() {
        downloadTask = nil
        download = .ready
        processQueue()
        fetchLighterIfUseful()
    }

    private func downloadFailed(cancelled: Bool) {
        downloadTask = nil
        let bytes: Int64 = if case .downloading(let done) = download { done } else { 0 }
        download = cancelled ? .paused(bytes) : .retrying(bytes)
        // Turned off and on again before the cancelled download let go.
        if cancelled { return wantsModel ? fetchIfNeeded() : () }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, wantsModel, case .retrying = download else { return }
            fetchIfNeeded()
        }
    }

    /// Laptops also keep the lighter model, for recordings on battery. It
    /// comes quietly after the main one; until then the main one is used.
    private func fetchLighterIfUseful() {
        let lighter = SpeechModel.small
        guard model != lighter, lighterTask == nil, PowerSource.hasBattery(), !ModelStore.isDownloaded(lighter)
        else { return }
        lighterTask = Task { [weak self] in
            await Task.detached(priority: .background) { try? await ModelStore.download(lighter) { _ in } }.value
            self?.lighterTask = nil
        }
    }

    /// The model a recording starting now uses: the lighter one on battery
    /// when it is there, else the main one. Nil until a model is downloaded.
    private func modelForNow() -> SpeechModel? {
        let wanted = SpeechModel.forNow()
        if ModelStore.isDownloaded(wanted) { return wanted }
        return ModelStore.isDownloaded(model) ? model : nil
    }

    // MARK: - Engine

    /// The engine for `wanted`, or the one already loaded while it is in
    /// use: two models at once would not fit the memory they were chosen for.
    private func engine(preferring wanted: SpeechModel) -> (model: SpeechModel, task: Task<SpeechEngine, Error>) {
        unload?.cancel()
        if let engine, engine.model == wanted || busy { return engine }
        release()
        let loaded = (model: wanted, task: Task { try await SpeechEngine.load(wanted) })
        engine = loaded
        return loaded
    }

    private var busy: Bool { live != nil || processing || finishing > 0 }

    /// Drops an engine that failed, so the next transcript loads it afresh
    /// instead of reusing the failure.
    private func forgetEngine(_ model: SpeechModel) {
        if engine?.model == model { release() }
    }

    /// Lets go of the loaded model away from the main thread: freeing a few
    /// gigabytes takes long enough to delay a recording that starts meanwhile.
    private func release() {
        guard let old = engine?.task else { return }
        engine = nil
        Task.detached(priority: .background) { _ = try? await old.value }
    }

    /// Frees the speech model now unless a transcript needs it, to make room
    /// for the speaker model; false while one does.
    func releaseIfIdle() -> Bool {
        guard !busy else { return false }
        unload?.cancel()
        release()
        return true
    }

    /// Frees the model's memory a minute after the last transcript.
    private func scheduleUnload() {
        guard !busy else { return }
        unload?.cancel()
        unload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, !busy else { return }
            release()
        }
    }

    // MARK: - While recording

    /// A feed for the recorder's audio when the next recording should be
    /// transcribed as it goes; nil when transcripts are off.
    func prepareLive() -> LiveFeed? {
        enabled ? LiveFeed() : nil
    }

    /// Called once the recorder has written `meta.json`: marks the
    /// recording and starts its session, or leaves it waiting for the model.
    func began(folder: URL, feed: LiveFeed?, microphone: Bool, computer: Bool) {
        guard let feed else { return }
        let stamp = RecordingLibrary.stamp(of: folder)
        latest = []
        guard let wanted = modelForNow() else {
            try? RecordingLibrary.markTranscript("waiting", model: self.model.name, in: folder)
            liveRunning = false
            return
        }
        let (model, loading) = engine(preferring: wanted)
        try? RecordingLibrary.markTranscript("transcribing", model: model.name, in: folder)
        live = (stamp, feed)
        liveRunning = true
        working.insert(stamp)
        let names = model.takesHints ? names() : nil
        Task {
            do {
                let engine: SpeechEngine
                do { engine = try await loading.value } catch {
                    forgetEngine(model)
                    throw error
                }
                feed.attach(try await engine.session(names: names, microphone: microphone, computer: computer))
            } catch {
                feed.fail()
                if live?.stamp == stamp { liveRunning = false }
            }
        }
    }

    /// The panel reads this while recording.
    func refreshLatest() {
        guard let live else { return }
        if live.feed.isBroken { liveRunning = false }
        guard let lines = live.feed.latest, lines != latest else { return }
        latest = lines
    }

    /// The recording is saved: finish its transcript from what was heard,
    /// or from the file when the live session could not keep up.
    func saved(folder: URL) {
        let stamp = RecordingLibrary.stamp(of: folder)
        if let current = live, current.stamp == stamp {
            live = nil
            liveRunning = false
            let feed = current.feed
            finishing += 1
            Task {
                let outcome = await feed.finish()
                finishing -= 1
                guard let outcome else {
                    working.remove(stamp)
                    return enqueue(stamp)
                }
                let folder = library.folder(withStamp: stamp)
                do {
                    guard let folder else { throw CocoaError(.fileNoSuchFile) }
                    try TranscriptDocument.save(
                        lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: outcome.model,
                        in: folder)
                } catch {
                    if let folder { try? RecordingLibrary.markTranscript("failed", error: "\(error)", in: folder) }
                }
                working.remove(stamp)
                finished(stamp)
                scheduleUnload()
            }
        } else if (MetaFile.read(folder)?["transcript"] as? [String: Any])?["status"] as? String == "waiting" {
            enqueue(stamp)
        }
    }

    // MARK: - Saved recordings

    /// One click: make a transcript for a recording that has none or whose
    /// transcript failed. Works with transcripts off; the click is the ask.
    func make(_ entry: RecordingEntry) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        try? RecordingLibrary.markTranscript("waiting", model: model.name, in: entry.folder)
        explicit.insert(stamp)
        enqueue(stamp)
        finished(stamp)
    }

    private func enqueue(_ stamp: String) {
        // Already transcribing, live or from the file, or already queued.
        if !working.contains(stamp) {
            queue.append(stamp)
            working.insert(stamp)
        }
        processQueue()
    }

    private func advance(_ stamp: String, fraction: Double, line: String?) {
        guard current == stamp else { return }
        if var now = progress {
            now.fraction = fraction
            now.line = line ?? now.line
            progress = now
        } else {
            progress = Progress(fraction: fraction, line: line, first: (fraction, .now))
        }
    }

    private func processQueue() {
        // Pictures and films show the queue; nothing downloads or runs.
        guard !staged, !processing, let index = queue.firstIndex(where: { enabled || explicit.contains($0) }) else {
            return
        }
        guard let wanted = modelForNow() else {
            // Waiting for the model; a click asks for the download too.
            return fetchIfNeeded()
        }
        let stamp = queue.remove(at: index)
        let (model, loading) = engine(preferring: wanted)
        processing = true
        current = stamp
        let names = model.takesHints ? names() : nil
        Task {
            do {
                let engine: SpeechEngine
                do { engine = try await loading.value } catch {
                    forgetEngine(model)
                    throw error
                }
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                let outcome = try await FolderTranscriber.transcribe(folder: folder, engine: engine, names: names) {
                    fraction, line in
                    Task { @MainActor [weak self] in self?.advance(stamp, fraction: fraction, line: line) }
                }
                // Looked up again: the card may have renamed it meanwhile.
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try TranscriptDocument.save(
                    lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: model, in: folder)
            } catch {
                if let folder = library.folder(withStamp: stamp) {
                    try? RecordingLibrary.markTranscript("failed", model: model.name, error: "\(error)", in: folder)
                }
            }
            explicit.remove(stamp)
            working.remove(stamp)
            processing = false
            current = nil
            progress = nil
            finished(stamp)
            processQueue()
            scheduleUnload()
        }
    }

    /// Moves a waiting recording to the front of the queue: the one the user
    /// opened is the one they want first.
    func prioritize(_ entry: RecordingEntry) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        guard let index = queue.firstIndex(of: stamp), index > 0 else { return }
        queue.insert(queue.remove(at: index), at: 0)
    }

    /// True while a recording is transcribing or will be on its own; one
    /// left waiting while transcripts are off offers Transcribe instead.
    /// How far this recording's transcript has come, while it is being made.
    func progress(of entry: RecordingEntry) -> Progress? {
        current == RecordingLibrary.stamp(of: entry.folder) ? progress : nil
    }

    func isWorking(on entry: RecordingEntry) -> Bool {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        if working.contains(stamp) { return enabled || explicit.contains(stamp) || !queue.contains(stamp) }
        return entry.transcript == .pending && enabled
    }

    /// Set once staged for pictures: the queue then never runs.
    private var staged = false

    /// Puts the row and the live lines in a given state for `TapeUp snapshot`.
    func stage(download: Download, enabled: Bool = true, live: Bool = false, latest: [String] = []) {
        staged = true
        self.download = download
        self.enabled = enabled
        liveRunning = live
        self.latest = latest.enumerated().map { TranscriptLine(start: Double($0.offset), end: 0, text: $0.element) }
    }

    /// Films: shows `stamp` being transcribed this far, or nothing.
    func stage(current stamp: String?, progress: Progress?) {
        current = stamp
        self.progress = progress
    }

    // MARK: - What the panel says

    /// The Transcript row's second line.
    var status: String {
        switch download {
        case .downloading(let bytes) where wantsModel:
            return "Downloading \(model.name) · \(Format.percent(bytes, of: model.downloadBytes))"
        case .ready where enabled:
            let waiting = queue.count + (processing ? 1 : 0)
            return waiting > 0 && !liveRunning
                ? "\(model.name) · \(waiting) to transcribe" : model.name
        case .retrying(let bytes) where wantsModel:
            return "No connection, retrying · \(Format.percent(bytes, of: model.downloadBytes))"
        default:
            return "Off"
        }
    }
}

/// Carries the recorder's audio to the live session, holding it while the
/// model loads. Called on the recorder's data queue.
final class LiveFeed: @unchecked Sendable {
    struct Outcome {
        let lines: [TranscriptLine]
        let failures: Int
        let pieces: Int
        let model: SpeechModel
    }

    private let lock = NSLock()
    private var session: TranscriptSession?
    private var model: SpeechModel?
    private var held: [(left: [Float], right: [Float], headphones: Bool)] = []
    private var heldFrames = 0
    /// True when audio was lost before the session started, or it never did:
    /// the transcript is then made from the file instead.
    private var broken = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var settled = false

    /// Two minutes of audio may wait for the model to load.
    private static let holdLimit = 48_000 * 120

    func feed(left: [Float], right: [Float], headphones: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session.feed(left: left, right: right, headphones: headphones) }
        guard !broken else { return }
        guard heldFrames < Self.holdLimit else {
            broken = true
            held = []
            return
        }
        held.append((left, right, headphones))
        heldFrames += left.count
    }

    func attach(_ session: TranscriptSession) {
        lock.lock()
        if !broken {
            for chunk in held { session.feed(left: chunk.left, right: chunk.right, headphones: chunk.headphones) }
            self.session = session
        }
        held = []
        settle()
        lock.unlock()
    }

    func fail() {
        lock.lock()
        broken = true
        held = []
        settle()
        lock.unlock()
    }

    /// Must hold the lock.
    private func settle() {
        settled = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    var latest: [TranscriptLine]? {
        lock.lock()
        defer { lock.unlock() }
        return session?.latest
    }

    /// True once what is heard live will not make the transcript.
    var isBroken: Bool { lock.withLock { broken || session?.overloaded == true } }

    /// The lines heard, or nil when the transcript must come from the file.
    func finish() async -> Outcome? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if settled {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
        guard let session = lock.withLock({ broken ? nil : session }) else { return nil }
        guard !session.overloaded else {
            session.abandon()
            return nil
        }
        let outcome = await session.finish()
        return Outcome(lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: session.model)
    }
}

/// Passes download progress on at most a few times a second.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let send: @Sendable (Int64) -> Void

    init(send: @escaping @Sendable (Int64) -> Void) { self.send = send }

    func report(_ bytes: Int64) {
        lock.lock()
        let now = Date()
        let due = now.timeIntervalSince(last) > 0.2
        if due { last = now }
        lock.unlock()
        if due { send(bytes) }
    }
}
