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
        case listening
        case failed
    }

    var library: RecordingLibrary
    /// Frees the speech model before the speaker model loads.
    var makeRoom: () -> Void = {}

    /// Work in progress or failed, by recording stamp.
    private(set) var work: [String: Work] = [:]
    /// Bumped on every change, so views reading results from disk redraw.
    private(set) var version = 0
    private var listening: Task<Void, Never>?

    init(library: RecordingLibrary) { self.library = library }

    func result(for entry: RecordingEntry) -> SpeakerResult? {
        _ = version
        return SpeakerLabels.result(in: entry.folder)
    }

    func work(on entry: RecordingEntry) -> Work? { work[RecordingLibrary.stamp(of: entry.folder)] }

    /// Labels a transcribed recording with `count` voices, or the estimate.
    func label(_ entry: RecordingEntry, count: Int?) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        guard work[stamp] == nil || work[stamp] == .failed else { return }
        if let heard = VoicePrints.read(in: entry.folder) {
            save(stamp: stamp, heard: heard, count: count)
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
                        Task { @MainActor [weak self] in
                            if case .downloading = self?.work[stamp] { self?.work[stamp] = .downloading(fraction) }
                        }
                    }
                }
                work[stamp] = .listening
                makeRoom()
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try? SpeakerLabels.mark("finding", in: folder)
                let heard = try await SpeakerFinder.listen(folder: folder)
                // The folder may have been renamed meanwhile.
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try heard.save(in: folder)
                work[stamp] = nil
                save(stamp: stamp, heard: heard, count: count)
            } catch {
                work[stamp] = .failed
                if let folder = library.folder(withStamp: stamp) {
                    try? SpeakerLabels.mark("failed", error: "\(error)", in: folder)
                }
                version += 1
            }
        }
    }

    /// Names a voice, or takes its name away.
    func name(_ voice: Int, _ name: String?, in entry: RecordingEntry) {
        try? SpeakerLabels.name(voice, name, in: entry.folder)
        version += 1
    }

    private func save(stamp: String, heard: VoicePrints, count: Int?) {
        guard let folder = library.folder(withStamp: stamp), let lines = TranscriptDocument.lines(in: folder) else {
            work[stamp] = .failed
            return
        }
        var result = SpeakerLabels.label(lines: lines, heard: heard, count: count)
        // The same voices keep their names; another count numbers them afresh.
        if let earlier = SpeakerLabels.result(in: folder), earlier.voices.count == result.voices.count {
            result.names = earlier.names
        }
        do {
            try SpeakerLabels.save(result, lines: lines, in: folder)
            work[stamp] = nil
        } catch {
            work[stamp] = .failed
        }
        version += 1
    }
}
