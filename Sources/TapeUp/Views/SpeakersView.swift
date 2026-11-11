import SwiftUI
import TapeUpCore

/// "Label speakers" and, once found, one row per voice to name. Appears
/// once the transcript is ready; the count chips above set how many voices.
struct SpeakersView: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry

    var body: some View {
        let result = shown(model.speakers.result(for: entry))
        let work = model.speakers.work(on: entry)
        VStack(alignment: .leading, spacing: 6) {
            if let result, work == nil || work == .failed {
                HStack {
                    SectionLabel(text: "Speakers")
                    Spacer()
                    if !result.suggested.isEmpty {
                        UseButton(help: "Use the suggested names") { model.speakers.acceptSuggestedNames(in: entry) }
                    } else if result.estimated, result.voices.count > 0 {
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
                    VoiceRow(
                        model: model, entry: entry, result: result, voice: voice, name: result.names[voice.id],
                        suggested: result.suggested[voice.id])
                }
            } else {
                status(work)
            }
        }
        .animation(.easeOut(duration: 0.2), value: work)
        // Playback stops with the page, a recount, a relabel or a recording starting.
        .onDisappear { model.speakers.player.stop() }
        .onChange(of: result?.assigned) { model.speakers.player.stop() }
        .onChange(of: work) { model.speakers.player.stop() }
        .onChange(of: model.phase == .idle) { model.speakers.player.stop() }
    }

    /// Suggestions show only while an agent is on.
    private func shown(_ result: SpeakerResult?) -> SpeakerResult? {
        guard var result, model.agents.chosen == nil else { return result }
        result.suggested = [:]
        return result
    }

    @ViewBuilder private func status(_ work: Speakers.Work?) -> some View {
        switch work {
        case .downloading(let fraction):
            working("Getting the speaker model · \(Int((fraction * 100).rounded()))%")
        case .waiting:
            working("Waiting for the transcript to finish…")
        case .listening:
            working("Finding voices…")
        case .failed:
            HStack(spacing: 4) {
                Text("Speakers could not be labeled.").font(.system(size: 12)).foregroundStyle(.secondary)
                if entry.hasAudio { LinkButton("Try again", action: model.labelSpeakers) }
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

/// One voice: a name to pick, how long it talked, a line it said, and a
/// play button that plays all it said, the line following the words.
private struct VoiceRow: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry
    let result: SpeakerResult
    let voice: Voice
    let name: String?
    let suggested: String?

    var body: some View {
        let player = model.speakers.player
        let playing = player.isPlaying(voice.id, in: entry)
        let quote = playing ? player.line ?? voice.quote : voice.quote
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                NamePicker(model: model, entry: entry, voice: voice, name: name, suggested: suggested)
                Spacer(minLength: 4)
                Text(Format.length(voice.seconds))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if FileManager.default.fileExists(atPath: entry.audio.path) {
                    // Same size playing or not, so the row never moves.
                    IconButton(
                        symbol: playing ? "stop.fill" : "play.fill",
                        help: model.phase != .idle
                            ? "Play once the recording stops" : playing ? "Stop" : "Play this voice",
                        size: 22, quiet: playing
                    ) {
                        player.toggle(voice.id, in: entry, result: result)
                    }
                    .disabled(model.phase != .idle)
                    .clickTarget("Play voice \(voice.id)")
                }
            }
            Text("\u{201C}\(quote)\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(playing ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 6)
                .hoverHelp(quote)
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
    let suggested: String?
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
                // A suggestion reads grey, like a suggested title, until taken.
                Text(name ?? suggested ?? "Voice \(voice.id)")
                    .font(.system(size: 12, weight: name == nil && suggested != nil ? .regular : .medium))
                    .foregroundStyle(name != nil ? .primary : suggested != nil ? .tertiary : .secondary)
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
        .hoverHelp(
            name != nil ? "Rename this voice" : suggested.map { "Suggested: \($0). Use takes it" } ?? "Name this voice"
        )
        .accessibilityLabel(
            name.map { "Voice \(voice.id), \($0)" } ?? suggested.map { "Voice \(voice.id), suggested \($0)" }
                ?? "Voice \(voice.id), unnamed")
    }

    private func pick(_ person: String) -> some View {
        Button {
            model.speakers.name(voice.id, person, in: entry)
        } label: {
            if person == name { Label(person, systemImage: "checkmark") } else { Text(person) }
        }
    }
}
