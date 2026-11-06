import AppKit
import SwiftUI
import TapeUpCore

/// The last few recordings, grouped by day, each one click from its path or
/// its card. The time sits in its own column, so naming a recording never moves it.
struct RecentView: View {
    @Bindable var model: AppModel

    private var days: [(day: String, entries: [RecordingEntry])] {
        var groups: [(day: String, entries: [RecordingEntry])] = []
        for entry in model.recent {
            let day = Format.day(entry.started)
            if groups.last?.day == day {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                // Undo takes the header's place, so the list never shifts.
                if model.trashed != nil {
                    Text("Moved to the Trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Button("Undo", action: model.undoTrash)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 6)
                } else if !model.recent.isEmpty {
                    SectionLabel(text: "Recent")
                }
                Spacer()
                IconButton(symbol: "folder", help: "Open recordings folder", action: model.openRoot)
                MoreMenu(model: model)
            }
            .padding(.leading, Style.inset)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 0) {
                let groups = days
                ForEach(groups, id: \.day) { group in
                    if groups.count > 1 || group.day != "Today" {
                        Text(group.day)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.top, 4)
                    }
                    ForEach(group.entries) { entry in
                        RecentRow(entry: entry, model: model)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 6)
    }
}

struct RecentRow: View {
    let entry: RecordingEntry
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.time(entry.started))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Format.timeColumnWidth, alignment: .leading)
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
            Spacer(minLength: 4)
            if hovering || copied {
                HStack(spacing: 0) {
                    IconButton(symbol: "trash", help: "Move to Trash", size: 22) { model.trash(entry) }
                    IconButton(symbol: "folder", help: "Show in Finder", size: 22) { model.reveal(entry) }
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy path", size: 22, action: copy)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            Text(Format.duration(entry.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.open(entry) }
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

/// App-wide settings, also on right-click of the menu-bar icon.
struct MoreMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Button("People…", action: model.openPeople)
            Button("Change Recordings Folder…") { FolderChooser.choose(model: model) }
                .disabled(model.phase != .idle)
            Toggle("Floating Controls While Recording", isOn: $model.showsFloatingControls)
            Toggle("Open at Login", isOn: launchAtLogin)
            Divider()
            Button("Quit TapeUp") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("TapeUp")
        .accessibilityLabel("TapeUp menu")
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: {
                _ = model.launchAtLoginRevision
                return model.launchAtLogin
            },
            set: { model.launchAtLogin = $0 })
    }
}

/// Picks a new recordings folder and asks whether the recordings move with it.
@MainActor
enum FolderChooser {
    static func choose(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = model.root.deletingLastPathComponent()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = model.allEntries.count
        guard count > 0 else { return model.changeRoot(to: url, moving: false) }
        let alert = NSAlert()
        alert.messageText =
            "Move your \(count == 1 ? "recording" : "\(count) recordings") to \u{201C}\(url.lastPathComponent)\u{201D}?"
        alert.informativeText =
            "New recordings go to the new folder either way. Recordings you leave behind stay in \u{201C}\(model.root.lastPathComponent)\u{201D} and no longer show in TapeUp."
        alert.addButton(withTitle: "Move Recordings")
        alert.addButton(withTitle: "Leave Them")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: model.changeRoot(to: url, moving: true)
        case .alertSecondButtonReturn: model.changeRoot(to: url, moving: false)
        default: break
        }
    }
}
