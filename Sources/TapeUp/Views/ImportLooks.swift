import AppKit
import SwiftUI
import TapeUpCore

// The import window's designs, compared side by side until one is picked.

// MARK: - 1 Listening

/// Files as waveforms grouped by day, the copy filling each waveform, and
/// what happens after as two linked steps over the Import button.
struct ListeningLook: View {
    @Bindable var imports: Imports
    let hovering: Int?
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if imports.items.isEmpty {
                Well(hovering: hovering, choose: choose)
            } else {
                let days = importDays(imports.items)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(days, id: \.day) { group in
                            SectionLabel(text: group.day).padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
                            ForEach(group.items) { item in ListeningRow(imports: imports, item: item) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
                .frame(height: min(CGFloat(imports.items.count) * 54 + CGFloat(days.count) * 26 + 4, 360))
                DropMore(hovering: hovering, choose: choose)
            }
            Divider().padding(.horizontal, 16)
            Chain(imports: imports).padding(.horizontal, 16).padding(.vertical, 14)
            ImportButton(imports: imports).padding(.horizontal, 16).padding(.bottom, 16)
        }
    }
}

private struct ListeningRow: View {
    let imports: Imports
    let item: Imports.Item
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .leading) {
                if item.state == .copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(item.candidate.map { Format.time($0.started) } ?? "")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Format.timeColumnWidth, height: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(item.state.muted ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(item.detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(item.state.isFailure ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Waveform(peaks: item.peaks, filled: item.fill, muted: item.state.muted).frame(height: 14)
                    if imports.labeling, item.candidate != nil, !item.state.muted {
                        VoiceCount(voices: item.voices) { imports.setVoices($0, for: item) }
                    }
                }
            }
            RemoveButton(item: item, visible: hovering) { imports.remove(item) }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .frame(height: 54, alignment: .top)
        .background(hovering ? Style.fill.opacity(0.6) : .clear, in: .rect(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.25), value: item.state)
    }
}

/// × on hover: leaves a file out, or undoes one already copied.
private struct RemoveButton: View {
    let item: Imports.Item
    let visible: Bool
    let remove: () -> Void

    var body: some View {
        let shown = visible && item.state != .copying
        IconButton(symbol: "xmark", help: item.removeHelp, size: 18, action: remove)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
    }
}

// MARK: - 2 Sentence

/// The files as a strip of tapes, and every choice as a word in one
/// sentence: click a word to turn it off; the words that need it go too.
struct SentenceLook: View {
    @Bindable var imports: Imports
    let hovering: Int?
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if imports.items.isEmpty {
                Well(hovering: hovering, choose: choose, height: 200)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(imports.items) { item in TapeCard(imports: imports, item: item) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                DropMore(hovering: hovering, choose: choose)
            }
            Divider().padding(.horizontal, 16)
            FlowLayout(spacing: 5, lineSpacing: 4) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in piece.view }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .disabled(imports.importing)
            .animation(.snappy(duration: 0.22), value: imports.transcribe)
            .animation(.snappy(duration: 0.22), value: imports.labelSpeakers)
            ImportButton(imports: imports) { _ in "Import" }.padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private enum Piece {
        case word(String)
        case strong(String)
        case muted(String)
        case token(String, on: Bool, trailing: String = "", action: () -> Void)

        @ViewBuilder @MainActor var view: some View {
            switch self {
            case .word(let text): Text(text).font(.system(size: 16))
            case .strong(let text): Text(text).font(.system(size: 16, weight: .semibold))
            case .muted(let text): Text(text).font(.system(size: 16)).foregroundStyle(.secondary)
            case .token(let text, let on, let trailing, let action):
                HStack(spacing: 1) {
                    WordToken(text: text, on: on, action: action)
                    if !trailing.isEmpty { Text(trailing).font(.system(size: 16)) }
                }
            }
        }
    }

