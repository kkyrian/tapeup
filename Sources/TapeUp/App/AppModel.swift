import AVFoundation
import AppKit
import Observation
import ServiceManagement
import TapeUpCore

/// Everything the panel and the menu-bar item show, and the actions behind them.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case recording(started: Date)
        case saving(started: Date)
    }

    enum Access: Equatable { case unknown, granted, denied }

    /// Number of bars in a lane.
    static let laneLength = 44

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var microphoneDevice = AudioDevices.defaultInputName()
    private(set) var outputDevice = AudioDevices.defaultOutputName()
    private(set) var microphoneLevels = [Float](repeating: 0, count: laneLength)
    private(set) var computerLevels = [Float](repeating: 0, count: laneLength)
    private(set) var microphoneAccess: Access = .unknown
    private(set) var computerAccess: Access = .unknown
    private(set) var recent: [RecordingEntry] = []
    private(set) var allEntries: [RecordingEntry] = []
    private(set) var problem: String?
    private(set) var peopleList = PeopleList()
    private var suggester = NameSuggester(entries: [], people: PeopleList())
    private var peopleModified: Date?

    /// The page in place of the recorder: who you record with, set up with your AI.
    var showingPeople = false
    /// What the people page reports after a copy, a paste or the file changing.
    private(set) var peopleNotice: PeopleNotice?

    enum PeopleNotice: Equatable {
        case copied
        case added(Int)
        case pasteFailed
    }

    /// The card on screen: the recording just saved, or one opened from Recent.
    var card: Card?

    struct Card: Equatable {
        var entry: RecordingEntry
        /// True while `audio.m4a` is still being written.
        var finishing: Bool
        var copied = false
        var justRecorded: Bool
    }

    var panelVisible = false {
        didSet {
            updateLevelTimer()
            updatePeopleWatch()
        }
    }
    private var peopleWatch: Timer?

    var root: URL {
        didSet {
            UserDefaults.standard.set(root.path, forKey: "recordingsRoot")
            library = RecordingLibrary(root: root)
            reload()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                problem = "Could not change Open at Login: \(error.localizedDescription)"
            }
            launchAtLoginRevision += 1
        }
    }
    /// Bumped so views reading `launchAtLogin` refresh after a change.
    private(set) var launchAtLoginRevision = 0

    /// Called when a recording stops by shortcut or quit, so the panel can show its card.
    var onSaved: (() -> Void)?

    private var library: RecordingLibrary
    private var recorder: Recorder?
    private var clockTimer: Timer?
    private var levelTimer: Timer?
    private var activity: NSObjectProtocol?
    private var deviceObservation: AudioDevices.Observation?
    private var pendingPeople: RecordingEntry.People?

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
        root = saved ?? RecordingLibrary.defaultRoot
        library = RecordingLibrary(root: saved ?? RecordingLibrary.defaultRoot)
        refreshAccess()
        deviceObservation = AudioDevices.observeDefaults(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        reload()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: - Recording

    func toggle() {
        switch phase {
        case .idle: start()
        case .recording: stop()
        case .saving: break
        }
    }

    func start() {
        guard phase == .idle else { return }
        problem = nil
        requestAccess { [weak self] in self?.begin() }
    }

    private func begin() {
        guard phase == .idle else { return }
        do {
            let folder = try library.newFolder()
            var options = Recorder.Options(folder: folder)
            options.you = peopleList.you
            let recorder = try Recorder(options: options)
            try recorder.start()
            self.recorder = recorder
            card = nil
            showingPeople = false
            phase = .recording(started: recorder.started)
            elapsed = 0
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording")
            clockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickClock() }
            }
            updateLevelTimer()
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Stops and saves. The card appears at once; the audio finishes in the background.
    func stop(then completion: (@MainActor () -> Void)? = nil) {
        guard case .recording(let started) = phase, let recorder else { return }
        phase = .saving(started: started)
        clockTimer?.invalidate()
        clockTimer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        resetLevels()
        updateLevelTimer()
        let folder = recorder.options.folder
        card = Card(
            entry: RecordingEntry(
                folder: folder, started: started, duration: elapsed, audio: folder.appendingPathComponent("audio.m4a"),
                status: "recording", people: .init()),
            finishing: true, justRecorded: true)
        pendingPeople = nil
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try recorder.stop() }
            await MainActor.run { [weak self] in
                self?.finishedSaving(folder: folder, outcome: outcome)
                completion?()
            }
        }
    }

    private func finishedSaving(folder: URL, outcome: Result<Recorder.Result, Error>) {
        recorder = nil
        phase = .idle
        if case .failure(let error) = outcome {
            problem = "\(error)"
        }
        if let people = pendingPeople {
            try? RecordingLibrary.save(people: people, in: folder)
            pendingPeople = nil
        }
        reload()
        if var card, card.entry.folder == folder, let entry = RecordingLibrary.entry(at: folder) {
            card.entry = entry
            card.finishing = false
            self.card = card
        }
    }

    private func tickClock() {
        guard case .recording(let started) = phase else { return }
        elapsed = Date().timeIntervalSince(started)
    }

    // MARK: - Levels

    private func updateLevelTimer() {
        let wanted = panelVisible && isRecording
        if wanted, levelTimer == nil {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickLevels() }
            }
        } else if !wanted {
            levelTimer?.invalidate()
            levelTimer = nil
        }
    }

    private func tickLevels() {
        guard let recorder else { return }
        let live = recorder.takeLive()
        push(&microphoneLevels, Self.meter(live.microphoneLevel))
        push(&computerLevels, Self.meter(live.computerLevel))
        if !live.microphone.isEmpty, live.microphone != microphoneDevice { microphoneDevice = live.microphone }
        if !live.output.isEmpty, live.output != outputDevice { outputDevice = live.output }
    }

    private func push(_ levels: inout [Float], _ value: Float) {
        levels.removeFirst()
        levels.append(value)
    }

    private func resetLevels() {
        microphoneLevels = .init(repeating: 0, count: Self.laneLength)
        computerLevels = .init(repeating: 0, count: Self.laneLength)
    }

    /// Peak amplitude to bar height: -54 dBFS and below is flat, 0 dBFS is full.
    static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return min(1, max(0, (db + 54) / 54))
    }

    // MARK: - Devices and access

    private func refreshDevices() {
        guard !isRecording else { return }
        microphoneDevice = AudioDevices.defaultInputName()
        outputDevice = AudioDevices.defaultOutputName()
    }

    func refreshAccess() {
        microphoneAccess =
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied, .restricted: .denied
            default: .unknown
            }
        computerAccess =
            switch AudioCapturePermission.status() {
            case .authorized: .granted
            case .denied: .denied
            case .unknown: .unknown
            }
        refreshDevices()
    }

    private func requestAccess(then: @escaping @MainActor () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            let finish: @Sendable () -> Void = {
                Task { @MainActor in
                    self?.refreshAccess()
                    then()
                }
            }
            guard AudioCapturePermission.status() != .authorized else { return finish() }
            AudioCapturePermission.request { _ in finish() }
        }
    }

    func openPrivacySettings(for track: String) {
        let pane = track == "microphone" ? "Privacy_Microphone" : "Privacy_AudioCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Library

    func reload() {
        allEntries = library.entries()
        recent = Array(allEntries.prefix(5))
        loadPeople()
    }

    private func loadPeople() {
        peopleModified = Self.modified(PeopleList.url(in: root))
        peopleList = PeopleList.load(from: root)
        suggester = NameSuggester(entries: allEntries, people: peopleList)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// While the panel is open, notice an assistant writing `people.json`.
    private func updatePeopleWatch() {
        if panelVisible, peopleWatch == nil {
            peopleWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPeopleFile() }
            }
        } else if !panelVisible {
            peopleWatch?.invalidate()
            peopleWatch = nil
        }
    }

    private func checkPeopleFile() {
        let modified = Self.modified(PeopleList.url(in: root))
        guard modified != peopleModified else { return }
        let before = peopleList.people.count
        loadPeople()
        if showingPeople || peopleList.people.count != before {
            peopleNotice = .added(max(0, peopleList.people.count - before))
        }
    }

    // MARK: - People

    func copyAssistantPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PeopleList.assistantPrompt(root: root), forType: .string)
        peopleNotice = .copied
    }

    /// Reads the assistant's answer from the clipboard and adds its people.
    func pasteAssistantAnswer() {
        guard let text = NSPasteboard.general.string(forType: .string), let list = try? PeopleList.parse(text) else {
            peopleNotice = .pasteFailed
            return
        }
        let before = peopleList.people.count
        let merged = peopleList.merged(with: list)
        do {
            try library.prepareRoot()
            try merged.save(to: root)
            loadPeople()
            peopleNotice = .added(peopleList.people.count - before)
        } catch {
            problem = "Could not save the people list: \(error.localizedDescription)"
        }
    }

    func removePerson(_ name: String) {
        var list = peopleList
        list.remove(name)
        try? list.save(to: root)
        loadPeople()
    }

    func openPeople() {
        card = nil
        peopleNotice = nil
        showingPeople = true
    }

    func closePeople() {
        showingPeople = false
        peopleNotice = nil
    }

    /// Finishes recordings a crash left behind, then refreshes the list.
    func recoverLeftovers() {
        let root = self.root
        Task.detached(priority: .utility) {
            let folders =
                (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            var recovered = false
            for folder in folders {
                if (try? Recorder.recover(folder: folder)) == true { recovered = true }
            }
            if recovered { await MainActor.run { [weak self] in self?.reload() } }
        }
    }

    func open(_ entry: RecordingEntry) {
        showingPeople = false
        card = Card(entry: entry, finishing: false, justRecorded: false)
    }

    func closeCard() { card = nil }

    func copy(_ entry: RecordingEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.clipboardText, forType: .string)
        if card?.entry.folder == entry.folder { card?.copied = true }
    }

    func reveal(_ entry: RecordingEntry) {
        let target = FileManager.default.fileExists(atPath: entry.audio.path) ? entry.audio : entry.folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openRoot() {
        try? library.prepareRoot()
        NSWorkspace.shared.open(root)
    }

    func setPeople(_ people: RecordingEntry.People) {
        guard var card else { return }
        card.entry.people = people
        self.card = card
        if card.finishing {
            pendingPeople = people
            return
        }
        do {
            try RecordingLibrary.save(people: people, in: card.entry.folder)
            reload()
        } catch {
            problem = "Could not save who was there: \(error.localizedDescription)"
        }
    }

    func suggestions(matching query: String, excluding chosen: [String], limit: Int = 6) -> [String] {
        suggester.suggestions(matching: query, excluding: chosen, limit: limit)
    }

    func knownSpelling(of name: String) -> String? { suggester.knownSpelling(of: name) }

    /// True once there is anything to suggest from.
    var hasSuggestionSource: Bool { !peopleList.people.isEmpty || allEntries.contains { !$0.people.names.isEmpty } }

    func dismissProblem() { problem = nil }

    /// Puts the model in a given state for `TapeUp snapshot`, which renders
    /// the panel offscreen so its design can be checked without recording.
    func stage(
        phase: Phase, elapsed: TimeInterval = 0, microphone: String, output: String, levels: ([Float], [Float])? = nil,
        notice: PeopleNotice? = nil, problem: String? = nil
    ) {
        self.phase = phase
        self.elapsed = elapsed
        microphoneDevice = microphone
        outputDevice = output
        if let levels {
            microphoneLevels = levels.0
            computerLevels = levels.1
        }
        microphoneAccess = .granted
        computerAccess = .granted
        peopleNotice = notice
        self.problem = problem
    }
}
