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
                    Label(card.copied ? "Copied" : "Copy path", systemImage: card.copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                FlatButton(kind: .plain, action: { model.reveal(card.entry) }) {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .disabled(card.finishing)
            if card.copied {
                CopyPeek(entry: card.entry)
            }
            Divider().padding(.vertical, 2)
            WhoWasThereView(model: model, people: card.entry.people)
        }
        .padding(Style.inset)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            IconButton(
                symbol: card.justRecorded ? "xmark" : "chevron.left", help: card.justRecorded ? "Close" : "Back",
                action: model.closeCard)
            VStack(alignment: .leading, spacing: 1) {
                TitleField(entry: card.entry, rename: model.setTitle)
                HStack(spacing: 4) {
                    if card.finishing {
                        ProgressView().controlSize(.mini)
                        Text("Saving…")
                    } else {
                        if card.justRecorded {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                            Text("Saved ·")
                        }
                        Text(subtitle).monospacedDigit()
                    }
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

    /// The length, and once renamed also when it was, since the title no
    /// longer says so.
    private var subtitle: String {
        let duration = Format.duration(card.entry.duration)
        return card.entry.title == nil ? duration : "\(Format.when(card.entry.started)) · \(duration)"
    }
}

/// The recording's name, renamed in place: click it, type, Return. Untitled
/// recordings go by when they started.
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
                TextField(Format.when(entry.started), text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
                    .onAppear { focused = true }
                    .padding(.horizontal, 4)
                    .background(Style.fill, in: .rect(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 1))
            } else {
                Button {
                    text = entry.title ?? ""
                    editing = true
                } label: {
                    HStack(spacing: 5) {
                        Text(entry.title ?? Format.when(entry.started)).lineLimit(1).truncationMode(.tail)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                    .padding(.horizontal, 4)
                    .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 4))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Rename")
                .accessibilityLabel("\(entry.title ?? Format.when(entry.started)), rename")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(height: 20)
        .padding(.leading, -4)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry.title ?? "") { rename(text) }
    }
}

/// The two lines Copy path just put on the clipboard, so you can trust what
/// your agent will receive.
struct CopyPeek: View {
    let entry: RecordingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            line("folder", Format.short(entry.folder))
            line("audio", Format.short(entry.audio))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Style.fill, in: .rect(cornerRadius: 6, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":").foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.head)
        }
    }
}
