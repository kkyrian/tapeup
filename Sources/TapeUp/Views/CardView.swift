import SwiftUI
import TapeUpCore

/// One recording: saved, its paths one click away, and who was there.
struct CardView: View {
    @Bindable var model: AppModel
    let card: AppModel.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 8) {
                Button {
                    model.copy(card.entry)
                } label: {
                    Label(card.copied ? "Copied" : "Copy path", systemImage: card.copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.gradient, in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                Button {
                    model.reveal(card.entry)
                } label: {
                    Label("Open in Finder", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
            }
            if card.copied {
                CopyPeek(entry: card.entry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Divider()
            WhoWasThereView(model: model, people: card.entry.people)
        }
        .padding(14)
        .animation(.snappy(duration: 0.25), value: card.copied)
        .animation(.snappy(duration: 0.25), value: card.finishing)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if card.finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Text("\(Format.long(card.entry.started)) · Mac audio + mic")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: model.closeCard) {
                Image(systemName: card.justRecorded ? "xmark" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.07), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(card.justRecorded ? "Close" : "Back")
            .accessibilityLabel(card.justRecorded ? "Close" : "Back")
        }
    }

    private var title: String {
        card.finishing ? "Saving…" : "Saved · \(Format.duration(card.entry.duration))"
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
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 7, style: .continuous))
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
