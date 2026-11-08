import Foundation
import Observation
import TapeUpCore

/// The transcripts' text for searching, read off the main thread the first
/// time it is needed and kept, so typing never waits on the disk. Kept by
/// the recording's stamp, which a title renaming its folder keeps; a
/// transcript rewritten since it was read is read again.
@MainActor @Observable
final class TranscriptIndex {
    private struct Text {
        var modified: Date?
        var folded: String?
    }

    private var texts: [String: Text] = [:]
    private var reading: Set<String> = []
    /// True while transcripts are still being read.
    private(set) var loading = false

    /// The folded text, nil when none is known yet or there is no transcript.
    func text(for entry: RecordingEntry) -> String? {
        entry.transcript == .done ? texts[RecordingLibrary.stamp(of: entry.folder)]?.folded : nil
    }

    /// Reads every finished transcript not read yet, or changed since.
    func load(_ entries: [RecordingEntry]) {
        let wanted = entries.filter { $0.transcript == .done }
            .map { (stamp: RecordingLibrary.stamp(of: $0.folder), folder: $0.folder) }
            .filter { !reading.contains($0.stamp) }
        guard !wanted.isEmpty else { return }
        let cached = texts.mapValues(\.modified)
        for item in wanted { reading.insert(item.stamp) }
        loading = true
        Task.detached(priority: .userInitiated) {
            var read: [(String, Text)] = []
            for (stamp, folder) in wanted {
                let modified = RecordingSearch.transcriptModified(in: folder)
                if let known = cached[stamp], known == modified { continue }
                read.append((stamp, Text(modified: modified, folded: RecordingSearch.transcriptText(in: folder))))
            }
            await MainActor.run { [weak self, read] in
                guard let self else { return }
                for (stamp, text) in read { texts[stamp] = text }
                for item in wanted { reading.remove(item.stamp) }
                loading = !reading.isEmpty
            }
        }
    }
}
