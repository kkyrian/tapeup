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

    struct Item: Identifiable {
        let url: URL
        var id: URL { url }
        var state: State = .reading
        var candidate: RecordingImport.Candidate?
        /// How much of it is copied, 0 to 1.
        var copied: Double = 0
        /// The voice count for speaker labels; nil is Auto (the estimate).
        var voices: Int?
        /// The recording it became.
        var stamp: String?
        /// A name typed for the recording, in place of the file's.
        var title: String?

        var name: String { (url.lastPathComponent as NSString).deletingPathExtension }
        /// What the recording will be called.
        var shownName: String { title ?? name }
    }

    let model: AppModel
    private(set) var items: [Item] = []
    var transcribe = true
    var labelSpeakers = true
    /// Files are being dragged over the window.
    var targeted = false
    var close: () -> Void = {}

    /// Fingerprints already in the library, read once per window.
    private var known: Set<String>?
    private var reader: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var stopping = false
    /// Files finished in an import before this one, left out of its count.
    private(set) var earlier: Set<Item.ID> = []

    init(model: AppModel) { self.model = model }

    func reset() {
        reader?.cancel()
        reader = nil
        adding = []
        items = []
        known = nil
        transcribe = true
        labelSpeakers = true
    }

    var importing: Bool { worker != nil }
    var ready: [Item] { items.filter { $0.state == .ready } }
    var readyBytes: Int64 { ready.reduce(0) { $0 + ($1.candidate?.bytes ?? 0) } }

    /// How much of these files is copied, by size, so the bar moves within
    /// a file too. A failed file counts as done.
    static func copiedShare(of items: [Item]) -> Double {
        var total = 0.0
        var copied = 0.0
        for item in items {
            let bytes = Double(max(item.candidate?.bytes ?? 1, 1))
            switch item.state {
            case .copied: copied += bytes
            case .copying: copied += bytes * min(max(item.copied, 0), 1)
            case .failed: copied += bytes
            case .ready, .reading: break
            default: continue
            }
            total += bytes
        }
        return total > 0 ? copied / total : 0
    }
    /// Files dropped and not yet listed, or listed and not yet read.
    var reading: Bool { !adding.isEmpty || items.contains { $0.state == .reading } }
    private var adding: Set<UUID> = []
    var copiedCount: Int { items.count { $0.state == .copied } }
    var labeling: Bool { transcribe && labelSpeakers }

    /// Adds files and the audio inside folders, each listed once.
    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let previous = reader
        let id = UUID()
        adding.insert(id)
        reader = Task { [weak self] in
            defer { Task { @MainActor in self?.adding.remove(id) } }
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
        }
    }

    /// Where a recording that came in has got to.
    enum Stage: Equatable {
        /// In the library; nothing more was asked for.
        case imported
        case waitingToTranscribe
        case transcribing
        case findingSpeakers
        case transcriptFailed
        /// Everything asked for is done.
        case ready(speakers: Bool)
    }

    /// How a recording that came in stands now: its transcript, then its
    /// speakers. Nil before it is copied in.
    func stage(of item: Item) -> Stage? {
        guard item.state == .copied, let stamp = item.stamp, let entry = model.importedEntry(stamp) else { return nil }
        switch entry.transcript {
        case .pending:
            return model.transcription.current == stamp ? .transcribing : .waitingToTranscribe
        case .failed:
            return .transcriptFailed
        case .done:
            if let work = model.speakers.work(on: entry), work != .failed { return .findingSpeakers }
            return .ready(speakers: model.speakers.result(for: entry) != nil)
        case .none:
            return .imported
        }
    }

    /// How far its transcript has come, while it is the one being made.
    func progress(of item: Item) -> Transcription.Progress? {
        guard let stamp = item.stamp, model.transcription.current == stamp else { return nil }
        return model.transcription.progress
    }

    /// The recording a copied file became.
    func entry(of item: Item) -> RecordingEntry? { item.stamp.flatMap(model.importedEntry) }

    /// Shows a recording that came in, in the panel.
    func open(_ item: Item) {
        guard let stamp = item.stamp else { return }
        model.showImported(stamp)
    }

    /// Names the recording, before, while or after it comes in; blank goes
    /// back to the file's name.
    func rename(_ item: Item, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        set(item.url) { $0.title = trimmed.isEmpty || trimmed == item.name ? nil : trimmed }
        if let stamp = item.stamp { model.renameImported(stamp, to: trimmed.isEmpty ? item.name : trimmed) }
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
        earlier = Set(items.filter { $0.state == .copied || $0.state.isFailure }.map(\.id))
        worker = Task {
            while !stopping {
                // Files added meanwhile join this import, once read.
                guard let item = items.first(where: { $0.state == .ready }), let candidate = item.candidate else {
                    if reading {
                        try? await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    break
                }
                let url = item.url
                set(url) { $0.state = .copying }
                do {
                    let stamp = try await model.importRecording(
                        candidate, transcribe: transcribe, labelSpeakers: labeling,
                        voices: labeling ? item.voices : nil, title: item.title
                    ) { fraction in
                        Task { @MainActor in self.set(url) { $0.copied = max($0.copied, fraction) } }
                    }
                    known?.insert(candidate.fingerprint)
                    set(url) {
                        $0.state = .copied
                        $0.copied = 1
                        $0.stamp = stamp
                    }
                    // Renamed while it was copying.
                    if let now = items.first(where: { $0.url == url }), now.title != item.title {
                        model.renameImported(stamp, to: now.shownName)
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

struct ImportView: View {
    static let width: CGFloat = 460
    private static let margin: CGFloat = 20
    private static let rowHeight: CGFloat = 44
    /// Icons sit in this column; every title in the window starts after it.
    fileprivate static let iconColumn: CGFloat = Style.textEdge - Style.inset

    @Bindable var imports: Imports
    let choose: () -> Void
    private var targeted: Bool { imports.targeted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dropArea
            if !imports.items.isEmpty { list.padding(.top, 4) }
            Divider().padding(.vertical, 14)
            options
            footer.padding(.top, 16)
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 8)
        .padding(.bottom, Self.margin)
        .frame(width: Self.width)
        .dropDestination(for: URL.self) { urls, _ in
            imports.add(urls)
            return !urls.isEmpty
        } isTargeted: {
            imports.targeted = $0
        }
        .animation(.snappy(duration: 0.2), value: imports.items.map(\.id))
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    // MARK: Drop area

    @ViewBuilder private var dropArea: some View {
        if imports.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    .padding(.bottom, 4)
                Text("Drop recordings or folders here")
                    .font(.system(size: 13, weight: .medium))
                LinkButton("Choose Files…", action: choose)
                    .hoverHelp("Audio files, videos, or folders of them")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(well)
        } else {
            AddMoreRow(targeted: targeted, action: choose)
        }
    }

    private var well: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape.fill(targeted ? Color.accentColor.opacity(0.07) : .clear)
            .overlay(
                shape.strokeBorder(
                    targeted ? Color.accentColor : Color.primary.opacity(0.14),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(imports.items) { item in
                        ImportRow(
                            item: item, twin: twin(of: item), showVoices: imports.labeling,
                            removable: item.state != .copied && item.state != .copying,
                            queued: imports.importing && item.state == .ready, stage: imports.stage(of: item),
                            progress: imports.progress(of: item),
                            entry: imports.entry(of: item), imports: imports
                        )
                        .id(item.id)
                    }
                }
            }
            // Files added below the fold come into view.
            .onChange(of: imports.items.count) { before, now in
                guard now > before, let added = imports.items.last else { return }
                withAnimation(.snappy(duration: 0.25)) { scroller.scrollTo(added.id, anchor: .bottom) }
            }
        }
        // Room for the rows' hover fill, which reaches 6 points past the text.
        .padding(.horizontal, -6)
        .scrollIndicators(.automatic)
        .frame(height: min(CGFloat(imports.items.count), 5.5) * Self.rowHeight)
    }

    /// For a file skipped as a copy: the listed file it copies, if any.
    private func twin(of item: Imports.Item) -> String? {
        guard item.state == .duplicate, let fingerprint = item.candidate?.fingerprint else { return nil }
        return imports.items.first {
            $0.id != item.id && $0.state != .duplicate && $0.candidate?.fingerprint == fingerprint
        }?.name
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $imports.transcribe) {
                option("text.quote", "Transcribe", "On this Mac", on: imports.transcribe)
            }
            Toggle(isOn: $imports.labelSpeakers) {
                option(
                    "person.2", "Label speakers", imports.transcribe ? "Who spoke when" : "Needs Transcribe",
                    on: imports.labeling || !imports.transcribe)
            }
            .disabled(!imports.transcribe)
        }
        .toggleStyle(OptionToggle())
        // Locked while copying, showing the choices it copies with.
        .allowsHitTesting(!imports.importing)
        .opacity(imports.importing ? 0.5 : 1)
    }

    /// Off reads as the source rows do: dimmed, and the words roll to "Off".
    private func option(_ symbol: String, _ title: String, _ detail: String, on: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.secondary : Color.secondary.opacity(0.6))
                .frame(width: Self.iconColumn, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(on ? .primary : .secondary)
                Text(on ? detail : "Off")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .animation(.snappy(duration: 0.2), value: on)
        .animation(.snappy(duration: 0.2), value: detail)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        let count = imports.ready.count
        if imports.importing {
            let current = imports.items.filter { !imports.earlier.contains($0.id) }
            let done = current.count { $0.state == .copied || $0.state.isFailure }
            let total = done + current.count { $0.state == .ready || $0.state == .copying || $0.state == .reading }
            HStack(spacing: 12) {
                ProgressView(value: Imports.copiedShare(of: current))
                    .animation(.linear(duration: 0.2), value: Imports.copiedShare(of: current))
                Text("Copying \(min(done + 1, total)) of \(total)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .frame(height: 32)
        } else if count > 0 {
            FlatButton(kind: .primary, action: imports.start) {
                Text("Import \(count) recording\(count == 1 ? "" : "s")")
                    + Text("  ·  " + ByteCountFormatter.string(fromByteCount: imports.readyBytes, countStyle: .file))
                    .foregroundStyle(.white.opacity(0.75))
            }
        } else if imports.copiedCount > 0 {
            FlatButton(kind: .primary, action: imports.close) { Text("Done") }
        } else {
            Text(imports.reading ? "Reading…" : "Import")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Style.fill, in: .rect(cornerRadius: Style.corner, style: .continuous))
        }
    }
}

/// Above the list: Choose Files… for more, which can also be dropped
/// anywhere on the window.
private struct AddMoreRow: View {
    let targeted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: ImportView.iconColumn, alignment: .leading)
                Text(targeted ? "Drop to add" : "Drop more here, or ")
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    + Text(targeted ? "" : "Choose Files…").fontWeight(.medium).foregroundStyle(Color.accentColor)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .frame(height: 32)
            .padding(.horizontal, 6)
            .background { background }
            .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .hoverHelp("Audio files, videos, or folders of them")
        .padding(.horizontal, -6)
    }

    /// The hover fill, or while files are dragged over the window an accent
    /// fill on the same frame, so nothing in the row moves.
    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Style.corner, style: .continuous)
        if targeted {
            shape.fill(Color.accentColor.opacity(0.08))
        } else if hovering {
            shape.fill(Style.fill)
        }
    }
}