    private var pieces: [Piece] {
        let count = imports.ready.count
        var list: [Piece] = [.word("Import")]
        if count > 0 {
            list += [
                .strong("\(count) recording\(count == 1 ? "" : "s")"),
                .muted("(" + ByteCountFormatter.string(fromByteCount: imports.readyBytes, countStyle: .file) + "),"),
            ]
        } else {
            list += [.word("recordings,")]
        }
        let transcribe = Piece.token("transcribe", on: imports.transcribe, trailing: "") {
            imports.transcribe.toggle()
        }
        guard imports.transcribe else {
            return list + [
                transcribe, .word("them,"), .word("and"), .word("name"), .word("them"), .word("after"),
                .word("their"), .word("files."),
            ]
        }
        list += [transcribe, .word("them,")]
        if let writer = imports.model.titleWriter {
            list += [.word("let"), .strong(writer), .word("title"), .word("them,")]
        } else {
            list += [.word("name"), .word("them"), .word("after"), .word("their"), .word("files,")]
        }
        list += [
            .word("and"),
            .token("find the speakers", on: imports.labelSpeakers, trailing: ".") { imports.labelSpeakers.toggle() },
        ]
        return list
    }
}

/// A word in the sentence that turns its step on or off.
private struct WordToken: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16, weight: on ? .semibold : .regular))
                .strikethrough(!on, color: .secondary)
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    on ? Color.accentColor.opacity(hovering ? 0.2 : 0.12) : hovering ? Style.fill : .clear,
                    in: .rect(cornerRadius: 6, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .hoverHelp(on ? "Turn off" : "Turn on")
    }
}

/// One file as a small tape: name, when and how long, its waveform.
private struct TapeCard: View {
    let imports: Imports
    let item: Imports.Item
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(subtitle)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(item.state.isFailure ? Color.orange : Color.secondary)
                .lineLimit(1)
            Waveform(peaks: item.peaks, filled: item.fill, muted: item.state.muted)
                .frame(height: 18)
                .padding(.top, 6)
            if imports.labeling, item.candidate != nil, !item.state.muted {
                VoiceCount(voices: item.voices) { imports.setVoices($0, for: item) }.padding(.top, 6)
            }
        }
        .padding(10)
        .frame(width: 140, alignment: .topLeading)
        .frame(minHeight: 96, alignment: .topLeading)
        .background(Style.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .opacity(item.state.muted ? 0.55 : 1)
        .overlay(alignment: .topTrailing) {
            if item.state == .copied && !hovering {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).padding(6)
            } else if hovering, item.state != .copying {
                IconButton(symbol: "xmark", help: item.removeHelp, size: 18) { imports.remove(item) }.padding(3)
            }
        }
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        guard let candidate = item.candidate, !item.state.muted, !item.state.isFailure else { return item.detail }
        return Format.day(candidate.started) + " · " + Format.length(candidate.duration)
    }
}

// MARK: - 3 Where they land

/// The new files placed among your recordings at the times they were made:
/// yours faint, the new ones solid, a duplicate as an outline.
struct LandingLook: View {
    @Bindable var imports: Imports
    let hovering: Int?
    let choose: () -> Void
    @State private var changing = false

    private enum Line: Identifiable {
        case new(Imports.Item)
        case yours(RecordingEntry)

        var id: String {
            switch self {
            case .new(let item): item.url.path
            case .yours(let entry): entry.folder.path
            }
        }

        var time: Date? {
            switch self {
            case .new(let item): item.candidate?.started
            case .yours(let entry): entry.started
            }
        }
    }

