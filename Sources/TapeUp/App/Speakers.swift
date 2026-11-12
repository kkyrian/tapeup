import Foundation
import Observation
import TapeUpCore
import TapeUpSpeech

/// Speaker labels for saved recordings, made only when asked. The first ask
/// fetches the speaker model; each recording is listened to once, and asking
/// for another number of voices refolds what was heard in a moment.
@MainActor @Observable
final class Speakers {
    enum Work: Equatable {
        case downloading(Double)
        /// A transcript is using the speech model; both would not fit.
        case waiting
        case listening
        case failed
    }

    var library: RecordingLibrary
    /// Frees the speech model before the speaker model loads; false while a
    /// transcript needs it.
    var makeRoom: () -> Bool = { true }
    /// Remembered voices: fills names in after labeling and learns from the
    /// names people choose.
    var voices: VoiceLibrary { VoiceLibrary(root: library.root) }
    /// Called after a name changes on disk, so who was there and the people list follow.
    var namesChanged: (String) -> Void = { _ in }
    var showProblem: (String) -> Void = { _ in }
    /// After a filled name is corrected: earlier meetings where the same
    /// wrong name was filled in for a voice like this one, unchecked.
    private(set) var offer: PastFillOffer?
    /// What the last Change all did, until Undo or the card changes.
    private(set) var offerDone: (stamp: String, count: Int, undo: VoiceFileUndo)?

    struct PastFillOffer {
        var stamp: String
        var voice: Int
        var from: String
        var to: String
        var hits: [VoiceLibrary.PastFill]
    }
    /// Plays a voice to name it, from the card's speaker rows.
    let player = VoicePlayer()

    /// Work in progress or failed, by recording stamp.
    private(set) var work: [String: Work] = [:]
    /// Bumped on every change, so views reading results from disk redraw.
    private(set) var version = 0
    /// The count each recording's labels should have, updated while a listen runs.
    private var wanted: [String: Int?] = [:]
    private var listening: Task<Void, Never>?

    init(library: RecordingLibrary) { self.library = library }

    func result(for entry: RecordingEntry) -> SpeakerResult? {
        _ = version
        return SpeakerLabels.result(in: entry.folder)
    }

    func work(on entry: RecordingEntry) -> Work? { work[RecordingLibrary.stamp(of: entry.folder)] }

    /// Films: shows work on a recording, or none, and redraws results.
    func stage(_ stamp: String, work now: Work?) {
        work[stamp] = now
        version += 1
    }

    /// True when labels exist or are being made, so a new count should relabel.
    func started(_ entry: RecordingEntry) -> Bool {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        return wanted[stamp] != nil || result(for: entry) != nil
    }