/// One file: how it stands in the icon column (remove there on hover), its
/// One file: what it is and how it stands. Before import its voice count;
/// once in, what can be done with the recording, and a click opens it.
private struct ImportRow: View {
    let item: Imports.Item
    let twin: String?
    let showVoices: Bool
    let removable: Bool
    /// Waiting its turn in an import under way.
    let queued: Bool
    let stage: Imports.Stage?
    /// While its transcript is being made: how far, and the latest line.
    let progress: Transcription.Progress?
    let entry: RecordingEntry?
    let imports: Imports
    @State private var hovering = false
    @State private var copiedPath = false
    @State private var copiedText = false

    var body: some View {
        HStack(spacing: 0) {
            // Once in, the file's side of the row opens its recording.
            HStack(spacing: 0) {
                leading
                Spacer(minLength: 12)
            }
            .contentShape(.rect)
            .onTapGesture { if item.state == .copied { imports.open(item) } }
            .hoverHelp(ifAny: item.state == .copied ? "Open in TapeUp" : nil)
            trailing
        }
        .frame(height: 44)
        .padding(.horizontal, 6)
        .background(
            hovering && item.state == .copied ? Style.fill : .clear,
            in: .rect(cornerRadius: Style.corner, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var leading: some View {
        Group {
            if hovering && removable {
                IconButton(symbol: "xmark", help: "Leave this one out", size: 20) { imports.remove(item) }
                    .padding(.leading, -3)
            } else {
                mark
            }
        }
        .frame(width: ImportView.iconColumn, height: 20, alignment: .leading)
        VStack(alignment: .leading, spacing: 2) {
            NameField(
                name: item.shownName, editable: [.ready, .copying, .copied].contains(item.state),
                muted: item.state.muted, pencilOnly: item.state == .copied, rowHovering: hovering,
                rename: { imports.rename(item, to: $0) })
            Text(status)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(statusColor)
                .lineLimit(1)
                // A quote keeps its newest words.
                .truncationMode(progress?.line != nil && stage == .transcribing ? .head : .tail)
                .contentTransition(item.state == .copying ? .numericText() : .opacity)
                .animation(.snappy(duration: 0.2), value: status)
        }
    }

    /// Before import, the voice count; once in, the recording's own actions.
    @ViewBuilder private var trailing: some View {
        if item.state == .copied, let entry {
            // One slot, as in Recent: how far at rest, the actions on hover,
            // so nothing moves as the pointer passes.
            ZStack(alignment: .trailing) {
                if let progress {
                    Text(progressText(progress))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: progress.fraction)
                        .opacity(hovering ? 0 : 1)
                }
                actions(entry)
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
        } else if showVoices, item.state == .ready || item.state == .copying {
            VoiceCount(voices: item.voices, set: { imports.setVoices($0, for: item) })
                .disabled(item.state != .ready)
                .transition(.opacity)
        }
    }

    private func progressText(_ progress: Transcription.Progress) -> String {
        let percent = "\(Int((progress.fraction * 100).rounded()))%"
        guard progress.fraction < 1 else { return "Finishing…" }
        return progress.remaining().map { percent + " · " + Format.left($0) } ?? percent
    }

    private func actions(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "arrow.up.forward.app", help: "Open in TapeUp", weight: .regular) {
                imports.open(item)
            }
            IconButton(
                symbol: copiedText ? "checkmark" : "doc.on.doc",
                help: entry.transcript == .done ? (copiedText ? "Copied" : "Copy transcript") : "No transcript yet",
                weight: .regular
            ) {
                imports.model.copyTranscript(entry)
                flash($copiedText)
            }
            .disabled(entry.transcript != .done)
            IconButton(
                symbol: copiedPath ? "checkmark" : "link", help: copiedPath ? "Copied" : "Copy path",
                weight: .regular
            ) {
                imports.model.copy(entry)
                flash($copiedPath)
            }
            IconButton(symbol: "folder", help: "Show in Finder", weight: .regular) { imports.model.reveal(entry) }
            IconButton(symbol: "trash", help: "Move to Trash", weight: .regular) { imports.remove(item) }
                .padding(.leading, 8)
        }
        .padding(.trailing, -6)
        .contentShape(.rect)
        .onTapGesture { imports.open(item) }
        .opacity(hovering || copiedText || copiedPath ? 1 : 0)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { flag.wrappedValue = false }
    }

    /// One mark per stage, so a check means everything asked for is done.
    @ViewBuilder private var mark: some View {
        switch (item.state, stage) {
        case (.reading, _):
            Spinner(tint: .secondary)
        case (.copying, _):
            ProgressRing(fraction: item.copied).padding(.leading, 1)
        case (.ready, _) where queued:
            Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(.tertiary)
        case (.copied, .transcribing) where progress != nil:
            ProgressRing(fraction: progress?.fraction ?? 0).padding(.leading, 1)
        case (.copied, .waitingToTranscribe):
            Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(.tertiary)
        case (.copied, .transcribing), (.copied, .findingSpeakers):
            Spinner(tint: .accentColor)
        case (.copied, .transcriptFailed), (.failed, _):
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(.orange)
        case (.copied, _):
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
        default:
            Image(systemName: item.candidate?.isMovie == true ? "film" : "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(item.state.muted ? .tertiary : .secondary)
        }
    }

    private var status: String {
        switch item.state {
        case .reading: return "Reading…"
        case .duplicate: return twin.map { "Copy of “\($0)”" } ?? "Already in TapeUp"
        case .unusable(let reason), .failed(let reason): return reason
        case .ready: return queued ? "Waiting to import · " + details : details
        case .copying: return "Copying… \(Int((item.copied * 100).rounded()))%"
        case .copied:
            switch stage {
            case .waitingToTranscribe: return "Waiting to transcribe"
            case .transcribing: return progress?.line.map { "“\($0)”" } ?? "Transcribing…"
            case .findingSpeakers: return "Finding speakers…"
            case .transcriptFailed: return "Transcript failed"
            case .ready(let speakers): return speakers ? "Transcript and speakers ready" : "Transcript ready"
            case .imported, nil: return "Imported · " + details
            }
        }
    }

    /// Grey text throughout: the mark carries the color, and only for a check
    /// or a problem.
    private var statusColor: Color {
        item.state.muted ? Color.secondary.opacity(0.6) : .secondary
    }

    private var details: String {
        guard let candidate = item.candidate else { return "" }
        return [
            Format.when(candidate.started), Format.length(candidate.duration),
            ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file),
        ]
        .joined(separator: " · ")
    }
}

/// An arc going round: work under way with no fraction to show.
private struct Spinner: View {
    let tint: Color
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .padding(.leading, 1)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
            .accessibilityHidden(true)
    }
}

