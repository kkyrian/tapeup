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
            if let result, work == nil || work == .failed {
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
                    VoiceRow(
                        model: model, entry: entry, result: result, voice: voice, name: result.names[voice.id],
                        filled: result.names[voice.id] != nil && result.provenance(for: voice.id).origin == .filled)
                }
                PastFillStrip(model: model, entry: entry)
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
    /// TapeUp filled the name in from the voice and nobody has checked it.
    let filled: Bool

    var body: some View {
        let player = model.speakers.player
        let playing = player.isPlaying(voice.id, in: entry)
        let quote = playing ? player.line ?? voice.quote : voice.quote
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                NamePicker(model: model, entry: entry, voice: voice, name: name, filled: filled)
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
                        // Listening and leaving the name is the check of a filled-in one.
                        if !playing { model.speakers.confirm(voice.id, in: entry) }
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
    let filled: Bool
    @State private var hovering = false

    var body: some View {
        let others = model.suggestions(matching: "", excluding: entry.people.names, limit: 12)
        Menu {
            ForEach(entry.people.names, id: \.self) { person in pick(person) }
            if !entry.people.names.isEmpty, !others.isEmpty { Divider() }
            ForEach(others, id: \.self) { person in pick(person) }
            if name != nil {
                Divider()
                Button("No name") { model.nameVoice(voice.id, nil, in: entry) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(name ?? "Voice \(voice.id)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(name != nil ? .primary : .secondary)
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
            filled
                ? "Filled in from their voice. Pick someone else if it's wrong"
                : name != nil ? "Rename this voice" : "Name this voice"
        )
        .accessibilityLabel(name.map { "Voice \(voice.id), \($0)" } ?? "Voice \(voice.id), unnamed")
    }

    private func pick(_ person: String) -> some View {
        Button {
            model.nameVoice(voice.id, person, in: entry)
        } label: {
            if person == name { Label(person, systemImage: "checkmark") } else { Text(person) }
        }
    }
}

/// After a filled-in name is corrected: the earlier meetings where the same
/// wrong name was filled in for a voice like this one, offered for the same
/// fix. Nothing changes without a click.
private struct PastFillStrip: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry

    private var stamp: String { RecordingLibrary.stamp(of: entry.folder) }

    var body: some View {
        if let offer = model.speakers.offer, offer.stamp == stamp {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "TapeUp also filled in \(offer.from) for a similar voice in \(count(offer.hits.count)). Change \(offer.hits.count == 1 ? "it" : "them") to \(offer.to)?"
                )
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                // Three at most, newest first; Change all covers the rest.
                ForEach(offer.hits.sorted { $0.stamp > $1.stamp }.prefix(3), id: \.stamp) { hit in
                    PastFillRow(model: model, hit: hit, single: offer.hits.count == 1)
                }
                if offer.hits.count > 3 {
                    Text("and \(offer.hits.count - 3) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    LinkButton(offer.hits.count == 1 ? "Change it" : "Change all \(offer.hits.count)") {
                        model.speakers.applyOffer()
                    }
                    .clickTarget("Change all past fills")
                    LinkButton(offer.hits.count == 1 ? "Leave it" : "Leave them", action: model.speakers.leaveOffer)
                }
                .padding(.leading, -6)
            }
            .padding(10)
            .background(Style.fill, in: .rect(cornerRadius: 8, style: .continuous))
            .padding(.top, 4)
        } else if let done = model.speakers.offerDone, done.stamp == stamp {
            HStack(spacing: 2) {
                Text("Changed in \(count(done.count))").font(.system(size: 11)).foregroundStyle(.secondary)
                LinkButton("Undo", action: model.speakers.undoOffer).frame(height: 13)
            }
            .padding(.top, 4)
        }
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 earlier meeting" : "\(n) earlier meetings" }
}

/// One earlier meeting in the strip: when and what, the voice to play or a
/// line it said, and Change for just this one.
private struct PastFillRow: View {
    @Bindable var model: AppModel
    let hit: VoiceLibrary.PastFill
    /// The only one offered: the strip's own button changes it.
    let single: Bool

    var body: some View {
        let entry = RecordingLibrary(root: model.root).folder(withStamp: hit.stamp).flatMap(RecordingLibrary.entry(at:))
        let result = entry.flatMap { SpeakerLabels.result(in: $0.folder) }
        let player = model.speakers.player
        let playable = entry.map { $0.hasAudio } ?? false
        let playing = entry.map { player.isPlaying(hit.voice, in: $0) } ?? false
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(entry.map { [$0.title, Format.day($0.started)].compactMap { $0 }.joined(separator: " · ") } ?? "")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if playable, let entry, let result {
                    IconButton(
                        symbol: playing ? "stop.fill" : "play.fill", help: playing ? "Stop" : "Play this voice",
                        size: 20, quiet: playing
                    ) {
                        player.toggle(hit.voice, in: entry, result: result)
                    }
                    .disabled(model.phase != .idle)
                }
                if !single { LinkButton("Change") { model.speakers.applyOffer(only: hit) } }
            }
            Text("\u{201C}\(playing ? player.line ?? hit.quote : hit.quote)\u{201D}")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
