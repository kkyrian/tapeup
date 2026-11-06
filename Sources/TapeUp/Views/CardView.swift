import SwiftUI
import TapeUpCore

/// One recording: saved, its paths one click away, and who was there.
struct CardView: View {
    @Bindable var model: AppModel
    let card: AppModel.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                FlatButton(kind: .primary, action: { model.copy(card.entry) }) {
                    Label(
                        model.copiedFlash ? "Copied" : "Copy path",
                        systemImage: model.copiedFlash ? "checkmark" : "doc.on.doc"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                FlatButton(kind: .plain, action: { model.reveal(card.entry) }) {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .disabled(card.finishing)
            .help(card.entry.clipboardText)
            Divider().padding(.vertical, 2)
            WhoWasThereView(model: model, people: card.entry.people)
        }
        .padding(Style.inset)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            IconButton(
                symbol: card.justRecorded ? "xmark" : "chevron.left", help: card.justRecorded ? "Close" : "Back",
                action: model.closeCard
            )
            .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            TitleField(entry: card.entry, model: model) {
                HStack(spacing: 4) {
                    if card.finishing {
                        ProgressView().controlSize(.mini)
                        Text("Saving…")
                    } else if card.justRecorded {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        Text("Saved ·")
                    }
                    Text("\(Format.when(card.entry.started)) · \(Format.length(card.entry.duration))")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if !card.finishing {
                IconButton(symbol: "trash", help: "Move to Trash") { model.trash(card.entry) }
                    .padding(.leading, 4)
            }
        }
    }
}

/// The recording's name and when it was made. The whole block renames: click
/// anywhere on it, type, then Return or a click elsewhere keeps the name and
/// Escape puts the old one back. The time is never part of the name.
struct TitleField<Subtitle: View>: View {
    let entry: RecordingEntry
    let model: AppModel
    @ViewBuilder let subtitle: Subtitle

    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @State private var frame = CGRect.zero
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        // One container, so its modifiers see a single view whether or not
        // the name is being edited.
        ZStack {
            if editing {
                block
            } else {
                // A button, not a tap gesture: it takes the first click even
                // while the panel is not focused.
                Button(action: begin) { block }
                    .buttonStyle(.plain)
                    .help("Rename")
                    .accessibilityLabel(entry.title.map { "\($0), rename" } ?? "Add a title")
            }
        }
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            frame = $0
        }
        .onDisappear(perform: commit)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if editing {
                    TextField("Title", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand(perform: cancel)
                        .onChange(of: focused) { _, now in if !now { commit() } }
                } else {
                    HStack(spacing: 5) {
                        Text(entry.title ?? "Add a title")
                            .foregroundStyle(entry.title == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(height: 18)
            subtitle
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            editing ? Style.fill : hovering ? Style.fillHover : .clear,
            in: .rect(cornerRadius: Style.corner - 2, style: .continuous)
        )
        .padding(.leading, -6)
        .contentShape(.rect)
    }

    private func begin() {
        text = entry.title ?? ""
        editing = true
        model.renaming = true
        model.focusPanel()
        DispatchQueue.main.async { focused = true }
        // The panel never loses focus to a click inside it, so a click outside
        // the field ends the rename here.
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
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry.title ?? "") { model.setTitle(text) }
    }

    private func cancel() {
        guard editing else { return }
        finish()
    }

    private func finish() {
        editing = false
        model.renaming = false
        stopWatchingClicks()
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
