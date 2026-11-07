import SwiftUI
import TapeUpCore

/// "Label speakers" and, once found, one row per voice to name. Appears
/// once the transcript is ready; the count chips above set how many voices.
struct SpeakersView: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry

    var body: some View {
        let result = model.speakers.result(for: entry)
        let work = model.speakers.work(on: entry)
        VStack(alignment: .leading, spacing: 6) {
            if let result, work != .listening, !isDownloading(work) {
                HStack {
                    SectionLabel(text: "Speakers")
                    Spacer()
                    if result.estimated, result.voices.count > 0 {
                        Text("Estimated · tap a count to change")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 16)
                if result.voices.isEmpty {
                    Text("No voices found.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(result.voices) { voice in
                    VoiceRow(model: model, entry: entry, voice: voice, name: result.names[voice.id])
                }
            } else {
                status(work)
            }
        }
        .animation(.easeOut(duration: 0.2), value: work)
    }

    private func isDownloading(_ work: Speakers.Work?) -> Bool {
        if case .downloading = work { return true }
        return false
    }

    @ViewBuilder private func status(_ work: Speakers.Work?) -> some View {
        switch work {
        case .downloading(let fraction):
            working("Getting the speaker model · \(Int((fraction * 100).rounded()))%")
        case .listening:
            working("Finding voices…")
        case .failed:
            HStack(spacing: 4) {
                Text("Speakers could not be labeled.").font(.system(size: 12)).foregroundStyle(.secondary)
                LinkButton("Try again", action: model.labelSpeakers)
            }
            .frame(height: 22)
        case nil:
            LinkButton("Label speakers", action: model.labelSpeakers)
                .padding(.leading, -6)
                .hoverHelp(
                    entry.people.count.map { "Find \($0) voice\($0 == 1 ? "" : "s") on this Mac" }
                        ?? "Find who spoke when, on this Mac")
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(height: 22)
    }
}

/// One voice: a name to pick, how long it talked, and a line it said.
private struct VoiceRow: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry
    let voice: Voice
    let name: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                NamePicker(model: model, entry: entry, voice: voice, name: name)
                Spacer(minLength: 4)
                Text(Format.length(voice.seconds))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("\u{201C}\(voice.quote)\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 6)
                .hoverHelp(voice.quote)
        }
    }
}

/// The voice's name as a menu: this recording's people first, then everyone
/// else known.
private struct NamePicker: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry
    let voice: Voice
    let name: String?
    @State private var hovering = false

    var body: some View {
        let others = model.suggestions(matching: "", excluding: entry.people.names, limit: 12)
        Menu {
            ForEach(entry.people.names, id: \.self) { person in pick(person) }
            if !entry.people.names.isEmpty, !others.isEmpty { Divider() }
            ForEach(others, id: \.self) { person in pick(person) }
            if name != nil {
                Divider()
                Button("No name") { model.speakers.name(voice.id, nil, in: entry) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(name ?? "Voice \(voice.id)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(name == nil ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(hovering ? Style.fillHover : Style.fill, in: .rect(cornerRadius: 5, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .hoverHelp(name == nil ? "Name this voice" : "Rename this voice")
        .accessibilityLabel(name.map { "Voice \(voice.id), \($0)" } ?? "Voice \(voice.id), unnamed")
    }

    private func pick(_ person: String) -> some View {
        Button {
            model.speakers.name(voice.id, person, in: entry)
        } label: {
            if person == name { Label(person, systemImage: "checkmark") } else { Text(person) }
        }
    }
}
