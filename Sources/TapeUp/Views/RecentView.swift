import AppKit
import SwiftUI
import TapeUpCore

/// The last few recordings, each one click from its path or its card.
struct RecentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                SectionLabel(text: "Recent")
                Spacer()
                IconButton(symbol: "folder", help: "Open recordings folder", action: model.openRoot)
                MoreMenu(model: model)
            }
            .padding(.leading, Style.inset)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            VStack(spacing: 0) {
                if let trashed = model.trashed {
                    TrashedRow(entry: trashed.entry, undo: model.undoTrash)
                }
                if model.peopleList.people.isEmpty, model.peopleList.you == nil {
                    SetupPeopleRow(model: model)
                }
                ForEach(model.recent) { entry in
                    RecentRow(entry: entry, model: model)
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
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title ?? Format.when(entry.started)).font(.system(size: 13)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hovering || copied {
                IconButton(symbol: "trash", help: "Move to Trash") { model.trash(entry) }
                IconButton(symbol: "folder", help: "Show in Finder") { model.reveal(entry) }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy path", action: copy)
            }
            Text(Format.duration(entry.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(height: detail == nil ? 32 : 40)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    /// Once renamed, the time moves to the second line, ahead of the people.
    private var detail: String? {
        let parts = [entry.title == nil ? nil : Format.when(entry.started), peopleLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

/// Stands where a trashed recording was, with a way back.
struct TrashedRow: View {
    let entry: RecordingEntry
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text("Moved \(entry.title ?? Format.when(entry.started)) to the Trash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button("Undo", action: undo)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
    }
}

struct MoreMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Button("People…", action: model.openPeople)
            Button("Change Recordings Folder…", action: chooseFolder).disabled(model.phase != .idle)
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
        .help("More")
        .accessibilityLabel("More")
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: {
                _ = model.launchAtLoginRevision
                return model.launchAtLogin
            },
            set: { model.launchAtLogin = $0 })
    }

    private func chooseFolder() {
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

/// Until there is a people list: one row that leads to it.
struct SetupPeopleRow: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button(action: model.openPeople) {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                Text("Add the people you meet").font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
