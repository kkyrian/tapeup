import SwiftUI
import TapeUpCore

/// Recordings that still hold their audio, to clear it in one go: age
/// chips, then the recordings by what happens to them: the ones that lose
/// their audio first, then the ones that stay and why. A lock on each row
/// keeps its audio. One action at the bottom confirms in place.
struct FreeUpSpaceView: View {
    @Bindable var model: AppModel
    @State private var asked: Confirm?
    /// Set by the gallery: the footer asks this as if clicked.
    @MainActor static var staged: Confirm?
    private var confirming: Confirm? {
        get { Self.staged ?? asked }
        nonmutating set { asked = newValue }
    }

    enum Confirm { case removeAudio, trashUntranscribed }

    /// What happens to a listed recording.
    enum Section: CaseIterable {
        /// The footer's action removes these, and only these.
        case remove
        /// Locked by the user: never cleared here. Next to the first, so a
        /// row locked there lands in sight.
        case locked
        /// Staying until their speakers are labeled.
        case unlabeled
        /// Staying: without a transcript, the audio is all they have.
        case untranscribed
    }

    /// The list's height whatever it holds, so filtering never moves the page's edges.
    static let listHeight: CGFloat = 330

    private var age: SpaceFilter.Age { model.spaceFilter.age }

    private func section(_ entry: RecordingEntry) -> Section {
        if entry.keepAudio { return .locked }
        switch model.spaceGroup(entry) {
        case .ready: return model.canRemoveAudio(entry) ? .remove : .unlabeled
        case .unlabeled: return .unlabeled
        case .untranscribed: return .untranscribed
        }
    }

    var body: some View {
        let candidates = model.spaceCandidates
        let shown = candidates.filter { age.matches($0) }
        let sections = Dictionary(grouping: shown, by: section)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Free up space", back: model.closeFreeUpSpace) {
                EmptyView()
            } trailing: {
                Text("Audio \(Format.size(candidates.reduce(0) { $0 + model.audioBytes($1) }))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            chips(candidates).padding(.top, 10)
            list(shown, sections: sections)
                .frame(height: Self.listHeight, alignment: .top)
                .padding(.top, 10)
            Divider().padding(.top, 6)
            footer(sections: sections)
                .padding(.top, 8)
        }
        .padding(Style.inset)
        .onChange(of: model.spaceFilter) { confirming = nil }
    }

    // MARK: Chips

