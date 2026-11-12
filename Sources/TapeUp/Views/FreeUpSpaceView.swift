import SwiftUI
import TapeUpCore

/// Recordings that still hold their audio, to clear it in one go: age
/// chips, then the recordings in three groups by what still needs the
/// audio, each with a lock that keeps its audio, and one action at the
/// bottom that confirms in place.
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
        let kept = candidates.filter(\.keepAudio)
        // Locked ones stay in place, so locking never moves the list.
        let shown = filter.kept ? kept : candidates.filter { filter.age.matches($0) }
        let groups = Dictionary(grouping: shown, by: model.spaceGroup)
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Free up space", back: model.closeFreeUpSpace) {
                EmptyView()
            } trailing: {
                Text("Audio \(Format.size(candidates.reduce(0) { $0 + model.audioBytes($1) }))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            chips(candidates, kept: kept).padding(.top, 10)
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

    private func chips(_ candidates: [RecordingEntry], kept: [RecordingEntry]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            // Every chip always, so the rows never reflow as counts change.
            ForEach(SpaceFilter.Age.allCases, id: \.self) { age in
                FilterChip(
                    title: age.title, count: candidates.filter { age.matches($0) }.count,
                    on: !filter.kept && filter.age == age
                ) {
                    model.spaceFilter = SpaceFilter(age: age, kept: false)
                }
            }
            FilterChip(title: "Kept", count: kept.count, on: filter.kept) {
                model.spaceFilter.kept.toggle()
            }
            .hoverHelp("Recordings you locked: Free up space leaves their audio")
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
                                    entry: entry, model: model, look: .monthDay,
                                    size: Format.size(model.audioBytes(entry)), keepable: true)
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
        if filter.kept { return "Nothing kept yet. Lock a recording on this page\nand Free up space leaves its audio." }
        if filter.age != .all { return "No recording \(filter.age.title.lowercased()) old holds audio" }
        return "No recording holds audio"
    }

    /// The group's name and count, then, for a group not ready yet, why
    /// and what to do first.
    private func heading(_ group: AppModel.SpaceGroup, _ entries: [RecordingEntry]) -> some View {
        let bytes = entries.reduce(0) { $0 + model.audioBytes($1) }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title(group)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(entries.count) · \(Format.size(bytes))")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 20)
            if !filter.kept, group != .ready {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group == .unlabeled ? "Labeling needs the audio" : "Only audio, so far")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    groupActions(group, entries)
                }
                .frame(height: 18)
            }
        }
        .padding(.horizontal, 6)
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
                LinkButton("Trash them…") { confirming = .trashUntranscribed }
                    .hoverHelp("Move these recordings to the Trash: without a transcript, the audio is all they have")
            }
        }
    }

    // MARK: The footer

    /// One line that says what will happen or just did, over one action.
    @ViewBuilder
    private func footer(groups: [AppModel.SpaceGroup: [RecordingEntry]]) -> some View {
        let ready = filter.kept ? [] : (groups[.ready] ?? []).filter { !$0.keepAudio && model.canRemoveAudio($0) }
        let readyBytes = ready.reduce(0) { $0 + model.audioBytes($1) }
        let untranscribed =
            filter.kept
            ? [] : (groups[.untranscribed] ?? []).filter { !$0.keepAudio && !model.transcription.isWorking(on: $0) }
        VStack(alignment: .leading, spacing: 6) {
            // Two lines' room always, so confirming never moves the action.
            line(ready: ready, untranscribed: untranscribed, groups: groups)
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
            } else if filter.kept {
                Text("Free up space never clears these")
            } else {
                let unkept = { (group: AppModel.SpaceGroup) in (groups[group] ?? []).filter { !$0.keepAudio }.count }
                let waiting = unkept(.unlabeled) + unkept(.untranscribed)
                let locked = groups.values.joined().filter(\.keepAudio).count
                Text(
                    (waiting == 0
                        ? "Transcripts, names and voices stay"
                        : ready.isEmpty
                            ? "Label or transcribe them first"
                            : "\(waiting) more need speakers or a transcript first")
                        + (locked == 1
                            ? "\n1 locked recording keeps its audio"
                            : locked > 1
                                ? "\n\(locked) locked recordings keep their audio"
                                : ready.isEmpty ? "" : "\nLock a row to keep its audio"))
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
