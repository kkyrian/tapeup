import AppKit
import SwiftUI
import TapeUpCore

/// The last few recordings, each one click from its path or its card.
struct RecentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("Recent").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button("Open folder", action: model.openRoot)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                MoreMenu(model: model)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if model.recent.isEmpty {
                Text("Your recordings will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                if model.peopleList.people.isEmpty {
                    SetupPeopleRow(model: model).padding(.horizontal, 6)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recent) { entry in
                        RecentRow(entry: entry, model: model)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.bottom, 8)
    }
}

struct RecentRow: View {
    let entry: RecordingEntry
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.when(entry.started)).font(.system(size: 13))
                if let people = peopleLine {
                    Text(people).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hovering {
                RowIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy path") {
                    model.copy(entry)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                RowIconButton(symbol: "person.2", help: "Who was there") { model.open(entry) }
            }
            Text(Format.duration(entry.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { model.open(entry) }
        .animation(.snappy(duration: 0.15), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(Format.when(entry.started)), \(Format.spokenDuration(entry.duration))")
        .accessibilityAction(named: "Copy path") { model.copy(entry) }
        .accessibilityAction(named: "Open") { model.open(entry) }
    }

    private var peopleLine: String? {
        let people = entry.people
        guard !people.isEmpty else { return nil }
        let count = people.count.map { $0 == 1 ? "Just you" : "\($0) people" }
        let names = people.names.isEmpty ? nil : people.names.joined(separator: ", ")
        return [count, names].compactMap { $0 }.joined(separator: " · ")
    }
}

struct RowIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 22)
                .background(hovering ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .transition(.opacity)
    }
}

struct MoreMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Button("Open Recordings Folder", action: model.openRoot)
            Button("Change Recordings Folder…", action: chooseFolder)
            Button("People…", action: model.openPeople)
            Toggle("Open at Login", isOn: launchAtLogin)
            Divider()
            Button("Quit TapeUp") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
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
        if panel.runModal() == .OK, let url = panel.url { model.root = url }
    }
}

/// First-run nudge: let an AI assistant list the people you record with.
struct SetupPeopleRow: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button(action: model.openPeople) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add the people you meet").font(.system(size: 13, weight: .medium))
                    Text("Your AI assistant writes the list in one step")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
