import AppKit
import SwiftUI
import TapeUpCore

/// A recording in a list: when it was, its title over who was there, and
/// its length, which gives way to copy, Finder and Trash on hover. Click
/// opens its card. Recent, All recordings and Free up space share it.
struct RecordingRow: View {
    enum Look: Equatable {
        /// The time of day, under a day heading.
        case time
        /// One line: weekday and day, the title and who was there, under a month heading.
        case dense
        /// Weekday and day over two lines, for the one-line look while searching.
        case weekday
        /// One line with the month and day, for a list without month headings.
        case monthDay
    }

    let entry: RecordingEntry
    @Bindable var model: AppModel
    var look: Look = .time
    /// A few words of the transcript, in place of who was there, when the
    /// search found the row by what was said.
    var excerpt: RecordingSearch.Excerpt?
    /// In place of the length at rest: the audio's size, on Free up space.
    var size: String?
    /// On Free up space, which clears audio only: a lock that keeps the
    /// audio takes the place of the Trash.
    var keepable = false
    /// Set by the gallery: the row for this folder draws as if hovered.
    @MainActor static var staged: String?
    @State private var hovering = false
    @State private var copied = false

    private var hovered: Bool { hovering || Self.staged == entry.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(leading)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: leadingWidth, alignment: .leading)
            if look == .dense || look == .monthDay {
                denseText
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = entry.title {
                        Text(title).font(.system(size: 13)).lineLimit(1)
                        if let excerpt {
                            excerptLine(excerpt)
                        } else if let people = peopleLine {
                            Text(people).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text(peopleLine ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        if let excerpt { excerptLine(excerpt) }
                    }
                }
            }
            Spacer(minLength: 4)
            // One fixed slot: the length at rest, the actions on hover, so
            // the title never narrows as the pointer passes.
            ZStack(alignment: .trailing) {
                Group {
                    // A ring only for the one being made; the rest wait their turn.
                    if model.transcription.current == RecordingLibrary.stamp(of: entry.folder) {
                        let progress = model.transcription.progress(of: entry)
                        ProgressRing(fraction: progress?.fraction ?? 0, size: 12).frame(width: 16, height: 16)
                            .hoverHelp(
                                "Transcribing, \(Int(((progress?.fraction ?? 0) * 100).rounded()))%"
                                    + (progress?.remaining().map { ", " + Format.left($0) } ?? ""))
                    } else if model.transcription.isWorking(on: entry) {
                        Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(.tertiary)
                            .frame(width: 16, height: 16)
                            .hoverHelp("Waiting to transcribe")
                    } else {
                        // Audio is the rule; only its absence is marked, and keeping it.
                        HStack(spacing: 3) {
                            if keepable, entry.keepAudio, entry.hasAudio {
                                Image(systemName: "lock.fill").font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if !entry.hasAudio, entry.status != "recording" {
                                Image(systemName: "text.page").font(.system(size: 10))
                            }
                            Text(size ?? Format.length(entry.duration)).font(.system(size: 11).monospacedDigit())
                        }
                        .foregroundStyle(size == nil ? .tertiary : .secondary)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            (size ?? Format.length(entry.duration)) + (entry.hasAudio ? "" : ", transcript only")
                                + (keepable && entry.keepAudio && entry.hasAudio ? ", kept" : ""))
                    }
                }
                .opacity(hovered || copied ? 0 : 1)
                HStack(spacing: 0) {
                    IconButton(symbol: copied ? "checkmark" : "link", help: "Copy path", size: 22, action: copy)
                    IconButton(symbol: "folder", help: "Show in Finder", size: 22) { model.reveal(entry) }
                    if keepable {
                        let kept = entry.keepAudio
                        IconButton(
                            symbol: kept ? "lock.fill" : "lock.open",
                            help: kept
                                ? "Kept: Free up space leaves its audio. Click to stop keeping it"
                                : "Keep its audio",
                            size: 22, tinted: kept
                        ) { model.setKeep(entry, !kept) }
                        .clickTarget("keep " + RecordingLibrary.stamp(of: entry.folder))
                    } else {
                        IconButton(symbol: "trash", help: "Move to Trash", size: 22) { model.trash(entry) }
                    }
                }
                .opacity(hovered || copied ? 1 : 0)
                .allowsHitTesting(hovered || copied)
            }
            .frame(width: 68, alignment: .trailing)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, look == .dense || look == .monthDay ? 2 : 6)
        .frame(minHeight: look == .dense || look == .monthDay ? 24 : 28)
        .background(hovered ? Style.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.open(entry) }
        .clickTarget("row " + RecordingLibrary.stamp(of: entry.folder))
        .contextMenu {
            Button("Copy Path", action: copy)
            Button("Show in Finder") { model.reveal(entry) }
            Button("Rename…") { model.open(entry) }
            Divider()
            if keepable, entry.hasAudio {
                Button(entry.keepAudio ? "Stop Keeping Audio" : "Keep Audio") { model.setKeep(entry, !entry.keepAudio) }
            }
            if model.canRemoveAudio(entry) {
                // On its card, where Undo shows.
                Button("Remove Audio, Keep Transcript") {
                    model.open(entry)
                    model.removeAudio(entry)
                }
            }
            if !keepable { Button("Move to Trash") { model.trash(entry) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            [entry.title, Format.when(entry.started), Format.spokenDuration(entry.duration)].compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAction(named: "Copy path") { model.copy(entry) }
        .accessibilityAction(named: "Show in Finder") { model.reveal(entry) }
        .accessibilityAction(named: "Open") { model.open(entry) }
        .accessibilityAction(named: "Move to Trash") { model.trash(entry) }
    }

    /// The title, then who was there in grey, on one line. The names
    /// never break mid-word: all of them, else the first name and how many
    /// more, else none; the full list is in the help.
    private var denseText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let title = entry.title {
                Text(title).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                ViewThatFits(in: .horizontal) {
                    ForEach(shortPeopleLines, id: \.self) { line in
                        Text(line).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
            } else {
                Text(peopleLine ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .hoverHelp(entry.title != nil ? peopleLine ?? "" : "")
    }

    /// Who was there, longest first: every name, then the first name and a count.
    private var shortPeopleLines: [String] {
        guard let full = peopleLine else { return [] }
        let people = entry.people
        guard let first = people.names.first else { return [full] }
        let others = max(people.names.count, (people.count ?? 0) - 1) - 1
        let short = (first.split(separator: " ").first.map(String.init) ?? first) + (others > 0 ? " +\(others)" : "")
        return short == full ? [full] : [full, short]
    }

    /// The transcript's words around the match: the match as said in the
    /// primary color, the rest grey.
    private func excerptLine(_ excerpt: RecordingSearch.Excerpt) -> some View {
        (Text(excerpt.before).foregroundStyle(.secondary) + Text(excerpt.match).foregroundStyle(.primary)
            + Text(excerpt.after).foregroundStyle(.secondary))
            .font(.system(size: 11))
            .lineLimit(1)
    }

    private var leading: String {
        switch look {
        case .time: Format.time(entry.started)
        case .dense, .weekday: Format.weekdayDay(entry.started)
        case .monthDay: Format.monthDay(entry.started)
        }
    }

    private var leadingWidth: CGFloat {
        switch look {
        case .time: Format.timeColumnWidth
        case .dense, .weekday: Format.weekdayDayColumnWidth
        case .monthDay: Format.monthDayColumnWidth
        }
    }

    private func copy() {
        model.copy(entry)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private var peopleLine: String? {
        let people = entry.people
        guard !people.isEmpty else { return nil }
        if !people.names.isEmpty {
            let names = people.names.joined(separator: ", ")
            let others = (people.count ?? 0) - people.names.count - 1
            return others > 0 ? "\(names) +\(others)" : names
        }
        return people.count.map { $0 == 1 ? "Just you" : "\($0) people" }
    }
}
