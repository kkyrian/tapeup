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

    /// Puts a line on the recorder page that the user dismisses.
    func show(problem text: String) { problem = text }
    private(set) var peopleList = PeopleList()
    private var suggester = NameSuggester(entries: [], people: PeopleList())
    private var peopleModified: Date?

    /// The page in place of the recorder: who you record with.
    var showingPeople = false
    /// The People page opens on its Fill from your AI steps.
    private(set) var peopleOpensFilling = false
    /// The page in place of the recorder: the folder, your AI and the app.
    var showingSettings = false
    /// The page in place of the recorder: every recording, to browse and search.
    var showingAllRecordings = false
    /// What that page is narrowed to, kept while a card opened from it is up.
    var recordingsFilter = RecordingFilter()
    /// The page in place of the recorder: recordings that still hold audio, to clear it.
    var showingFreeUpSpace = false
    /// What Free up space shows: an age, or the kept recordings.
    var spaceFilter = SpaceFilter()
    /// Audio Free up space just moved to the Trash, by stamp, until Undo or the panel closes.
    var freedAudio: [String: URL]?
    /// Recordings with no transcript Free up space just moved to the Trash.
    var freedRecordings: [(entry: RecordingEntry, location: URL)]?
    /// The stamp of the recording last opened from the page, scrolled back into view on return.
    var recordingsAnchor: String?
    /// The transcripts' text for that page's search.
    let transcriptIndex = TranscriptIndex()
    /// What the people page reports after a copy, a paste or the file changing.
    private(set) var peopleNotice: PeopleNotice?

    enum PeopleNotice: Equatable {
        case copied
        case added(Int)
        case pasteFailed
        /// A name typed by hand is already on the list.
        case taken(String)
    }

    /// The card on screen: the recording just saved, or one opened from Recent.
    var card: Card? {
        // A voice playing stops with its card, the panel closing included; a rename keeps the stamp.
        didSet {
            let stamp = { (card: Card?) in card.map { RecordingLibrary.stamp(of: $0.entry.folder) } }
            if stamp(card) != stamp(oldValue) {
                speakers.player.stop()
                speakers.clearOffer()
                removedAudio = nil
            }
        }
    }
    private(set) var copiedFlash = false
    private(set) var transcriptCopiedFlash = false
    /// Count copies, so only the latest one's timer ends its flash.
    private var copies = 0
    private var transcriptCopies = 0
    /// Transcripts: the model, live transcription, saved recordings waiting.
    let transcription: Transcription
    /// Speaker labels, made when asked.
    let speakers: Speakers
    /// Suggested titles from the user's agent or the on-device model.
    let titles: Titles
    /// The user's own Claude Code or Codex, when picked in ···.
    let agents = Agents()
    /// True when the panel was opened by the user and holds the keyboard, so
    /// a field may take the cursor at once. False after a shortcut stop, so
    /// the card never takes typing away from a call.
    var panelFocused = false
    /// Makes the panel take the keyboard; set by the panel controller.
    var focusPanel: () -> Void = {}
    /// Opens the panel under the menu-bar icon.
    var showPanel: () -> Void = {}
    /// Check for Updates…; nil in a build that cannot update (no release key).
    var checkForUpdates: (() -> Void)?
    /// The Automatic updates switch: a daily check, installed when idle.
    var automaticUpdates = true {
        didSet { setAutomaticUpdates?(automaticUpdates) }
    }
    var setAutomaticUpdates: ((Bool) -> Void)?
    /// The version an update just brought, for the one line that says so.
    var updatedTo: String?

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
    private(set) var microphoneOn = Settings.store.object(forKey: "recordMicrophone") as? Bool ?? true
    private(set) var computerOn = Settings.store.object(forKey: "recordComputer") as? Bool ?? true

    func toggleMicrophone() {
        guard phase == .idle, !(microphoneOn && !computerOn) else { return }
        microphoneOn.toggle()
        Settings.store.set(microphoneOn, forKey: "recordMicrophone")
        restartMonitor()
    }

    func toggleComputer() {
        guard phase == .idle, !(computerOn && !microphoneOn) else { return }
        computerOn.toggle()
        Settings.store.set(computerOn, forKey: "recordComputer")
        restartMonitor()
    }

    private func restartMonitor() {
        stopMonitor()
        resetLevels()
        updateLevelTimer()
    }

    /// The last recording moved to the Trash, until it is put back or the panel closes.
    private(set) var trashed: (entry: RecordingEntry, location: URL)?
    /// The open recording's audio, just moved to the Trash, until it is put
    /// back, another recording opens or the panel closes.
    private(set) var removedAudio: (stamp: String, location: URL)?

    var panelVisible = false {
        didSet {
            if !panelVisible {
                testing = false
                trashed = nil
                removedAudio = nil
                freedAudio = nil
                freedRecordings = nil
            }
            updateLevelTimer()
            updatePeopleWatch()
        }
    }
    private var peopleWatch: Timer?

    var root: URL {
        didSet {
            Settings.store.set(root.path, forKey: "recordingsRoot")
            library = RecordingLibrary(root: root)
            transcription.library = library
            speakers.library = library
            titles.library = library
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

    private(set) var library: RecordingLibrary
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
    private(set) var activeFolder: URL?
    /// True while recordings move to another folder, so a second move waits.
    private(set) var movingRecordings = false
    /// The shortcut shown on the buttons, or nil when another app holds it.
    var shortcutLabel: String? = HotKey.recordShortcutLabel

    init() {
        let saved = Settings.store.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
        root = saved ?? RecordingLibrary.defaultRoot
        let library = RecordingLibrary(root: saved ?? RecordingLibrary.defaultRoot)
        self.library = library
        transcription = Transcription(library: library)
        speakers = Speakers(library: library)
        titles = Titles(library: library)
        speakers.showProblem = { [weak self] in self?.show(problem: $0) }
        refreshAccess()
        deviceObservation = AudioDevices.observeDefaults(queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        reload()
        transcription.showProblem = { [weak self] in self?.show(problem: $0) }
        transcription.finished = { [weak self] stamp in self?.transcriptFinished(stamp) }
        transcription.names = { [weak self] in self?.nameHints() }
        speakers.makeRoom = { [weak self] in self?.transcription.releaseIfIdle() ?? true }
        titles.named = { [weak self] stamp, title in self?.nameIfUnnamed(stamp, title) }
        titles.agents = agents
        speakers.namesChanged = { [weak self] stamp in
            // Who was there and the people list were written with the name.
            self?.voicesRevision += 1
            self?.loadPeople()
            self?.refreshQuietly(stamp)
        }
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
        // The computer-audio tap would hear a voice still playing.
        speakers.player.stop()
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
            showingSettings = false
            showingAllRecordings = false
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
        // The saved card shows, whichever page was open.
        showingPeople = false
        showingSettings = false
        showingAllRecordings = false
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
            // The transcript may have finished while the audio was saving.
            titles.suggest(for: entry, agent: true)
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
    var showsFloatingControls = Settings.store.object(forKey: "floatingControls") as? Bool ?? true {
        didSet { Settings.store.set(showsFloatingControls, forKey: "floatingControls") }
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
        // The durable journal is the only source of pending identity changes.
        finishPendingRenames()
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

    /// Takes a person off the list; their remembered voice goes with them.
    /// Past recordings keep their name: they were there.
    func removePerson(_ name: String) {
        do {
            try VoiceLibrary(root: root).forgetPerson(name)
            voicesRevision += 1
            loadPeople()
            reload()
        } catch {
            show(problem: "Could not remove the person: \(error.localizedDescription)")
        }
    }

    /// Bumped when the remembered voices are forgotten, so Settings redraws.
    private var voicesRevision = 0

    /// How many people's voices are remembered.
    var voicesRemembered: Int {
        _ = voicesRevision
        return VoiceStore.count(in: root)
    }

    /// Forgets every remembered voice; names already given stay.
    func forgetAllVoices() {
        var voices = VoiceStore.load(from: root)
        voices.forgetAll()
        do {
            try voices.save(to: root)
        } catch {
            problem = "Could not forget the voices: \(error.localizedDescription)"
        }
        voicesRevision += 1
    }

    /// The last rename everywhere, until Undo or the People page closes.
    private(set) var lastRename: (from: String, to: String, recordings: Int, undo: VoiceFileUndo)?
    /// A rename onto a name already listed, waiting for Merge or Cancel.
    private(set) var mergeAsk: (from: String, into: String, note: String?)?

    /// Recordings being written, transcribed or labeled right now.
    private var busyStamps: Set<String> {
        var busy = transcription.working.union(speakers.busy)
        if let activeFolder { busy.insert(RecordingLibrary.stamp(of: activeFolder)) }
        return busy
    }

    /// Renames a person in the list and every recording at once. False,
    /// with the reason on the recorder page, when it could not.
    private func renameEverywhere(_ old: String, to new: String) -> Bool {
        do {
            let result = try VoiceLibrary(root: root).renamePerson(old, to: new, busy: busyStamps)
            lastRename = (old, new, result.changedRecordings.count, result.undo)
            if let problem = result.problem { show(problem: problem) }
            loadPeople()
            reload()
            if let card { refreshQuietly(RecordingLibrary.stamp(of: card.entry.folder)) }
            return true
        } catch {
            show(problem: "Could not rename \(old): \(error.localizedDescription)")
            return false
        }
    }

    /// Called by reload(), including the launch reload. A completed or undone
    /// rename cannot be recreated from a separate in-memory catch-up list.
    private func finishPendingRenames() {
        do {
            for result in try VoiceLibrary(root: root).finishPendingRenames(busy: busyStamps) {
                if let problem = result.problem { show(problem: problem) }
            }
        } catch {
            show(problem: "Could not finish pending renames: \(error.localizedDescription)")
        }
    }

    func undoRename() {
        guard let lastRename else { return }
        do {
            let result = try lastRename.undo.restore(busy: busyStamps)
            if let problem = result.problem { show(problem: problem) } else { self.lastRename = nil }
        } catch {
            show(problem: "Could not undo the rename: \(error.localizedDescription)")
        }
        loadPeople()
        reload()
        if let card { refreshQuietly(RecordingLibrary.stamp(of: card.entry.folder)) }
    }

    /// Merges the person being renamed into the one already listed.
    func confirmMerge() {
        guard let ask = mergeAsk else { return }
        mergeAsk = nil
        guard renameEverywhere(ask.from, to: ask.into) else { return }
        if let note = ask.note, !note.isEmpty {
            changePeople { list in
                guard let person = list.people.first(where: { $0.name == ask.into }), person.context == nil else {
                    return true
                }
                return list.update(ask.into, to: .init(name: ask.into, context: note))
            }
        }
    }

    func cancelMerge() { mergeAsk = nil }

    func clearRenameNotice() {
        lastRename = nil
        mergeAsk = nil
    }

    /// Adds a person typed by hand. False when the name is already listed.
    @discardableResult
    func addPerson(_ name: String, note: String?) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let added = changePeople { list in
            guard !list.contains(name) else { return false }
            list.add(.init(name: name, context: note))
            return true
        }
        if !added { peopleNotice = .taken(name) }
        return added
    }

    /// Renames a person or changes their note; an empty name keeps the old
    /// one. A new name is written everywhere the person appears, with Undo;
    /// a name someone else has asks to merge them first, and returns false
    /// until then. A person no longer in the file (an assistant rewrote it)
    /// ends the edit with nothing saved.
    @discardableResult
    func updatePerson(_ name: String, to newName: String, note: String?) -> Bool {
        var trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { trimmed = name }
        let list = currentPeopleFile()
        guard let person = list.people.first(where: { $0.name == name }) else {
            loadPeople()
            return true
        }
        if trimmed != name {
            if let existing = list.allNames.first(where: {
                $0 != name && $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                mergeAsk = (name, existing, note)
                return false
            }
            guard renameEverywhere(name, to: trimmed) else { return false }
        }
        if (note ?? "") != (person.context ?? "") {
            changePeople { $0.update(trimmed, to: .init(name: trimmed, context: note)) }
        }
        return true
    }

    /// Sets the user's own name; empty clears it.
    @discardableResult
    func setYou(_ name: String) -> Bool {
        // A new spelling of you is a rename, everywhere you appear.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = currentPeopleFile()
        if let you = list.you, !trimmed.isEmpty, trimmed != you,
            !list.allNames.contains(where: { $0 != you && $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        {
            return renameEverywhere(you, to: trimmed)
        }
        let set = changePeople { $0.setYou(name) }
        if !set { peopleNotice = .taken(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return set
    }

    /// Changes the list as it is on disk now and saves it; a refused
    /// change saves nothing.
    @discardableResult
    private func changePeople(_ change: (inout PeopleList) -> Bool) -> Bool {
        var list = currentPeopleFile()
        let before = list
        guard change(&list) else {
            loadPeople()
            return false
        }
        guard list != before else { return true }
        do {
            try library.prepareRoot()
            try list.save(to: root)
        } catch {
            problem = "Could not save the people list: \(error.localizedDescription)"
        }
        loadPeople()
        return true
    }

    /// People, with the steps for filling it from your AI open when asked
    /// from a recording that has no names to suggest yet.
    func openPeople(filling: Bool = false) {
        // A card still saving comes back when the page closes.
        if card?.finishing != true { card = nil }
        peopleNotice = nil
        peopleOpensFilling = filling
        showingSettings = false
        showingFreeUpSpace = false
        showingAllRecordings = false
        showingPeople = true
    }

    func openSettings() {
        if card?.finishing != true { card = nil }
        showingPeople = false
        showingFreeUpSpace = false
        showingAllRecordings = false
        showingSettings = true
        agents.refresh()
    }

    func openAllRecordings() {
        if card?.finishing != true { card = nil }
        showingPeople = false
        showingFreeUpSpace = false
        showingSettings = false
        recordingsFilter = RecordingFilter()
        recordingsAnchor = nil
        showingAllRecordings = true
    }

    func closeAllRecordings() {
        showingAllRecordings = false
        recordingsAnchor = nil
    }

    /// One click for every recording shown without a transcript: each joins
    /// the queue, which makes them one after another.
    func makeTranscripts(_ entries: [RecordingEntry]) {
        let waiting = entries.filter { !transcription.isWorking(on: $0) }
        guard !waiting.isEmpty else { return }
        for entry in waiting { transcription.make(entry, announce: false) }
        reload()
    }

    func closeSettings() {
        showingSettings = false
    }

    func closePeople() {
        showingPeople = false
        peopleNotice = nil
        clearRenameNotice()
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
        showingSettings = false
        if showingAllRecordings { recordingsAnchor = RecordingLibrary.stamp(of: entry.folder) }
        card = Card(entry: entry, finishing: false, justRecorded: false)
        titles.suggest(for: entry, agent: true)
    }

    /// A made title, given unless the user named the recording or is
    /// typing a name for it right now.
    private func nameIfUnnamed(_ stamp: String, _ title: String) {
        guard let folder = library.folder(withStamp: stamp), RecordingLibrary.entry(at: folder)?.title == nil else {
            return
        }
        if renaming, let card, RecordingLibrary.stamp(of: card.entry.folder) == stamp { return }
        if folder == activeFolder {
            pendingTitle = pendingTitle ?? (folder, title)
            return
        }
        _ = try? RecordingLibrary.save(title: title, in: folder)
        refreshCard(stamp)
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
        refreshCard(stamp)
        if let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder) {
            // The user's agent only for the recording on the card.
            let atCard = card.map { RecordingLibrary.stamp(of: $0.entry.folder) == stamp } ?? false
            titles.suggest(for: entry, agent: atCard)
            // Speakers are labeled with every transcript, so no one has to ask;
            // an import follows its own switch, and names its voices after.
            let imported = RecordingImport.isImported(folder)
            if entry.transcript == .done, !speakers.started(entry),
                !imported || RecordingImport.wantsSpeakerLabels(folder)
            {
                speakers.label(entry, count: entry.people.count)
            }
        }
    }

    // MARK: - Import

    /// Opens the import window, with any files dropped on the menu-bar icon.
    var openImport: ([URL]) -> Void = { _ in }

    var importLibrary: RecordingLibrary { library }

    /// Copies one file in and starts its transcript when asked; returns the
    /// new recording's stamp, which finds it after a rename.
    @discardableResult
    func importRecording(
        _ candidate: RecordingImport.Candidate, transcribe: Bool, labelSpeakers: Bool, voices: Int?,
        title: String? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> String {
        let plan = RecordingImport.Plan(
            transcribe: transcribe, labelSpeakers: labelSpeakers, people: .init(count: voices), title: title)
        let copy = try await importRecording(candidate, plan: plan, progress: progress)
        return RecordingLibrary.stamp(of: copy.folder)
    }

    func importRecording(
        _ candidate: RecordingImport.Candidate, plan: RecordingImport.Plan,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (folder: URL, imported: Bool) {
        let copy = try await RecordingImport.copyOnce(candidate, into: library, plan: plan, progress: progress)
        reload()
        if copy.imported, plan.transcribe, let entry = RecordingLibrary.entry(at: copy.folder) {
            transcription.make(entry)
        }
        return copy
    }

    /// Shows an imported recording in the panel; one still waiting for its
    /// transcript is transcribed next.
    func showImported(_ stamp: String) {
        guard let entry = importedEntry(stamp) else { return }
        // The panel first: showing it closes a card left from before.
        showPanel()
        open(entry)
        transcription.prioritize(entry)
    }

    /// Renames an imported recording from the import window; the open card
    /// follows.
    func renameImported(_ stamp: String, to title: String) {
        guard let entry = importedEntry(stamp) else { return }
        do {
            try RecordingLibrary.save(title: title, in: entry.folder)
            refreshCard(stamp)
        } catch {
            problem = "Could not save the title: \(error.localizedDescription)"
        }
    }

    /// The recording an import made, wherever a title has moved it.
    func importedEntry(_ stamp: String) -> RecordingEntry? {
        allEntries.first { RecordingLibrary.stamp(of: $0.folder) == stamp }
    }

    /// Reads a recording again after work on it finished: the list, and the card if it is open.
    func refreshCard(_ stamp: String) {
        reload()
        guard let card, RecordingLibrary.stamp(of: card.entry.folder) == stamp, !card.finishing,
            let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder)
        else { return }
        self.card?.entry = entry
        titles.suggest(for: entry, agent: true)
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
            let location = try Trash.move(entry.folder)
            if card?.entry.folder == entry.folder { card = nil }
            trashed = (entry, location)
            reload()
        } catch {
            problem = "Could not move the recording to the Trash: \(error.localizedDescription)"
        }
    }

    /// Switches the recordings folder; with `moving`, the recordings already
    /// made go along. Never while recording, so no folder is mid-write.
    func changeRoot(to destination: URL, moving: Bool, done: (@MainActor @Sendable (String?) -> Void)? = nil) {
        guard phase == .idle else {
            done?("TapeUp is recording; change the folder after it stops.")
            return
        }
        guard !movingRecordings else {
            done?("TapeUp is still moving the recordings; try again when it finishes.")
            return
        }
        guard destination.standardizedFileURL != root.standardizedFileURL else {
            done?(nil)
            return
        }
        guard moving else {
            root = destination
            done?(nil)
            return
        }
        let library = library
        movingRecordings = true
        Task.detached(priority: .userInitiated) {
            let outcome = Result { try library.move(to: destination) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                movingRecordings = false
                root = destination
                switch outcome {
                case .success(let result) where !result.skipped.isEmpty:
                    problem =
                        "\(result.skipped.count) recording\(result.skipped.count == 1 ? "" : "s") stayed in \(library.root.lastPathComponent): the new folder already has one with the same name."
                    done?(problem)
                case .failure(let error):
                    problem = "Some recordings could not be moved: \(error.localizedDescription)"
                    done?(problem)
                default:
                    done?(nil)
                }
            }
        }
    }

    /// Whether a recording's audio can go while its transcript stays: only
    /// once the transcript is done and nothing is reading the audio.
    func canRemoveAudio(_ entry: RecordingEntry) -> Bool {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        let labeling = speakers.work[stamp].map { $0 != .failed } ?? false
        return entry.transcript == .done && entry.hasAudio && entry.folder != activeFolder
            && !transcription.working.contains(stamp) && !labeling
    }

    /// Moves the recording's audio to the Trash and keeps everything else.
    func removeAudio(_ entry: RecordingEntry) {
        guard canRemoveAudio(entry) else { return }
        do { _ = try removeAudioForCommand(entry) } catch {
            problem = "Could not move the audio to the Trash: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func removeAudioForCommand(_ entry: RecordingEntry) throws -> URL {
        speakers.player.stop()
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        let location = try Trash.move(entry.audio)
        EventLog.append("audio removed", in: entry.folder)
        removedAudio = (stamp, location)
        refreshQuietly(stamp)
        return location
    }

    /// Puts the audio removed last back in its recording.
    func undoRemoveAudio() {
        guard let removedAudio, let folder = library.folder(withStamp: removedAudio.stamp),
            let entry = RecordingLibrary.entry(at: folder)
        else { return }
        self.removedAudio = nil
        do {
            try FileManager.default.moveItem(at: removedAudio.location, to: entry.audio)
            EventLog.append("audio restored", in: folder)
            refreshQuietly(removedAudio.stamp)
        } catch {
            problem = "Could not put the audio back: \(error.localizedDescription)"
        }
    }

    /// Reloads the list and the open card without asking for a title.
    func refreshQuietly(_ stamp: String) {
        reload()
        guard let card, RecordingLibrary.stamp(of: card.entry.folder) == stamp,
            let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder)
        else { return }
        self.card?.entry = entry
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
        // Someone new at a meeting joins the people list, so they are
        // suggested next time and their name is spelled right.
        let added = people.names.filter { name in
            !card.entry.people.names.contains(name) && !peopleList.contains(name)
        }
        if !added.isEmpty {
            changePeople { list in
                for name in added { list.add(.init(name: name)) }
                return true
            }
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

    /// Names a voice, and adds the name to who was there, so naming a
    /// speaker never has to be done twice.
    /// Names a voice; the person joins who was there and the people list.
    func nameVoice(_ voice: Int, _ name: String?, in entry: RecordingEntry) {
        speakers.name(voice, name, in: entry)
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

    /// True when a name is the user's own, as set on the People page.
    func isYou(_ name: String) -> Bool {
        guard let you = peopleList.you else { return false }
        return NameSuggester.fold(you) == NameSuggester.fold(name)
    }

    /// True once there is anything to suggest from.
    var hasSuggestionSource: Bool { !peopleList.people.isEmpty || allEntries.contains { !$0.people.names.isEmpty } }

    func dismissProblem() { problem = nil }

    func clearPeopleNotice() { if peopleNotice != .copied { peopleNotice = nil } }

    /// Puts the model in a given state for `TapeUp snapshot`, which renders
    /// the panel offscreen so its design can be checked without recording.
    func stage(
        phase: Phase, elapsed: TimeInterval = 0, microphone: String, output: String, levels: ([Float], [Float])? = nil,
        notice: PeopleNotice? = nil, problem: String? = nil, testing: Bool = false, paused: Bool = false
    ) {
        self.phase = phase
        self.paused = paused
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

// MARK: Requests from the command line

extension AppModel {
    /// Completes an import's missing stages using the app's ordinary queues.
    private func ensureImport(
        _ file: URL, title: String?, requestedRoot: URL,
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CommandOutcome {
        var stamp: String?
        do {
            guard root.standardizedFileURL == requestedRoot else {
                throw Refusal(
                    "folder_changed", "TapeUp switched recordings folders before import began.",
                    suggestion: "Check TapeUp folder before choosing where to import.")
            }
            progress("Inspecting the import…")
            let candidate = try await CLIWork.inspect(file)
            guard root.standardizedFileURL == requestedRoot else {
                throw Refusal(
                    "folder_changed", "TapeUp switched recordings folders during inspection.",
                    suggestion: "Check TapeUp folder before choosing where to import.")
            }
            progress("Importing…")
            let copy = try await importRecording(
                candidate, plan: .init(transcribe: true, labelSpeakers: true, title: title))
            let id = RecordingLibrary.stamp(of: copy.folder)
            stamp = id
            progress("Recording \(id): \(copy.folder.path)")
            func current() throws -> RecordingEntry {
                guard root.standardizedFileURL == requestedRoot else {
                    throw Refusal(
                        "folder_changed", "TapeUp switched recordings folders.",
                        suggestion: "Check TapeUp folder before choosing the recording again.")
                }
                guard let folder = library.folder(withStamp: id), let entry = RecordingLibrary.entry(at: folder) else {
                    throw Refusal("not_found", "The imported recording is no longer there.")
                }
                return entry
            }
            var entry = try current()
            while RecordingWork.foreignOwner(in: entry.folder) != nil {
                try await Task.sleep(for: .milliseconds(100))
                entry = try current()
            }
            try RecordingWork.recover(in: entry.folder, appBusy: busyStamps.contains(id))
            entry = try current()
            if entry.transcript != .done {
                try CLIWork.requireAudio(entry)
                progress("Transcribing…")
                try transcription.ensure(entry)  // makes a queued, disabled transcript explicit too
                while entry.transcript != .done || transcription.working.contains(id) {
                    if entry.transcript == .failed, !transcription.working.contains(id) {
                        throw Refusal(
                            "transcription_failed", "The transcript could not be made.",
                            suggestion: "Check the recording audio and model before retrying.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    entry = try current()
                }
            }
            while RecordingWork.foreignOwner(in: entry.folder) != nil {
                try await Task.sleep(for: .milliseconds(100))
                entry = try current()
            }
            if !CLIWork.labelsCurrent(entry.folder, count: nil) {
                try CLIWork.requireAudio(entry)
                progress("Labeling speakers…")
                if !speakers.busy.contains(id) { try speakers.ensureLabels(entry, count: nil) }
                while !CLIWork.labelsCurrent(entry.folder, count: nil) {
                    if (MetaFile.read(entry.folder)?["speaker_labels"] as? [String: Any])?["status"] as? String
                        == "failed", !speakers.busy.contains(id)
                    {
                        throw Refusal(
                            "labels_failed", "Speakers could not be labeled.",
                            suggestion: "Check the audio, voice files and model before retrying.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    entry = try current()
                }
            }
            return CLIWork.imported(entry.folder, copied: copy.imported, requestedTitle: title)
        } catch {
            if let stamp { throw CLIWork.importFailure(error, stamp: stamp, file: file, title: title) }
            throw error
        }
    }

    /// Answers a `TapeUp` command sent while the app runs, so the work shows
    /// in the panel and only one model loads. `reply` gets a refusal, or nil
    /// and the folder the command acted on.
    func handle(
        _ request: [String: String], progress: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        reply: @escaping @MainActor @Sendable (Refusal?, URL?, String?) -> Void
    ) {
        func done(_ refusal: Refusal?, _ folder: URL?) { reply(refusal, folder, nil) }
        func failed(_ error: Error) { done(CLIWork.refusal(error), nil) }
        let command = request["command"] ?? ""
        if command == "keep", request["value"] == "off" {
            done(
                Refusal(
                    "usage", "TapeUp keep takes only a recording.",
                    suggestion: "Only the user unlocks audio in Free up space."), nil)
            return
        }
        if command == "folder" {
            let destination = URL(fileURLWithPath: request["value"] ?? root.path)
            let moving = request["move"] == "1"
            changeRoot(to: destination, moving: moving) { [weak self] problem in
                guard let problem else { return done(nil, self?.root) }
                if self?.root.standardizedFileURL == destination.standardizedFileURL {
                    // The folder changed; some recordings stayed behind.
                    done(Refusal("partly_moved", problem, suggestion: "Move or rename them by hand."), self?.root)
                } else {
                    done(
                        Refusal(
                            "busy", problem,
                            suggestion:
                                "Wait for a current move to finish, or ask the user to stop recording before changing folders.",
                            retryable: self?.movingRecordings == true), nil)
                }
            }
            return
        }
        if command == "import" {
            let requestedRoot = root.standardizedFileURL
            Task {
                do {
                    let outcome = try await ensureImport(
                        URL(fileURLWithPath: request["value"] ?? ""), title: request["title"],
                        requestedRoot: requestedRoot, progress: progress)
                    reply(nil, nil, try outcome.encoded())
                } catch { failed(error) }
            }
            return
        }
        if command == "people" {
            do {
                let outcome = try CLIWork.people(request, root: root, busy: busyStamps)
                if let rename = outcome.rename {
                    lastRename = (
                        request["value"] ?? "", request["new"] ?? "", rename.changedRecordings.count, rename.undo
                    )
                }
                voicesRevision += 1
                loadPeople()
                reload()
                if let card { refreshQuietly(RecordingLibrary.stamp(of: card.entry.folder)) }
                reply(nil, root, try outcome.encoded())
            } catch { failed(error) }
            return
        }
        guard let target = request["recording"], let folder = library.recording(target),
            let entry = RecordingLibrary.entry(at: folder)
        else {
            done(
                Refusal(
                    "not_found", "No recording \(request["recording"] ?? "") in \(root.path).",
                    suggestion: "Give its folder, folder name or start time, such as 2026-11-06-1430."), nil)
            return
        }
        guard folder != activeFolder, entry.status != "recording" else {
            done(
                Refusal(
                    "recording", "That recording is still running.", suggestion: "Try again after it stops.",
                    retryable: false), nil)
            return
        }
        let stamp = RecordingLibrary.stamp(of: folder)
        switch command {
        case "voices", "remove-audio", "keep":
            do {
                let outcome: CommandOutcome = try library.withLock {
                    var held: FolderLock?
                    defer { held?.release() }
                    guard var entry = RecordingLibrary.entry(at: folder) else {
                        throw Refusal(
                            "not_found", "That recording was removed or moved from this library.",
                            suggestion: "Check TapeUp folder and choose its full stamp again.")
                    }
                    let outcome: CommandOutcome
                    if command == "voices", request["action"] != "name" {
                        outcome = try CLIWork.voices(folder)
                    } else {
                        if command == "remove-audio", entry.keepAudio { try CLIWork.removeCheck(entry) }
                        let needsIdle = command != "keep" && (command != "remove-audio" || entry.hasAudio)
                        if needsIdle, transcription.isSuspended(stamp) {
                            throw Refusal(
                                "busy", "Transcription is queued but turned off in the app.",
                                suggestion:
                                    "If the user wants that work, run TapeUp transcribe \(stamp) to request it explicitly."
                            )
                        }
                        entry = try CLIWork.check(entry, busy: busyStamps.contains(stamp), needsIdle: needsIdle)
                        if command == "keep" || command == "remove-audio" { held = try CLIWork.lock(folder) }
                        switch command {
                        case "voices":
                            outcome = try CLIWork.alone(request, root: root)
                            speakers.refreshNames(stamp)
                        case "keep":
                            if !entry.keepAudio { setKeep(entry, true) }
                            guard RecordingLibrary.entry(at: folder)?.keepAudio == true else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            outcome = CLIWork.kept(folder)
                        default:
                            try CLIWork.removeCheck(entry)
                            let hadAudio = entry.hasAudio
                            var location: URL?
                            if hadAudio {
                                guard canRemoveAudio(entry) else {
                                    throw Refusal(
                                        "busy", "The app is transcribing or labeling this recording.",
                                        suggestion: "Wait for the app's work to finish.", retryable: true)
                                }
                                location = try removeAudioForCommand(entry)
                            }
                            outcome = CLIWork.removed(folder, removed: hadAudio, trash: location)
                        }
                    }
                    return outcome
                }
                reply(nil, folder, try outcome.encoded())
            } catch { failed(error) }
        case "title":
            do {
                let renamed = try library.withLock {
                    let current = library.folder(withStamp: stamp) ?? folder
                    return try RecordingLibrary.save(title: request["value"], in: current)
                }
                refreshCard(stamp)
                done(nil, renamed)
            } catch {
                done(Refusal("write_failed", "Could not save the title: \(error.localizedDescription)"), nil)
            }
        case "transcribe":
            do {
                try CLIWork.requireAudio(entry)
                try transcription.ensure(entry)
                done(nil, folder)
            } catch { failed(error) }
        case "speakers":
            let count = request["voices"].flatMap(Int.init)
            if CLIWork.labelsCurrent(folder, count: count) {
                reply(nil, folder, try? CLIWork.speakers(folder, labeled: false).encoded())
                return
            }
            guard entry.transcript == .done else {
                done(
                    Refusal(
                        "no_transcript", "That recording has no transcript yet.",
                        suggestion: "Run TapeUp transcribe \(stamp) first."), nil)
                return
            }
            do {
                try CLIWork.requireAudio(entry)
                try speakers.ensureLabels(entry, count: count)
                done(nil, folder)
            } catch { failed(error) }
        default:
            done(Refusal("usage", "TapeUp does not know the command \(command)."), nil)
        }
    }
}