    private func chips(_ candidates: [RecordingEntry]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            // Every chip always, so the rows never reflow as counts change.
            ForEach(SpaceFilter.Age.allCases, id: \.self) { age in
                FilterChip(title: age.title, count: candidates.filter { age.matches($0) }.count, on: self.age == age) {
                    model.spaceFilter = SpaceFilter(age: age)
                }
            }
        }
    }

    // MARK: The list

    @ViewBuilder
    private func list(_ shown: [RecordingEntry], sections: [Section: [RecordingEntry]]) -> some View {
        if shown.isEmpty {
            Text(age == .all ? "No recording holds audio" : "No recording \(age.title.lowercased()) old holds audio")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let present = Section.allCases.filter { !(sections[$0] ?? []).isEmpty }
                    ForEach(Array(present.enumerated()), id: \.element) { index, section in
                        if let entries = sections[section] {
                            heading(section, entries).padding(.top, index == 0 ? 2 : 14).padding(.bottom, 2)
                            ForEach(entries.sorted { $0.started > $1.started }) { entry in
                                RecordingRow(
                                    entry: entry, model: model, look: .monthDay,
                                    size: Format.size(model.audioBytes(entry)), keepable: true)
                            }
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: sections[.locked]?.map(\.id))
            }
            .scrollIndicators(.automatic)
            .padding(.horizontal, -6)
        }
    }

    /// What happens to the section's recordings, their count and size, then
    /// why they stay and what to do first.
    private func heading(_ section: Section, _ entries: [RecordingEntry]) -> some View {
        let bytes = entries.reduce(0) { $0 + model.audioBytes($1) }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title(section)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(entries.count) · \(Format.size(bytes))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            if let why = why(section) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(why).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    sectionActions(section, entries)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 6)
    }

    private func title(_ section: Section) -> String {
        switch section {
        case .remove: "These lose their audio"
        case .unlabeled: "Speakers not labeled"
        case .untranscribed: "No transcript"
        case .locked: "Locked"
        }
    }

    private func why(_ section: Section) -> String? {
        switch section {
        case .remove: nil
        case .unlabeled, .untranscribed: "Audio stays for now"
        case .locked: "Audio stays"
        }
    }

    @ViewBuilder
    private func sectionActions(_ section: Section, _ entries: [RecordingEntry]) -> some View {
        switch section {
        case .remove, .locked:
            EmptyView()
        case .unlabeled:
            let waiting = entries.filter {
                model.speakers.work(on: $0) == nil || model.speakers.work(on: $0) == .failed
            }
            if waiting.isEmpty {
                Text("Labeling").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LinkButton("Label speakers") { model.labelSpeakers(waiting) }
                    .hoverHelp("Label their speakers first, one after another, while the audio is here")
            }
        case .untranscribed:
            let waiting = entries.filter { !model.transcription.isWorking(on: $0) }
            if waiting.isEmpty {
                Text("Transcribing").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                LinkButton("Transcribe") { model.makeTranscripts(waiting) }
                    .hoverHelp("Make their transcripts first; speakers are labeled with them")
                LinkButton("Trash them…") { confirming = .trashUntranscribed }
                    .hoverHelp("Move these recordings to the Trash: without a transcript, the audio is all they have")
            }
        }
    }

    // MARK: The footer

    /// One line that says what will happen or just did, over one action.
    @ViewBuilder
    private func footer(sections: [Section: [RecordingEntry]]) -> some View {
        let ready = sections[.remove] ?? []
        let readyBytes = ready.reduce(0) { $0 + model.audioBytes($1) }
        let untranscribed = (sections[.untranscribed] ?? []).filter { !model.transcription.isWorking(on: $0) }
        VStack(alignment: .leading, spacing: 6) {
            // Two lines' room always, so confirming never moves the action.
            line(ready: ready, untranscribed: untranscribed, sections: sections)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 28, alignment: .bottomLeading)
            switch confirming {
            case .removeAudio where !ready.isEmpty:
                HStack(spacing: 8) {
                    FlatButton(kind: .destructive, action: { remove(ready) }) { Text("Remove audio") }
                        .clickTarget("Confirm remove audio")
                    FlatButton(kind: .plain, action: { confirming = nil }) { Text("Cancel") }
                }
            case .trashUntranscribed where !untranscribed.isEmpty:
                HStack(spacing: 8) {
                    FlatButton(kind: .destructive, action: { trash(untranscribed) }) { Text("Move to Trash") }
                        .clickTarget("Confirm trash recordings")
                    FlatButton(kind: .plain, action: { confirming = nil }) { Text("Cancel") }
                }
            default:
                FlatButton(kind: .primary, action: { confirming = .removeAudio }) {
                    Text(
                        ready.isEmpty
                            ? "Nothing to remove"
                            : "Remove audio from \(ready.count) · \(Format.size(readyBytes))")
                }
                .disabled(ready.isEmpty)
                .opacity(ready.isEmpty ? 0.5 : 1)
                .clickTarget("Remove audio from ready")
            }
        }
    }

    @ViewBuilder
    private func line(
        ready: [RecordingEntry], untranscribed: [RecordingEntry], sections: [Section: [RecordingEntry]]
    ) -> some View {
        switch confirming {
        case .removeAudio where !ready.isEmpty:
            let unnamed = ready.filter(model.hasUnnamedVoices).count
            let bytes = ready.reduce(0) { $0 + model.audioBytes($1) }
            Text(
                "Remove audio from \(ready.count) (\(Format.size(bytes)))?\n"
                    + (unnamed > 0
                        ? "Transcripts stay; unnamed voices in \(unnamed) lose replay."
                        : "Transcripts, names and voices stay."))
        case .trashUntranscribed where !untranscribed.isEmpty:
            Text(
                "Move \(untranscribed.count) recording\(untranscribed.count == 1 ? "" : "s") to the Trash?\n"
                    + "They have no transcript, so nothing stays.")
        default:
            if let freed = model.freedAudio {
                HStack(spacing: 2) {
                    Text("Audio from \(freed.count) moved to the Trash")
                    LinkButton("Undo", action: model.undoFreeAudio).frame(height: 13)
                }
            } else if let freed = model.freedRecordings {
                HStack(spacing: 2) {
                    Text("\(freed.count) moved to the Trash")
                    LinkButton("Undo", action: model.undoTrashUntranscribed).frame(height: 13)
                }
            } else {
                let waiting = (sections[.unlabeled]?.count ?? 0) + (sections[.untranscribed]?.count ?? 0)
                Text(
                    (waiting == 0
                        ? "Transcripts, names and voices stay"
                        : ready.isEmpty
                            ? "Label or transcribe them first"
                            : "\(waiting) more need speakers or a transcript first")
                        + (ready.isEmpty || sections[.locked] != nil ? "" : "\nLock a row to keep its audio"))
            }
        }
    }

    private func remove(_ ready: [RecordingEntry]) {
        confirming = nil
        model.freeAudio(ready)
    }

    private func trash(_ entries: [RecordingEntry]) {
        confirming = nil
        model.trashUntranscribed(entries)
    }
}