/// The recording's name, renamed in place at any stage: click it, type,
/// then Return or a click elsewhere keeps it and Escape puts it back.
private struct NameField: View {
    let name: String
    let editable: Bool
    let muted: Bool
    /// Once imported a click on the name opens the recording, like the rest
    /// of the row; renaming is the pencil beside it, shown on row hover.
    var pencilOnly = false
    var rowHovering = false
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @State private var frame = CGRect.zero
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if editing {
                TextField("Name", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: finish)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(Style.fill, in: .rect(cornerRadius: 5, style: .continuous))
            } else if editable && pencilOnly {
                HStack(spacing: 2) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                    IconButton(symbol: "pencil", help: "Rename", size: 18, weight: .regular, action: begin)
                        .opacity(rowHovering ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: rowHovering)
                }
                .frame(height: 20)
            } else if editable {
                Button(action: begin) { label }
                    .buttonStyle(.plain)
                    .hoverHelp("Rename")
                    .accessibilityLabel("\(name), rename")
                    .onHover { hovering = $0 }
            } else {
                label
            }
        }
        .font(.system(size: 13))
        .padding(.leading, -5)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            frame = $0
        }
        .onDisappear(perform: commit)
    }

    private var label: some View {
        HStack(spacing: 5) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(muted ? .secondary : .primary)
            if editable {
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 20)
        .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 5, style: .continuous))
        .contentShape(.rect)
    }

    private func begin() {
        text = name
        editing = true
        DispatchQueue.main.async { focused = true }
        // A click on the window's background takes no focus, so a click
        // outside the field ends the rename here.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if let height = event.window?.contentView?.bounds.height {
                    let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                    if !frame.contains(point) { commit() }
                }
            }
            return event
        }
    }

    private func commit() {
        guard editing else { return }
        finish()
        if text != name { rename(text) }
    }

    private func finish() {
        editing = false
        hovering = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// How many voices to find: Auto (the estimate), 2, 3, 4, or a number of
/// five or more typed in place of 5+. Drawn as a native segmented control,
/// the choice a raised knob, so a column of them stays quiet.
private struct VoiceCount: View {
    let voices: Int?
    let set: (Int?) -> Void
    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            segment("Auto", width: 38, selected: voices == nil, help: "Find how many voices there are") { set(nil) }
            ForEach(2...4, id: \.self) { number in
                segment("\(number)", selected: voices == number, help: "\(number) voices") { set(number) }
            }
            if typing {
                TextField("5+", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: Segment.width, height: Segment.height)
                    .background(Knob())
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.accentColor)
                    )
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .onAppear { focused = true }
            } else {
                let large = (voices ?? 0) >= 5
                segment(large ? "\(voices!)" : "5+", selected: large, help: "Five or more voices") {
                    text = large ? "\(voices!)" : ""
                    typing = true
                }
            }
        }
        .padding(2)
        .background(Style.fill, in: .rect(cornerRadius: 7, style: .continuous))
    }

    private func commit() {
        guard typing else { return }
        typing = false
        if let number = Int(text.trimmingCharacters(in: .whitespaces)), number >= 1 { set(number) }
    }

    private func segment(
        _ title: String, width: CGFloat = Segment.width, selected: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Segment(title: title, width: width, selected: selected, action: action).hoverHelp(help)
    }
}

