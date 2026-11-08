import AppKit
import SwiftUI
import TapeUpCore

/// The files gathered for import, read one at a time, then copied in.
@MainActor @Observable
final class Imports {
    enum State: Equatable {
        case reading
        case ready
        /// Already in TapeUp, or listed twice.
        case duplicate
        /// No sound, or not readable.
        case unusable(String)
        case copying
        case copied
        case failed(String)
    }

    /// The designs being compared; the one picked stays, the others go.
    enum Look: String, CaseIterable, Identifiable {
        case listening, sentence, landing, live
        var id: String { rawValue }
        var title: String {
            switch self {
            case .listening: "Listening"
            case .sentence: "Sentence"
            case .landing: "Where they land"
            case .live: "Starts on drop"
            }
        }
    }

    struct Item: Identifiable {
        let url: URL
        var id: URL { url }
        var state: State = .reading
        var candidate: RecordingImport.Candidate?
        /// The file's loudness in slices, for its waveform; empty until read.
        var peaks: [Float] = []
        /// How much of it is copied, 0 to 1.
        var copied: Double = 0
        /// The voice count for speaker labels; nil is Auto (the estimate).
        var voices: Int?
        /// The recording it became.
        var stamp: String?

        var name: String { (url.lastPathComponent as NSString).deletingPathExtension }
    }

    let model: AppModel
    private(set) var items: [Item] = []
    var look: Look = .listening {
        didSet { if look == .live, !ready.isEmpty { start() } }
    }
    var transcribe = true
    var labelSpeakers = true
    var close: () -> Void = {}

    /// Fingerprints already in the library, read once per window.
    private var known: Set<String>?
    private var reader: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var stopping = false

    init(model: AppModel) { self.model = model }

    func reset() {
        reader?.cancel()
        reader = nil
        items = []
        known = nil
        transcribe = true
        labelSpeakers = true
    }

    var importing: Bool { worker != nil }
    var ready: [Item] { items.filter { $0.state == .ready } }
    var readyBytes: Int64 { ready.reduce(0) { $0 + ($1.candidate?.bytes ?? 0) } }
    var reading: Bool { items.contains { $0.state == .reading } }
    var copiedCount: Int { items.count { $0.state == .copied } }
    var labeling: Bool { transcribe && labelSpeakers }

    /// Adds files and the audio inside folders, each listed once.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let previous = reader
        reader = Task { [weak self] in
            await previous?.value
            let files = await Task.detached(priority: .userInitiated) { RecordingImport.files(in: urls) }.value
            guard let self, !Task.isCancelled else { return }
            let listed = Set(items.map(\.url.standardizedFileURL))
            let new = files.filter { !listed.contains($0.standardizedFileURL) }
            items += new.map { Item(url: $0) }
            if known == nil {
                let library = model.importLibrary
                known = await Task.detached(priority: .userInitiated) { RecordingImport.imported(in: library) }.value
            }
            for url in new {
                guard !Task.isCancelled else { return }
                await read(url)
            }
        }
    }

    private func read(_ url: URL) async {
        let state: State
        var candidate: RecordingImport.Candidate?
        do {
            let found = try await RecordingImport.inspect(url)
            candidate = found
            let root = model.importLibrary.root.resolvingSymlinksInPath().path + "/"
            let inLibrary = url.resolvingSymlinksInPath().path.hasPrefix(root)
            let listedBefore = items.contains { $0.url != url && $0.candidate?.fingerprint == found.fingerprint }
            state = inLibrary || known?.contains(found.fingerprint) == true || listedBefore ? .duplicate : .ready
        } catch let failure as RecordingImport.Failure {
            state = .unusable(failure.description)
        } catch {
            state = .unusable(RecordingImport.Failure.unreadable.description)
        }
        set(url) {
            $0.candidate = candidate
            $0.state = state
        }
        // Dropping is the go-ahead in the live design.
        if look == .live, state == .ready { start() }
        guard let candidate else { return }
        let peaks = await RecordingImport.peaks(of: url, duration: candidate.duration, count: 72)
        set(url) { $0.peaks = peaks }
    }

    /// Leaves a file out; one already copied goes to the Trash, so this is
    /// also the undo. A file copying now finishes first.
    func remove(_ item: Item) {
        guard item.state != .copying else { return }
        if item.state == .copied, let stamp = item.stamp, let entry = model.importedEntry(stamp) {
            model.trash(entry)
            known?.remove(item.candidate?.fingerprint ?? "")
        }
        items.removeAll { $0.url == item.url }
        // A file kept out as a duplicate of this one can now come in.
        if let fingerprint = item.candidate?.fingerprint, known?.contains(fingerprint) != true,
            let twin = items.firstIndex(where: { $0.state == .duplicate && $0.candidate?.fingerprint == fingerprint })
        {
            items[twin].state = .ready
            if look == .live { start() }
        }
    }

    func setVoices(_ voices: Int?, for item: Item) {
        set(item.url) { $0.voices = voices }
        // Once copied, the count is the recording's own.
        if let stamp = item.stamp, let entry = model.importedEntry(stamp) {
            try? RecordingLibrary.save(people: .init(count: voices, names: entry.people.names), in: entry.folder)
            model.reload()
        }
    }

    /// Copies ready files in, one at a time, until none is left or Stop.
    func start() {
        guard worker == nil else { return }
        stopping = false
        worker = Task {
            while !stopping, let item = items.first(where: { $0.state == .ready }), let candidate = item.candidate {
                let url = item.url
                set(url) { $0.state = .copying }
                do {
                    let stamp = try await model.importRecording(
                        candidate, transcribe: transcribe, labelSpeakers: labeling,
                        voices: labeling ? item.voices : nil
                    ) { fraction in
                        Task { @MainActor in self.set(url) { $0.copied = max($0.copied, fraction) } }
                    }
                    known?.insert(candidate.fingerprint)
                    set(url) {
                        $0.state = .copied
                        $0.copied = 1
                        $0.stamp = stamp
                    }
                } catch {
                    let reason = (error as? RecordingImport.Failure)?.description ?? error.localizedDescription
                    set(url) { $0.state = .failed(reason) }
                }
            }
            worker = nil
        }
    }

    /// Lets the file copying now finish and leaves the rest.
    func stop() { stopping = true }

    private func set(_ url: URL, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.url == url }) else { return }
        change(&items[index])
    }
}