    private var days: [(day: String, lines: [Line])] {
        let imported = Set(imports.items.compactMap(\.stamp))
        return importDays(imports.items).map { group in
            let yours = imports.model.allEntries.filter {
                Format.day($0.started) == group.day && !imported.contains(RecordingLibrary.stamp(of: $0.folder))
            }
            let lines = group.items.map(Line.new) + yours.prefix(6).map(Line.yours)
            return (group.day, lines.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if imports.items.isEmpty {
                Well(hovering: hovering, choose: choose)
            } else {
                let groups = days
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.day) { group in
                            SectionLabel(text: group.day).padding(.top, 10).padding(.bottom, 4)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(group.lines) { line in
                                    switch line {
                                    case .new(let item): LandingRow(imports: imports, item: item)
                                    case .yours(let entry): YoursRow(entry: entry)
                                    }
                                }
                            }
                            .background(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.1)).frame(width: 2).padding(.leading, 7)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
                .frame(
                    height: min(
                        CGFloat(groups.reduce(0) { $0 + $1.lines.count }) * 32 + CGFloat(groups.count) * 30, 420))
                DropMore(hovering: hovering, choose: choose)
            }
            Divider().padding(.horizontal, 16)
            if changing {
                Chain(imports: imports).padding(.horizontal, 16).padding(.top, 12)
            }
            HStack(spacing: 4) {
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                LinkButton(changing ? "Done" : "Change") { changing.toggle() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ImportButton(imports: imports) { "Add \($0) to your recordings" }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .animation(.snappy(duration: 0.22), value: changing)
    }

    private var summary: String {
        guard imports.transcribe else { return "Named after each file, no transcript ·" }
        let title = imports.model.titleWriter.map { "titled by \($0)" } ?? "named after each file"
        return "Transcribed, \(title)" + (imports.labeling ? ", speakers labeled ·" : " ·")
    }
}

private struct LandingRow: View {
    let imports: Imports
    let item: Imports.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Dot(state: item.state, copied: item.fill).frame(width: 16)
            Text(item.candidate.map { Format.time($0.started) } ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Format.timeColumnWidth, alignment: .leading)
            Text(item.name)
                .font(.system(size: 13, weight: item.state.muted ? .regular : .semibold))
                .foregroundStyle(item.state.muted ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.state.muted ? item.detail : item.candidate.map { Format.length($0.duration) } ?? item.detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(item.state.isFailure ? Color.orange : Color.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4)
            if imports.labeling, item.candidate != nil, !item.state.muted {
                VoiceCount(voices: item.voices) { imports.setVoices($0, for: item) }
            }
            RemoveButton(item: item, visible: hovering) { imports.remove(item) }
        }
        .frame(height: 32)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    /// New: a solid accent dot, ringed while it copies; a duplicate: an outline.
    private struct Dot: View {
        let state: Imports.State
        let copied: Double

        var body: some View {
            ZStack {
                if state.muted {
                    Circle().strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.5).frame(width: 10, height: 10)
                } else {
                    Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 16, height: 16)
                    Circle().fill(Color.accentColor).frame(width: 9, height: 9)
                    if state == .copying {
                        Circle().trim(from: 0, to: copied)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 16, height: 16)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor), in: .circle)
        }
    }
}

/// One of your recordings, faint, between the new ones.
private struct YoursRow: View {
    let entry: RecordingEntry

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                .padding(2)
                .background(Color(nsColor: .windowBackgroundColor), in: .circle)
                .frame(width: 16)
            Text(Format.time(entry.started))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: Format.timeColumnWidth, alignment: .leading)
            Text(entry.title ?? "Untitled").font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
        }
        .frame(height: 28)
    }
}

// MARK: - 4 Starts on drop

/// Set what happens, then drop: each file starts as it lands, and its row
/// follows it through copy, transcript, title and speakers. × undoes.
struct LiveLook: View {
    @Bindable var imports: Imports
    let hovering: Int?
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Chain(imports: imports).padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
            Divider().padding(.horizontal, 16)
            if imports.items.isEmpty {
                Well(hovering: hovering, choose: choose, title: "Drop recordings to start", height: 200)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(imports.items) { item in LiveRow(imports: imports, item: item) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(imports.items.count) * 62 + 12, 372))
                HStack {
                    if imports.importing {
                        Text(copying).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        LinkButton("Stop the rest", action: imports.stop)
                    } else {
                        DropMore(hovering: hovering, choose: choose, text: "Drop more any time, or")
                            .padding(.horizontal, -16)
                        Spacer()
                        LinkButton("Done", action: imports.close)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
            }
        }
    }

    private var copying: String {
        let left = imports.items.count { $0.state == .ready || $0.state == .copying }
        return "Copying, \(left) to go"
    }
}

