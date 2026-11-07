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
                try? SpeakerLabels.mark("finding", in: folder)
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

    /// Names a voice, or takes its name away.
    func name(_ voice: Int, _ name: String?, in entry: RecordingEntry) {
        try? SpeakerLabels.name(voice, name, in: entry.folder)
        version += 1
    }

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
            guard let folder = library.folder(withStamp: stamp), let lines = TranscriptDocument.lines(in: folder)
            else { throw CocoaError(.fileNoSuchFile) }
            var result = SpeakerLabels.label(lines: lines, heard: heard, count: wanted[stamp] ?? nil)
            if let earlier = SpeakerLabels.result(in: folder), earlier.assigned.count == lines.count {
                result.names = SpeakerLabels.carry(
                    earlier.names, from: earlier.assigned, to: result.assigned, lines: lines)
            }
            try SpeakerLabels.save(result, lines: lines, in: folder)
            work[stamp] = nil
            wanted[stamp] = nil
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