extension Imports.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var muted: Bool {
        switch self {
        case .duplicate, .unusable: true
        default: false
        }
    }
}

/// The import window: the design picked below, and a strip to switch
/// designs while they are compared.
struct ImportView: View {
    static let width: CGFloat = 440

    @Bindable var imports: Imports
    let choose: () -> Void
    /// How many files are over the window right now, or nil.
    @State private var hovering: Int?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch imports.look {
                case .listening: ListeningLook(imports: imports, hovering: hovering, choose: choose)
                case .sentence: SentenceLook(imports: imports, hovering: hovering, choose: choose)
                case .landing: LandingLook(imports: imports, hovering: hovering, choose: choose)
                case .live: LiveLook(imports: imports, hovering: hovering, choose: choose)
                }
            }
            LookPicker(look: $imports.look)
        }
        .frame(width: Self.width)
        .background(hovering != nil ? Color.accentColor.opacity(0.05) : .clear)
        .onDrop(of: [.fileURL], delegate: FileDrop(hovering: $hovering, add: imports.add))
        .animation(.snappy(duration: 0.22), value: imports.items.map(\.id))
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.25), value: imports.look)
    }
}

/// While the designs are compared: which one is showing.
private struct LookPicker: View {
    @Binding var look: Imports.Look

    var body: some View {
        HStack(spacing: 2) {
            Text("Design").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary).padding(.trailing, 4)
            ForEach(Array(Imports.Look.allCases.enumerated()), id: \.element) { index, option in
                Segment(title: "\(index + 1) \(option.title)", selected: look == option) { look = option }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Color.primary.opacity(0.04))
    }
}

// MARK: - Shared pieces

/// Counts the files coming in while they are over the window, so it can say
/// what letting go will do before it happens.
struct FileDrop: DropDelegate {
    @Binding var hovering: Int?
    let add: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { hovering = info.itemProviders(for: [.fileURL]).count }
    func dropExited(info: DropInfo) { hovering = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        hovering = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let data = try? await provider.loadItem(forTypeIdentifier: "public.file-url") as? Data,
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    urls.append(url)
                }
            }
            add(urls)
        }
        return true
    }
}

