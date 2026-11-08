import AppKit
import SwiftUI
import TapeUpCore

/// A recording in a list: when it was, its title over who was there, and
/// its length, which gives way to copy, Finder and Trash on hover. Click
/// opens its card. Recent and All recordings share it.
struct RecordingRow: View {
    enum Look: Equatable {
        /// The time of day, under a day heading.
        case time
        /// The date, where no heading says the day, in a column this wide.
        case date(width: CGFloat)
        /// One line: weekday and day, the title and who was there, under a month heading.
        case dense
    }

    let entry: RecordingEntry
    @Bindable var model: AppModel
    var look: Look = .time
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
            if look == .dense {
                denseText
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = entry.title {
                        Text(title).font(.system(size: 13)).lineLimit(1)
                        if let people = peopleLine {
                            Text(people).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else {
                        Text(peopleLine ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            // One fixed slot: the length at rest, the actions on hover, so
            // the title never narrows as the pointer passes.
            ZStack(alignment: .trailing) {
                Group {
                    if let progress = model.transcription.progress(of: entry) {
                        ProgressRing(fraction: progress.fraction, size: 12).frame(width: 16, height: 16)
                            .hoverHelp(
                                "Transcribing, \(Int((progress.fraction * 100).rounded()))%"
                                    + (progress.remaining().map { ", " + Format.left($0) } ?? ""))
                    } else if model.transcription.isWorking(on: entry) {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                            .hoverHelp("Transcribing")
                    } else {
                        Text(Format.length(entry.duration))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .opacity(hovered || copied ? 0 : 1)
                HStack(spacing: 0) {
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy path", size: 22, action: copy)
                    IconButton(symbol: "folder", help: "Show in Finder", size: 22) { model.reveal(entry) }
                    IconButton(symbol: "trash", help: "Move to Trash", size: 22) { model.trash(entry) }
                }
                .opacity(hovered || copied ? 1 : 0)
                .allowsHitTesting(hovered || copied)
            }
            .frame(width: 68, alignment: .trailing)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, look == .dense ? 2 : 6)
        .frame(minHeight: look == .dense ? 24 : 28)
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
            Button("Move to Trash") { model.trash(entry) }
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

    /// The title, then who was there in grey, on one line; the title keeps
    /// its room and the names give way.
    private var denseText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let title = entry.title {
                Text(title).font(.system(size: 13)).lineLimit(1).layoutPriority(1)
                if let people = peopleLine {
                    Text(people).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(peopleLine ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var leading: String {
        switch look {
        case .time: Format.time(entry.started)
        case .date: Format.shortDate(entry.started)
        case .dense: Format.weekdayDay(entry.started)
        }
    }

    private var leadingWidth: CGFloat {
        switch look {
        case .time: Format.timeColumnWidth
        case .date(let width): width
        case .dense: Format.weekdayDayColumnWidth
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
