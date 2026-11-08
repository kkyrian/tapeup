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
                    LinkButton("Undo", action: model.undoTrash)
                } else if let first = days.first {
                    // The first day names the list; no "Recent" above "Today".
                    SectionLabel(text: first.day)
                }
                Spacer()
                IconButton(symbol: "folder", help: "Open in Finder", action: model.openRoot)
                MoreMenu(model: model)
            }
            .padding(.leading, Style.inset)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 0) {
                let groups = days
                ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                    if index > 0 || model.trashed != nil {
                        SectionLabel(text: group.day)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.entries) { entry in
                        RecordingRow(entry: entry, model: model)
                    }
                }
                // Its words start where the rows' times do.
                if model.allEntries.count > model.recent.count {
                    LinkButton("Show all", action: model.openAllRecordings)
                        .clickTarget("Show all")
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 6)
    }
}

/// Where to go: Import, People and Settings, also on right-click of the menu-bar icon.
struct MoreMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        MoreButton(help: "TapeUp", badge: model.agents.needsAttention) {
            Button("Import…") { model.openImport([]) }
            Button("People…", action: model.openPeople)
            Button(model.agents.settingsTitle, action: model.openSettings)
            Divider()
            Button("Quit TapeUp") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
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