/// The empty window: a still waveform that comes alive under files.
struct Well: View {
    let hovering: Int?
    let choose: () -> Void
    var title = "Drop recordings here"
    var height: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            ListeningLine(active: hovering != nil).frame(width: 180, height: 48)
            Text(hovering.map { $0 == 1 ? "Let go to add it" : "Let go to add \($0)" } ?? title)
                .font(.system(size: 15, weight: .semibold))
                .contentTransition(.opacity)
                .padding(.top, 18)
            Text("Audio, video, or whole folders. Your files stay where they are.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            LinkButton("Choose Files…", action: choose)
                .padding(.top, 10)
                .hoverHelp("Pick files or folders")
                .opacity(hovering == nil ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// Under a list: the same waveform, small, for more files.
struct DropMore: View {
    let hovering: Int?
    let choose: () -> Void
    var text = "Drop more, or"

    var body: some View {
        HStack(spacing: 8) {
            ListeningLine(active: hovering != nil, count: 9).frame(width: 36, height: 14)
            Text(hovering.map { "Let go to add \($0)" } ?? text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if hovering == nil {
                LinkButton("Choose Files…", action: choose).padding(.leading, -6)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}

/// Bars like each file's waveform: a faint, still shape at rest, moving in
/// the accent while files are over the window.
struct ListeningLine: View {
    let active: Bool
    var count = 31

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let step = size.width / CGFloat(count)
                let width = max(1.5, step * 0.5)
                for index in 0..<count {
                    let x = Double(index) / Double(count - 1)
                    let envelope = 0.35 + 0.65 * sin(x * .pi)
                    // A still, speech-like shape; while listening it moves.
                    let still = 0.25 + 0.2 * sin(Double(index) * 1.7) * cos(Double(index) * 0.6)
                    let moving =
                        0.5 + 0.5 * sin(time * 7 + Double(index) * 0.9) * cos(time * 3.1 + Double(index) * 0.4)
                    let level = envelope * (active ? 0.2 + 0.8 * moving : still)
                    let height = max(2, CGFloat(level) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2, width: width,
                        height: height)
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: width / 2),
                        with: .color(active ? Color.accentColor : Color.primary.opacity(0.18)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A file's loudness as thin bars; the part already copied is drawn in the
/// accent. Before it is read, a flat line.
struct Waveform: View {
    let peaks: [Float]
    let filled: Double
    let muted: Bool

    var body: some View {
        Canvas { context, size in
            let base = Color.primary.opacity(muted ? 0.12 : 0.28)
            guard !peaks.isEmpty else {
                let line = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
                context.fill(Path(line), with: .color(base))
                return
            }
            let step = size.width / CGFloat(peaks.count)
            let width = max(1, step * 0.55)
            for (index, peak) in peaks.enumerated() {
                let height = max(1.5, CGFloat(peak) * size.height)
                let x = CGFloat(index) * step
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                let done = (x + width / 2) / size.width <= filled
                context.fill(
                    Path(roundedRect: rect, cornerRadius: width / 2), with: .color(done ? Color.accentColor : base))
            }
        }
        .accessibilityHidden(true)
    }
}

extension Imports.Item {
    /// How far the waveform is drawn in the accent: the copy so far.
    var fill: Double {
        switch state {
        case .copying: copied
        case .copied: 1
        default: 0
        }
    }

    /// Length and size, or how the file stands.
    var detail: String {
        switch state {
        case .reading: return "Reading…"
        case .duplicate: return "Already in TapeUp"
        case .unusable(let reason), .failed(let reason): return reason
        default:
            guard let candidate else { return "" }
            return Format.length(candidate.duration) + " · "
                + ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file)
        }
    }

    var removeHelp: String { state == .copied ? "Undo: move it to the Trash" : "Leave this one out" }
}

/// How many voices to find: "Auto" until clicked, then Auto, 2, 3, 4 and a
/// typed number of five or more, folding back once one is picked.
struct VoiceCount: View {
    let voices: Int?
    let set: (Int?) -> Void
    @State private var open = false
    @State private var typing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if open {
                HStack(spacing: 1) {
                    Segment(title: "Auto", selected: voices == nil) { pick(nil) }
                    ForEach(2...4, id: \.self) { number in
                        Segment(title: "\(number)", selected: voices == number) { pick(number) }
                    }
                    if typing {
                        TextField("5+", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .multilineTextAlignment(.center)
                            .frame(width: 28, height: 18)
                            .background(Color.accentColor.opacity(0.12), in: .capsule)
                            .focused($focused)
                            .onSubmit(commit)
                            .onChange(of: focused) { _, now in if !now { commit() } }
                            .onAppear { focused = true }
                    } else {
                        let large = (voices ?? 0) >= 5
                        Segment(title: large ? "\(voices!)" : "5+", selected: large) {
                            text = large ? "\(voices!)" : ""
                            typing = true
                        }
                    }
                }
                .padding(2)
                .background(Style.fill, in: .capsule)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            } else {
                Button {
                    open = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.wave.2").font(.system(size: 9, weight: .semibold))
                        Text(voices.map { "\($0) voices" } ?? "Auto")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(voices == nil ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(hovering ? Style.fillHover : Style.fill, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(Pressable())
                .onHover { hovering = $0 }
                .hoverHelp("How many voices to find")
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: open)
        .fixedSize()
    }

    private func pick(_ number: Int?) {
        set(number)
        open = false
    }

    private func commit() {
        guard typing else { return }
        typing = false
        if let number = Int(text.trimmingCharacters(in: .whitespaces)), number >= 1 { set(number) }
        open = false
    }
}

struct Segment: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(minWidth: 22, minHeight: 18)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : hovering ? Style.fillHover : .clear, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What happens to each file once it is in, as a chain: transcribe and
/// title, then label speakers. Turning the first off breaks the link, and
/// the second goes with it.
struct Chain: View {
    @Bindable var imports: Imports

    var body: some View {
        HStack(spacing: 0) {
            ChainNode(
                title: "Transcribe",
                detail: imports.transcribe
                    ? imports.model.titleWriter.map { "titled by \($0)" } ?? "named after each file"
                    : "named after each file",
                on: imports.transcribe, enabled: true
            ) { imports.transcribe.toggle() }
            ChainLink(on: imports.transcribe)
            ChainNode(
                title: "Label speakers", detail: "on this Mac", on: imports.labeling, enabled: imports.transcribe
            ) { imports.labelSpeakers.toggle() }
            Spacer(minLength: 0)
        }
        .disabled(imports.importing && imports.look != .live)
        .animation(.snappy(duration: 0.22), value: imports.transcribe)
        .animation(.snappy(duration: 0.22), value: imports.labelSpeakers)
    }
}

struct ChainNode: View {
    let title: String
    let detail: String
    let on: Bool
    let enabled: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                ZStack {
                    Circle().strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    if on {
                        Circle().fill(Color.accentColor)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: 40)
            .background(
                hovering && enabled ? Style.fillHover : Style.fill, in: .rect(cornerRadius: 9, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The link between two steps: whole while both run, broken when not.
struct ChainLink: View {
    let on: Bool
    var width: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                path, with: .color(on ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: on ? [] : [2, 4]))
        }
        .frame(width: width, height: 40)
    }
}

/// The main button, as the import stands: Import with the count and size,
/// the copy's progress, or Done.
struct ImportButton: View {
    let imports: Imports
    var verb: (Int) -> String = { "Import \($0) recording\($0 == 1 ? "" : "s")" }

    var body: some View {
        let count = imports.ready.count
        if imports.importing {
            let done = imports.items.count { $0.state == .copied || $0.state.isFailure }
            let total = done + imports.items.count { $0.state == .ready || $0.state == .copying }
            Text("Copying \(min(done + 1, total)) of \(total)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: 32)
        } else if count > 0 {
            FlatButton(kind: .primary, action: imports.start) {
                Text(
                    verb(count) + " · "
                        + ByteCountFormatter.string(fromByteCount: imports.readyBytes, countStyle: .file))
            }
        } else if imports.copiedCount > 0 {
            FlatButton(kind: .plain, action: imports.close) { Text("Done") }
        } else {
            FlatButton(kind: .plain, action: {}) { Text(imports.reading ? "Reading…" : "Nothing to import") }
                .disabled(true)
                .opacity(0.6)
        }
    }
}

/// Groups items by the day they were recorded, newest first, as the panel does.
func importDays(_ items: [Imports.Item]) -> [(day: String, items: [Imports.Item])] {
    let sorted = items.enumerated().sorted { first, second in
        switch (first.element.candidate?.started, second.element.candidate?.started) {
        case (let one?, let two?): one > two
        case (nil, nil): first.offset < second.offset
        case (nil, _): false
        case (_, nil): true
        }
    }
    var groups: [(day: String, items: [Imports.Item])] = []
    for (_, item) in sorted {
        let day = item.candidate.map { Format.day($0.started) } ?? "Reading"
        if groups.last?.day == day {
            groups[groups.count - 1].items.append(item)
        } else {
            groups.append((day, [item]))
        }
    }
    return groups
}
