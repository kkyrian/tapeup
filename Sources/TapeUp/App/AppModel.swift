import AVFoundation
import AppKit
import Observation
import ServiceManagement
import TapeUpCore
import TapeUpSpeech

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
    private(set) var copiedFlash = false
    private(set) var transcriptCopiedFlash = false
    /// Count copies, so only the latest one's timer ends its flash.
    private var copies = 0
    private var transcriptCopies = 0
    /// Transcripts: the model, live transcription, saved recordings waiting.
    let transcription: Transcription
    /// Speaker labels, made when asked.
    let speakers: Speakers
    /// True when the panel was opened by the user and holds the keyboard, so
    /// a field may take the cursor at once. False after a shortcut stop, so
    /// the card never takes typing away from a call.
    var panelFocused = false
    /// Makes the panel take the keyboard; set by the panel controller.
    var focusPanel: () -> Void = {}

    struct Card: Equatable {
        var entry: RecordingEntry
        /// True while `audio.m4a` is still being written.
        var finishing: Bool
        var copied = false
        var justRecorded: Bool
    }

    /// True while the user is checking levels before recording. Off by
    /// default: listening lights the mic indicator and puts AirPods into
    /// call mode, which opening a menu should never do.
    private(set) var testing = false

    func toggleTesting() {
        testing.toggle()
        guard testing else {
            resetLevels()
            return updateLevelTimer()
        }
        // The first check asks for access, as recording would.
        requestAccess { [weak self] in self?.updateLevelTimer() }
    }

    /// Which sources the next recording takes. Kept across launches; at least
    /// one stays on.
    private(set) var microphoneOn = UserDefaults.standard.object(forKey: "recordMicrophone") as? Bool ?? true
    private(set) var computerOn = UserDefaults.standard.object(forKey: "recordComputer") as? Bool ?? true

    func toggleMicrophone() {
        guard phase == .idle, !(microphoneOn && !computerOn) else { return }
        microphoneOn.toggle()
        UserDefaults.standard.set(microphoneOn, forKey: "recordMicrophone")
        restartMonitor()
    }

    func toggleComputer() {
        guard phase == .idle, !(computerOn && !microphoneOn) else { return }
        computerOn.toggle()
        UserDefaults.standard.set(computerOn, forKey: "recordComputer")
        restartMonitor()
    }

    private func restartMonitor() {
        stopMonitor()
        resetLevels()
        updateLevelTimer()
    }

    /// The last recording moved to the Trash, until it is put back or the panel closes.
    private(set) var trashed: (entry: RecordingEntry, location: URL)?

    var panelVisible = false {
        didSet {
            if !panelVisible {
                testing = false
                trashed = nil
            }
            updateLevelTimer()
            updatePeopleWatch()
        }
    }
    private var peopleWatch: Timer?

    var root: URL {
        didSet {
            UserDefaults.standard.set(root.path, forKey: "recordingsRoot")
            library = RecordingLibrary(root: root)
            transcription.library = library
            speakers.library = library
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
    private let monitor = LevelMonitor()
    private var monitoring = false
    private var activity: NSObjectProtocol?
    private var deviceObservation: AudioDevices.Observation?
    /// Who was there, entered while the recording is still saving.
    private var pendingPeople: (folder: URL, people: RecordingEntry.People)?
    private var pendingTitle: (folder: URL, title: String?)?
    /// The folder being recorded or saved; kept out of Recent until it is final.
    private var activeFolder: URL?
    /// The shortcut shown on the buttons, or nil when another app holds it.
    var shortcutLabel: String? = HotKey.recordShortcutLabel

    init() {
        let saved = UserDefaults.standard.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
        root = saved ?? RecordingLibrary.defaultRoot
        let library = RecordingLibrary(root: saved ?? RecordingLibrary.defaultRoot)
        self.library = library
        transcription = Transcription(library: library)
        speakers = Speakers(library: library)
        refreshAccess()
        deviceObservation = AudioDevices.observeDefaults(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        reload()
        transcription.finished = { [weak self] stamp in self?.transcriptFinished(stamp) }
        transcription.names = { [weak self] in self?.nameHints() }
        speakers.makeRoom = { [weak self] in self?.transcription.releaseIfIdle() ?? true }
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
        stopMonitor()
        let missing = [
            microphoneOn && microphoneAccess == .denied ? "your mic" : nil,
            computerOn && computerAccess == .denied ? "your Mac's audio" : nil,
        ].compactMap { $0 }
        guard missing.isEmpty else {
            problem =
                "TapeUp can't hear \(missing.joined(separator: " or ")). Choose Allow access, turn TapeUp on, then record."
            return
        }
        do {
            let folder = try library.newFolder()
            var options = Recorder.Options(folder: folder)
            options.you = peopleList.you
            options.microphoneOn = microphoneOn
            options.computerOn = computerOn
            let feed = transcription.prepareLive()
            if let feed { options.onAudio = { feed.feed(left: $0, right: $1, headphones: $2) } }
            let recorder = try Recorder(options: options)
            try recorder.start()
            transcription.began(folder: folder, feed: feed, microphone: microphoneOn, computer: computerOn)
            self.recorder = recorder
            activeFolder = folder
            card = nil
            showingPeople = false
            phase = .recording(started: recorder.started)
            testing = false
            elapsed = 0
            paused = false
            pausedTotal = 0
            pausedSince = nil
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording")
            clockTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickClock() }
            }
            updateLevelTimer()
        } catch {
            problem = "Could not start recording: \(error.localizedDescription)"
            updateLevelTimer()
        }
    }

    /// Stops and saves. The card appears at once; the audio finishes in the background.
    func stop(then completion: (@MainActor () -> Void)? = nil) {
        guard case .recording(let started) = phase, let recorder else { return }
        tickClock()
        paused = false
        pausedSince = nil
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
        pendingTitle = nil
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
        activeFolder = nil
        phase = .idle
        updateLevelTimer()
        if case .failure(let error) = outcome {
            problem = "\(error)"
        }
        if let pending = pendingPeople, pending.folder == folder {
            try? RecordingLibrary.save(people: pending.people, in: folder)
            pendingPeople = nil
        }
        var saved = folder
        if let pending = pendingTitle, pending.folder == folder {
            saved = (try? RecordingLibrary.save(title: pending.title, in: folder)) ?? folder
            pendingTitle = nil
        }
        transcription.saved(folder: saved)
        reload()
        if var card, card.entry.folder == folder, let entry = RecordingLibrary.entry(at: saved) {
            card.entry = entry
            card.finishing = false
            self.card = card
        }
    }

    private func tickClock() {
        guard case .recording(let started) = phase else { return }
        let pausedNow = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = Date().timeIntervalSince(started) - pausedTotal - pausedNow
        transcription.refreshLatest()
    }

    /// True while a recording is paused: nothing is added to the file.
    private(set) var paused = false
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: Date?

    func togglePause() {
        guard isRecording, let recorder else { return }
        if paused {
            recorder.resume()
            pausedTotal += pausedSince.map { Date().timeIntervalSince($0) } ?? 0
            pausedSince = nil
        } else {
            recorder.pause()
            pausedSince = Date()
        }
        paused.toggle()
        tickClock()
    }

    /// Whether the small recording controls float over other windows while recording.
    var showsFloatingControls = UserDefaults.standard.object(forKey: "floatingControls") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsFloatingControls, forKey: "floatingControls") }
    }

    // MARK: - Levels

    /// Levels move whenever the panel is open: from the recorder while
    /// recording, otherwise from a monitor that listens without recording.
    private func updateLevelTimer() {
        let wanted = panelVisible && (isRecording || testing)
        if panelVisible, testing, phase == .idle { startMonitor() } else { stopMonitor() }
        if wanted, levelTimer == nil {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tickLevels() }
            }
        } else if !wanted {
            levelTimer?.invalidate()
            levelTimer = nil
            if !isRecording { resetLevels() }
        }
    }

    private var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    private func startMonitor() {
        guard !monitoring else { return }
        let microphone = microphoneOn && microphoneAccess == .granted
        let computer = computerOn && computerAccess == .granted
        guard microphone || computer else { return }
        monitoring = true
        monitor.start(microphone: microphone, computer: computer)
    }

    private func stopMonitor() {
        guard monitoring else { return }
        monitoring = false
        monitor.stop()
    }

    private func tickLevels() {
        guard let recorder else {
            let peaks = monitor.take()
            push(&microphoneLevels, Self.meter(peaks.microphone))
            push(&computerLevels, Self.meter(peaks.computer))
            return
        }
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
        allEntries = library.entries().filter { $0.folder != activeFolder }
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
        let merged = currentPeopleFile().merged(with: list)
        do {
            try library.prepareRoot()
            try merged.save(to: root)
            loadPeople()
            peopleNotice = .added(peopleList.people.count - before)
        } catch {
            problem = "Could not save the people list: \(error.localizedDescription)"
        }
    }

    /// The list as it is on disk now, which an assistant may have just
    /// changed. A file that cannot be read is set aside, never overwritten.
    private func currentPeopleFile() -> PeopleList {
        do {
            return try PeopleList.loadChecked(from: root)
        } catch {
            if let aside = try? PeopleList.setAsideUnreadable(in: root) {
                problem = "The old people list couldn't be read, so it was kept as \(aside.lastPathComponent)."
            }
            return PeopleList()
        }
    }

    func removePerson(_ name: String) {
        var list = currentPeopleFile()
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
        let library = library
        let launched = Date()
        Task.detached(priority: .utility) {
            AudioDevices.removeLeftovers()
            let folders = library.recordingFolders()
            for folder in folders { _ = try? Recorder.recover(folder: folder, startedBefore: launched) }
            Speakers.clearInterrupted(folders)
            await MainActor.run { [weak self] in
                guard let self else { return }
                reload()
                transcription.start(pending: allEntries)
            }
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
        guard card?.entry.folder == entry.folder else { return }
        card?.copied = true
        // The button says Copied for a moment; the copied lines stay.
        copiedFlash = true
        copies += 1
        let copy = copies
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copies == copy { self?.copiedFlash = false }
        }
    }

    /// Copies the transcript's text, the labeled one once it exists.
    func copyTranscript(_ entry: RecordingEntry) {
        let labeled = entry.folder.appendingPathComponent(SpeakerLabels.fileName)
        let file = FileManager.default.fileExists(atPath: labeled.path) ? labeled : entry.transcriptFile
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            problem = "Could not read the transcript."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        transcriptCopiedFlash = true
        transcriptCopies += 1
        let copy = transcriptCopies
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.transcriptCopies == copy { self?.transcriptCopiedFlash = false }
        }
    }

    /// Makes a transcript for a recording without one, or tries a failed one again.
    func makeTranscript(_ entry: RecordingEntry) { transcription.make(entry) }

    /// A transcript was written or failed: refresh the list and the open card.
    private func transcriptFinished(_ stamp: String) {
        reload()
        guard let card, RecordingLibrary.stamp(of: card.entry.folder) == stamp, !card.finishing,
            let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder)
        else { return }
        self.card?.entry = entry
    }

    /// Names and terms for the speech model: the people list, who was at
    /// recent recordings, and distinctive words from titles.
    private func nameHints() -> String? {
        let recent = allEntries.prefix(100)
        return NameHints.make(
            names: peopleList.allNames + recent.flatMap(\.people.names), titles: recent.compactMap(\.title))
    }

    /// Moves a recording's folder to the Trash, where it can still be restored.
    func trash(_ entry: RecordingEntry) {
        do {
            var location: NSURL?
            try FileManager.default.trashItem(at: entry.folder, resultingItemURL: &location)
            if card?.entry.folder == entry.folder { card = nil }
            trashed = location.map { (entry, $0 as URL) }
            reload()
        } catch {
            problem = "Could not move the recording to the Trash: \(error.localizedDescription)"
        }
    }

    /// Switches the recordings folder; with `moving`, the recordings already
    /// made go along. Never while recording, so no folder is mid-write.
    func changeRoot(to destination: URL, moving: Bool) {
        guard phase == .idle, destination.standardizedFileURL != root.standardizedFileURL else { return }
        guard moving else {
            root = destination
            return
        }
        let library = library
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try library.move(to: destination) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                root = destination
                switch outcome {
                case .success(let result) where !result.skipped.isEmpty:
                    problem =
                        "\(result.skipped.count) recording\(result.skipped.count == 1 ? "" : "s") stayed in \(library.root.lastPathComponent): the new folder already has one with the same name."
                case .failure(let error):
                    problem = "Some recordings could not be moved: \(error.localizedDescription)"
                default: break
                }
            }
        }
    }

    /// Puts the last trashed recording back where it was.
    func undoTrash() {
        guard let trashed else { return }
        self.trashed = nil
        do {
            try FileManager.default.moveItem(at: trashed.location, to: trashed.entry.folder)
            reload()
        } catch {
            problem = "Could not put the recording back: \(error.localizedDescription)"
        }
    }

    func reveal(_ entry: RecordingEntry) {
        let target = FileManager.default.fileExists(atPath: entry.audio.path) ? entry.audio : entry.folder
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openRoot() {
        try? library.prepareRoot()
        NSWorkspace.shared.open(root)
    }

    /// Labels the open recording's speakers: as many voices as the count
    /// says, or the estimate without one.
    func labelSpeakers() {
        guard let entry = card?.entry else { return }
        speakers.label(entry, count: entry.people.count)
    }

    func setPeople(_ people: RecordingEntry.People) {
        guard var card else { return }
        // Labels already made follow the count.
        if people.count != card.entry.people.count, speakers.started(card.entry) {
            speakers.label(card.entry, count: people.count)
        }
        card.entry.people = people
        self.card = card
        if card.entry.folder == activeFolder {
            pendingPeople = (card.entry.folder, people)
            return
        }
        do {
            try RecordingLibrary.save(people: people, in: card.entry.folder)
            reload()
        } catch {
            problem = "Could not save who was there: \(error.localizedDescription)"
        }
    }

    /// Names the open recording; the folder keeps its dated name.
    /// True while the card's title is being edited.
    var renaming = false

    func setTitle(_ title: String) {
        guard var card else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        card.entry.title = trimmed.isEmpty ? nil : trimmed
        self.card = card
        if card.entry.folder == activeFolder {
            pendingTitle = (card.entry.folder, card.entry.title)
            return
        }
        do {
            let folder = try RecordingLibrary.save(title: trimmed, in: card.entry.folder)
            if let entry = RecordingLibrary.entry(at: folder) { self.card?.entry = entry }
            reload()
        } catch {
            problem = "Could not save the title: \(error.localizedDescription)"
        }
    }

    func suggestions(matching query: String, excluding chosen: [String], limit: Int = 6) -> [String] {
        suggester.suggestions(matching: query, excluding: chosen, limit: limit)
    }

    func knownSpelling(of name: String) -> String? { suggester.knownSpelling(of: name) }

    /// True once there is anything to suggest from.
    var hasSuggestionSource: Bool { !peopleList.people.isEmpty || allEntries.contains { !$0.people.names.isEmpty } }

    func dismissProblem() { problem = nil }

    func clearPeopleNotice() { if peopleNotice != .copied { peopleNotice = nil } }

    /// Puts the model in a given state for `TapeUp snapshot`, which renders
    /// the panel offscreen so its design can be checked without recording.
    func stage(
        phase: Phase, elapsed: TimeInterval = 0, microphone: String, output: String, levels: ([Float], [Float])? = nil,
        notice: PeopleNotice? = nil, problem: String? = nil, testing: Bool = false
    ) {
        self.phase = phase
        self.testing = testing
        self.elapsed = elapsed
        microphoneDevice = microphone
        outputDevice = output
        microphoneLevels = levels?.0 ?? [Float](repeating: 0, count: Self.laneLength)
        computerLevels = levels?.1 ?? [Float](repeating: 0, count: Self.laneLength)
        microphoneAccess = .granted
        computerAccess = .granted
        peopleNotice = notice
        self.problem = problem
    }
}
