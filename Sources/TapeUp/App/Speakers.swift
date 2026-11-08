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
    /// The user's agent, asked to suggest names once voices are found.
    var agents: Agents?
    /// The names a voice may be given: this recording's people, then the
    /// people list. With none, no names are suggested.
    var knownNames: (RecordingEntry) -> [String] = { $0.people.names }
    /// Plays a voice to name it, from the card's speaker rows.
    let player = VoicePlayer()

    /// Work in progress or failed, by recording stamp.
    private(set) var work: [String: Work] = [:]
    /// Bumped on every change, so views reading results from disk redraw.
    private(set) var version = 0
    /// The count each recording's labels should have, updated while a listen runs.
    private var wanted: [String: Int?] = [:]
    private var listening: Task<Void, Never>?
    private var agentWanted: Set<String> = []

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
    /// `askAgent` is false for work the user did not start in the panel, so
    /// the user's agent is never called in bulk.
    func label(_ entry: RecordingEntry, count: Int?, askAgent: Bool = true) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        wanted[stamp] = .some(count)
        if askAgent { agentWanted.insert(stamp) } else { agentWanted.remove(stamp) }
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
            guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
            let result = try SpeakerLabels.relabel(heard, count: wanted[stamp] ?? nil, in: folder)
            work[stamp] = nil
            wanted[stamp] = nil
            version += 1
            if agentWanted.remove(stamp) != nil { suggestNames(stamp: stamp, result: result) }
        } catch {
            failed(stamp, error)
        }
    }

    /// Asks the user's agent which known person each unnamed voice is. The
    /// answer can only be a known name or none; it shows as a suggestion.
    private func suggestNames(stamp: String, result: SpeakerResult) {
        guard let agents, agents.chosen != nil, let folder = library.folder(withStamp: stamp),
            let entry = RecordingLibrary.entry(at: folder), let lines = TranscriptDocument.lines(in: folder)
        else { return }
        let known = knownNames(entry)
        let unnamed = result.voices.filter { result.names[$0.id] == nil }
        guard !known.isEmpty, !unnamed.isEmpty else { return }
        let labeled = zip(lines, result.assigned).map { line, voice in
            TranscriptLine(
                start: line.start, end: line.end,
                text: "\(voice.map { result.names[$0] ?? "Voice \($0)" } ?? "Unknown"): \(line.text)")
        }
        let prompt = """
            Lines from a transcript, each starting with the voice that said it. For each voice listed below, \
            say which of the known people it is, only when the lines make it clear (someone addressed by \
            name, introducing themselves, or named by others). Otherwise give an empty name. Never guess.
            Voices to name: \(unnamed.map { "Voice \($0.id)" }.joined(separator: ", "))
            Known people: \(known.joined(separator: ", "))

            Transcript lines:
            \(TitleExcerpt.make(lines: labeled))
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "voices": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "voice": ["type": "integer"], "name": ["type": "string", "enum": known + [""]],
                        ],
                        "required": ["voice", "name"], "additionalProperties": false,
                    ],
                ]
            ],
            "required": ["voices"], "additionalProperties": false,
        ]
        Task { [weak self] in
            struct Answer: Decodable {
                struct Pick: Decodable {
                    var voice: Int
                    var name: String
                }
                var voices: [Pick]
            }
            guard let self,
                let data = await agents.ask("names", prompt: prompt, schema: schema, stamp: stamp, in: library),
                let answer = try? JSONDecoder().decode(Answer.self, from: data),
                let folder = library.folder(withStamp: stamp),
                // A recount or a name given meanwhile changed what was asked about.
                SpeakerLabels.result(in: folder)?.assigned == result.assigned
            else { return }
            var picks: [Int: String] = [:]
            for pick in answer.voices where known.contains(pick.name) { picks[pick.voice] = pick.name }
            guard !picks.isEmpty else { return }
            try? SpeakerLabels.suggest(picks, in: folder)
            version += 1
        }
    }

    /// Takes every suggested name.
    func acceptSuggestedNames(in entry: RecordingEntry) {
        try? SpeakerLabels.acceptSuggested(in: entry.folder)
        version += 1
    }

    private func failed(_ stamp: String, _ error: Error) {
        agentWanted.remove(stamp)
        work[stamp] = .failed
        wanted[stamp] = nil
        if let folder = library.folder(withStamp: stamp) {
            try? SpeakerLabels.mark("failed", error: "\(error)", in: folder)
        }
        version += 1
    }
}