    /// Labels a transcribed recording with `count` voices, or the estimate.
    func label(_ entry: RecordingEntry, count: Int?) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        wanted[stamp] = .some(count)
        if let current = work[stamp], current != .failed { return }
        if let heard = VoicePrints.read(in: entry.folder) {
            save(stamp: stamp, heard: heard)
            return
        }
        work[stamp] = SpeakerFinder.isDownloaded() ? .listening : .downloading(0)
        try? SpeakerLabels.mark("finding", in: entry.folder)
        let previous = listening
        listening = Task { [weak self] in
            // One recording at a time: the model holds a few gigabytes.
            await previous?.value
            guard let self else { return }
            do {
                if !SpeakerFinder.isDownloaded() {
                    try await SpeakerFinder.download { fraction in
                        Task { @MainActor [weak self] in self?.downloaded(fraction) }
                    }
                }
                while !makeRoom() {
                    work[stamp] = .waiting
                    try await Task.sleep(for: .seconds(2))
                }
                work[stamp] = .listening
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                let heard = try await SpeakerFinder.listen(folder: folder)
                // The folder may have been renamed meanwhile.
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try heard.save(in: folder)
                save(stamp: stamp, heard: heard)
            } catch {
                failed(stamp, error)
            }
        }
    }

    /// Names a voice, or takes its name away. Changing a name TapeUp filled
    /// in is a correction: the voice is remembered as not that person, and
    /// earlier unchecked fills like it are offered for the same fix.
    func name(_ voice: Int, _ name: String?, in entry: RecordingEntry) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        guard let folder = library.folder(withStamp: stamp) else { return }
        let before = SpeakerLabels.result(in: folder)
        let old = before?.names[voice]
        let filled = before.map { $0.provenance(for: voice).origin != .person } ?? false
        offer = nil
        offerDone = nil
        do {
            if let name {
                if let old, old != name, filled {
                    try voices.correct(voice, to: name, in: folder)
                    let hits = (try? voices.pastFills(afterCorrecting: voice, from: old, in: folder, busy: busy)) ?? []
                    if !hits.isEmpty {
                        offer = PastFillOffer(stamp: stamp, voice: voice, from: old, to: name, hits: hits)
                    }
                } else {
                    try voices.name(voice, name, in: folder)
                }
            } else {
                try voices.unname(voice, in: folder)
            }
        } catch {
            showProblem("Could not save the voice name: \(error.localizedDescription)")
            return
        }
        version += 1
        namesChanged(stamp)
    }

    /// Playing a voice and leaving its name is the strongest check of a fill.
    func confirm(_ voice: Int, in entry: RecordingEntry) {
        guard let folder = library.folder(withStamp: RecordingLibrary.stamp(of: entry.folder)),
            let result = SpeakerLabels.result(in: folder), result.names[voice] != nil,
            result.provenance(for: voice).origin == .filled
        else { return }
        do { try voices.confirm(voice, in: folder) } catch {
            showProblem("Could not confirm the voice: \(error.localizedDescription)")
        }
        version += 1
    }

    /// Changes every offered earlier fill, or just one, to the corrected name.
    func applyOffer(only hit: VoiceLibrary.PastFill? = nil) {
        guard let offer else { return }
        // A made title may have renamed a folder since the offer was made.
        let hits = (hit.map { [$0] } ?? offer.hits).map { hit in
            var hit = hit
            if let folder = library.folder(withStamp: hit.stamp) { hit.recording = folder }
            return hit
        }
        let result: VoiceLibrary.PastFillResult
        do { result = try voices.applyPastFills(hits, to: offer.to, busy: busy) } catch {
            showProblem("Could not change earlier fills: \(error.localizedDescription)")
            return
        }
        if !result.skipped.isEmpty { showProblem("Some earlier fills were skipped because they changed or are busy.") }
        let changed = Set(result.changed.map { "\($0.stamp)/\($0.voice)" })
        let left = offer.hits.filter { !changed.contains("\($0.stamp)/\($0.voice)") && $0 != hit }
        self.offer =
            left.isEmpty || hit == nil
            ? nil : PastFillOffer(stamp: offer.stamp, voice: offer.voice, from: offer.from, to: offer.to, hits: left)
        offerDone = (offer.stamp, result.changed.count + (offerDone?.count ?? 0), result.undo)
        version += 1
        for stamp in changed.map({ String($0.split(separator: "/")[0]) }) { namesChanged(stamp) }
    }

    func leaveOffer() { offer = nil }

    func undoOffer() {
        guard let done = offerDone else { return }
        do {
            let result = try done.undo.restore(busy: busy)
            if let problem = result.problem { showProblem(problem) } else { offerDone = nil }
        } catch { showProblem("Could not undo the earlier changes: \(error.localizedDescription)") }
        version += 1
        namesChanged(done.stamp)
    }

    /// Forgets the offer when another recording's card opens.
    func clearOffer() {
        offer = nil
        offerDone = nil
    }

    /// Recordings being listened to right now, which renames and fixes skip.
    var busy: Set<String> { Set(work.compactMap { $0.value == .failed ? nil : $0.key }) }

    /// A quit while finding voices leaves `finding` in meta.json; nothing is
    /// finding them after a launch.
    nonisolated static func clearInterrupted(_ folders: [URL]) {
        for folder in folders {
            let labels = MetaFile.read(folder)?["speaker_labels"] as? [String: Any]
            if labels?["status"] as? String == "finding" {
                try? SpeakerLabels.mark("failed", error: "TapeUp quit while finding voices", in: folder)
            }
        }
    }

    private func downloaded(_ fraction: Double) {
        for (stamp, state) in work {
            if case .downloading = state { work[stamp] = .downloading(fraction) }
        }
    }

    private func save(stamp: String, heard: VoicePrints) {
        do {
            guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
            let result = try SpeakerLabels.relabel(heard, count: wanted[stamp] ?? nil, in: folder)
            work[stamp] = nil
            wanted[stamp] = nil
            // Remembered voices fill in the names they clearly match.
            if !result.voices.isEmpty, let fills = try? voices.fill(in: folder), !fills.isEmpty {
                namesChanged(stamp)
            }
            version += 1
        } catch {
            failed(stamp, error)
        }
    }

    private func failed(_ stamp: String, _ error: Error) {
        work[stamp] = .failed
        wanted[stamp] = nil
        if let folder = library.folder(withStamp: stamp) {
            try? SpeakerLabels.mark("failed", error: "\(error)", in: folder)
        }
        version += 1
    }
}