private struct Segment: View {
    static let width: CGFloat = 26
    static let height: CGFloat = 20

    let title: String
    let width: CGFloat
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(width: width, height: Self.height)
                .foregroundStyle(selected ? .primary : enabled ? .secondary : .tertiary)
                .background {
                    if selected {
                        Knob()
                    } else if hovering && enabled {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Style.fill)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen segment: raised like the switch's knob.
private struct Knob: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(scheme == .dark ? Color.white.opacity(0.2) : Color.white)
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.12), radius: 0.5, y: 0.5)
    }
}

/// A toggle drawn as the panel's switch, the whole row clicking.
private struct OptionToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        OptionRow(configuration: configuration)
    }

    private struct OptionRow: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 0) {
                    configuration.label
                    Spacer(minLength: 8)
                    MiniSwitch(on: configuration.isOn && enabled)
                }
                .frame(height: 36)
                .padding(.horizontal, 6)
                .background(
                    hovering && enabled ? Style.fill : .clear,
                    in: .rect(cornerRadius: Style.corner, style: .continuous)
                )
                .contentShape(.rect)
            }
            .buttonStyle(Pressable())
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .padding(.horizontal, -6)
        }
    }
}

extension View {
    /// Help text only when there is something to say.
    @ViewBuilder fileprivate func hoverHelp(ifAny text: String?) -> some View {
        if let text { hoverHelp(text) } else { self }
    }
}
