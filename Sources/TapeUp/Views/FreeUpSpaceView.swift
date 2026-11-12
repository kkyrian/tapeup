import SwiftUI
import TapeUpCore

/// Recordings that still hold their audio, to clear it in one go: age
/// chips, then the recordings in three groups by what still needs the
/// audio, and one action at the bottom that confirms in place.
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

    /// The list's height whatever it holds, so filtering never moves the page's edges.
    static let listHeight: CGFloat = 330

    private var filter: SpaceFilter { model.spaceFilter }

    var body: some View {
        let candidates = model.spaceCandidates
        let unkept = candidates.filter { !$0.keepAudio }
        let kept = candidates.filter(\.keepAudio)
        let shown = filter.kept ? kept : unkept.filter { filter.age.matches($0) }
        let groups = Dictionary(grouping: shown, by: model.spaceGroup)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Free up space", back: model.closeFreeUpSpace) {
                EmptyView()
            } trailing: {
                Text("Audio \(Format.size(candidates.reduce(0) { $0 + model.audioBytes($1) }))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            chips(unkept: unkept, kept: kept).padding(.top, 10)
            list(shown, groups: groups)
                .frame(height: Self.listHeight, alignment: .top)
                .padding(.top, 10)
            Divider().padding(.top, 6)
            footer(groups: groups)
                .padding(.top, 8)
        }
        .padding(Style.inset)
        .onChange(of: model.spaceFilter) { confirming = nil }
    }

    // MARK: Chips

    private func chips(unkept: [RecordingEntry], kept: [RecordingEntry]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            // An age nothing is past yet has no chip; the one picked always shows.
            ForEach(
                SpaceFilter.Age.allCases.filter { age in
                    age == .all || age == filter.age || unkept.contains { age.matches($0) }
                }, id: \.self
            ) { age in
                FilterChip(
                    title: age.title, count: unkept.filter { age.matches($0) }.count,
                    on: !filter.kept && filter.age == age
                ) {
                    model.spaceFilter = SpaceFilter(age: age, kept: false)
                }
            }
            FilterChip(title: "Kept", count: kept.count, on: filter.kept) {
                model.spaceFilter.kept.toggle()
            }
            .hoverHelp("Recordings you keep: Free up space leaves their audio alone")
        }
    }

    // MARK: The list

    @ViewBuilder
    private func list(_ shown: [RecordingEntry], groups: [AppModel.SpaceGroup: [RecordingEntry]]) -> some View {
        if shown.isEmpty {
            Text(emptyText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let present = AppModel.SpaceGroup.allCases.filter { !(groups[$0] ?? []).isEmpty }
                    ForEach(Array(present.enumerated()), id: \.element) { index, group in
                        if let entries = groups[group] {
                            heading(group, entries).padding(.top, index == 0 ? 2 : 14).padding(.bottom, 2)
                            ForEach(entries.sorted { $0.started > $1.started }) { entry in
                                RecordingRow(
                                    entry: entry, model: model, look: .dense,
                                    size: Format.size(model.audioBytes(entry)))
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .padding(.horizontal, -6)
        }
    }

    private var emptyText: String {
        if filter.kept { return "Nothing kept yet. Keep a recording from its card\nto leave its audio alone." }
        if filter.age != .all { return "No recording \(filter.age.title.lowercased()) old holds audio" }
        return "No recording holds audio"
    }

    /// The group's name and count, with what it needs before its audio can go.
    private func heading(_ group: AppModel.SpaceGroup, _ entries: [RecordingEntry]) -> some View {
        let bytes = entries.reduce(0) { $0 + model.audioBytes($1) }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title(group)).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
            Text("\(entries.count)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                .hoverHelp("\(Format.size(bytes)) of audio")
            Spacer(minLength: 4)
            if !filter.kept { groupActions(group, entries) }
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    private func title(_ group: AppModel.SpaceGroup) -> String {
        if filter.kept {
            return group == .ready ? "Kept" : group == .unlabeled ? "Kept, not labeled" : "Kept, no transcript"
        }
        switch group {
        case .ready: return "Ready"
        case .unlabeled: return "Speakers not labeled"
        case .untranscribed: return "No transcript"
        }
    }

    @ViewBuilder
    private func groupActions(_ group: AppModel.SpaceGroup, _ entries: [RecordingEntry]) -> some View {
        switch group {
        case .ready:
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
                LinkButton("Trash…") { confirming = .trashUntranscribed }
                    .hoverHelp("Move these recordings to the Trash: without a transcript, the audio is all they have")
            }
        }
    }

    // MARK: The footer

    /// One line that says what will happen or just did, over one action.
    @ViewBuilder
    private func footer(groups: [AppModel.SpaceGroup: [RecordingEntry]]) -> some View {
        let ready = filter.kept ? [] : (groups[.ready] ?? []).filter(model.canRemoveAudio)
        let readyBytes = ready.reduce(0) { $0 + model.audioBytes($1) }
        let untranscribed =
            filter.kept
            ? [] : (groups[.untranscribed] ?? []).filter { !model.transcription.isWorking(on: $0) }
        VStack(alignment: .leading, spacing: 6) {
            line(ready: ready, untranscribed: untranscribed, groups: groups)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
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
            case _ where filter.kept:
                // The action's room, empty: these are never cleared here.
                Color.clear.frame(height: 32)
            default:
                FlatButton(kind: .primary, action: { confirming = .removeAudio }) {
                    Text(
                        ready.isEmpty
                            ? "Nothing ready to remove"
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
        ready: [RecordingEntry], untranscribed: [RecordingEntry], groups: [AppModel.SpaceGroup: [RecordingEntry]]
    ) -> some View {
        switch confirming {
        case .removeAudio where !ready.isEmpty:
            let unnamed = ready.filter(model.hasUnnamedVoices).count
            Text(
                unnamed > 0
                    ? "Transcripts stay. \(unnamed) have voices you can't play after."
                    : "Remove audio from \(ready.count)? Transcripts and names stay.")
        case .trashUntranscribed where !untranscribed.isEmpty:
            Text("Move \(untranscribed.count) with no transcript to the Trash?")
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
            } else if filter.kept {
                Text("Free up space never clears these")
            } else {
                let waiting = (groups[.unlabeled]?.count ?? 0) + (groups[.untranscribed]?.count ?? 0)
                Text(
                    waiting == 0
                        ? "Transcripts, names and voices stay"
                        : ready.isEmpty
                            ? "Label or transcribe them first"
                            : "\(waiting) more need speakers or a transcript first")
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
