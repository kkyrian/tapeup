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
        HStack(alignment: .top, spacing: 0) {
            IconButton(
                symbol: card.justRecorded ? "xmark" : "chevron.left", help: card.justRecorded ? "Close" : "Back",
                action: model.closeCard
            )
            .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                TitleField(entry: card.entry, rename: model.setTitle)
                HStack(spacing: 4) {
                    if card.finishing {
                        ProgressView().controlSize(.mini)
                        Text("Saving…")
                    } else if card.justRecorded {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                        Text("Saved ·")
                    }
                    Text("\(Format.when(card.entry.started)) · \(Format.duration(card.entry.duration))")
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !card.finishing {
                Menu {
                    Button("Move to Trash", role: .destructive) { model.trash(card.entry) }
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
            }
        }
    }
}

/// The recording's name, renamed in place: click it, type, Return. The time
/// is never part of the name; it stays on the line below.
struct TitleField: View {
    let entry: RecordingEntry
    let rename: (String) -> Void

    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("Title", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .onAppear { focused = true }
            } else {
                Button {
                    text = entry.title ?? ""
                    editing = true
                } label: {
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
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Rename")
                .accessibilityLabel(entry.title.map { "\($0), rename" } ?? "Add a title")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(height: 18)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry.title ?? "") { rename(text) }
    }
}