private struct LiveRow: View {
    let imports: Imports
    let item: Imports.Item
    @State private var hovering = false

    private var entry: RecordingEntry? { item.stamp.flatMap(imports.model.importedEntry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let title = entry?.title, title != item.name {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("from \(item.name)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(item.name)
                        .font(.system(size: 13, weight: item.state.muted ? .regular : .semibold))
                        .foregroundStyle(item.state.muted ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if item.state.muted || item.state.isFailure || item.state == .reading {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(item.state.isFailure ? Color.orange : Color.secondary)
                } else if imports.labeling, speakersOpen {
                    VoiceCount(voices: item.voices) { imports.setVoices($0, for: item) }
                }
                RemoveButton(item: item, visible: hovering) { imports.remove(item) }
            }
            if !item.state.muted, !item.state.isFailure, item.state != .reading {
                StepTrack(stops: stops)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(hovering ? Style.fill.opacity(0.6) : .clear, in: .rect(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }

    /// The voice count can change until the speakers are found.
    private var speakersOpen: Bool {
        guard let entry else { return true }
        return imports.model.speakers.result(for: entry) == nil && imports.model.speakers.work(on: entry) == nil
    }

    private var stops: [StepTrack.Stop] {
        var list = [
            StepTrack.Stop(
                title: "Copied",
                progress: item.state == .copied ? 1 : item.state == .copying ? max(item.copied, 0.02) : 0)
        ]
        guard imports.transcribe else { return list }
        let transcript: Double? = {
            switch entry?.transcript {
            case .done: 1
            case .pending: nil
            case .failed: -1
            default: 0
            }
        }()
        list.append(.init(title: "Transcript", progress: transcript))
        if imports.model.titleWriter != nil {
            let titled: Double? = entry?.title != nil ? 1 : transcript == 1 ? nil : 0
            list.append(.init(title: "Titled", progress: titled))
        }
        if imports.labeling {
            let speakers: Double? = {
                guard let entry else { return 0 }
                if imports.model.speakers.result(for: entry) != nil { return 1 }
                switch imports.model.speakers.work(on: entry) {
                case .failed: return -1
                case nil: return 0
                default: return nil
                }
            }()
            list.append(.init(title: "Speakers", progress: speakers))
        }
        return list
    }
}

/// A file's way through import: a segment per step, filled when done,
/// moving while under way (progress nil), orange when it failed (-1).
private struct StepTrack: View {
    struct Stop {
        let title: String
        let progress: Double?
    }

    let stops: [Stop]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in Segment(progress: stop.progress) }
            }
            HStack(spacing: 3) {
                ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                    Text(stop.title)
                        .font(.system(size: 10, weight: (stop.progress ?? 0.5) >= 1 ? .semibold : .regular))
                        .foregroundStyle((stop.progress ?? 0.5) >= 1 || stop.progress == nil ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Segment: View {
        let progress: Double?

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: progress != nil)) { context in
                GeometryReader { geometry in
                    let width = geometry.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        if let progress, progress < 0 {
                            Capsule().fill(Color.orange)
                        } else if let progress {
                            Capsule().fill(Color.accentColor).frame(width: width * min(1, progress))
                        } else {
                            // Under way: a short bar travelling along.
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4)
                            Capsule()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: width * 0.3)
                                .offset(x: (width * 1.3) * phase / 1.4 - width * 0.3)
                        }
                    }
                    .clipShape(.capsule)
                }
            }
            .frame(height: 4)
        }
    }
}
