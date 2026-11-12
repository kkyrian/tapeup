import Foundation

/// Synchronous disk operations for the integrator; run on a serial background
/// queue. A fill never teaches the store; only label actions below do.
public struct VoiceLibrary: Sendable {
    public let root: URL
    public var parameters: VoiceMatching.Parameters

    public init(root: URL, parameters: VoiceMatching.Parameters = .init()) {
        self.root = root
        self.parameters = parameters
    }

    private struct Recording {
        var folder: URL
        var result: SpeakerResult
        var lines: [TranscriptLine]
        var meta: [String: Any]
        var prints: [Int: [Float]]
        var stamp: String { RecordingLibrary.stamp(of: folder) }

        init(_ folder: URL) throws {
            self.folder = folder
            guard let data = try VoiceFiles.read(folder.appendingPathComponent(SpeakerLabels.resultFileName)),
                let lines = TranscriptDocument.lines(in: folder)
            else { throw CocoaError(.fileNoSuchFile) }
            let result = try JSONDecoder().decode(SpeakerResult.self, from: data)
            self.result = result
            guard lines.count == result.assigned.count, Set(result.voices.map(\.id)).count == result.voices.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.lines = lines
            meta = try VoiceFiles.object(MetaFile.url(in: folder))
            prints =
                VoicePrints.read(in: folder).map { SpeakerLabels.prints(of: result, heard: $0, lines: lines) } ?? [:]
        }

        func example(_ voice: Int) -> VoiceStore.Example? {
            guard let print = prints[voice], let seconds = result.voices.first(where: { $0.id == voice })?.seconds,
                seconds.isFinite, seconds > 0
            else { return nil }
            return .init(print: print, stamp: stamp, voice: voice, seconds: seconds)
        }

        mutating func attend(_ person: String) -> Bool {
            var who = meta["who_was_there"] as? [String: Any] ?? [:]
            var names = who["names"] as? [String] ?? []
            guard !names.contains(where: { $0.caseInsensitiveCompare(person) == .orderedSame }) else { return false }
            names.append(person)
            who["names"] = names
            meta["who_was_there"] = who
            return true
        }

        mutating func removeAttendance(_ person: String) {
            // Retain attendance when another voice still carries that name.
            guard !result.names.values.contains(person) else { return }
            guard var who = meta["who_was_there"] as? [String: Any], let names = who["names"] as? [String] else {
                return
            }
            who["names"] = names.filter { $0.caseInsensitiveCompare(person) != .orderedSame }
            meta["who_was_there"] = who
        }

        func writes() throws -> [(URL, Data?)] {
            try VoiceFiles.speakerWrites(result, lines: lines, meta: meta, folder: folder)
        }
    }

    /// Fills unnamed voices, adds attendance, and records provenance. Does not
    /// add people to people.json or examples to the voice store.
    @discardableResult
    public func fill(in folder: URL) throws -> [VoiceMatching.Fill] {
        try VoiceFiles.locked {
            var recording = try Recording(folder)
            let store = VoiceStore.load(from: root)
            let fills = VoiceMatching.match(
                prints: recording.prints,
                seconds: Dictionary(uniqueKeysWithValues: recording.result.voices.map { ($0.id, $0.seconds) }),
                store: store,
                headphones: TranscriptDocument.sidesKnown(meta: recording.meta),
                microphoneOnlyVoices: SpeakerLabels.microphoneOnlyVoices(
                    lines: recording.lines, assigned: recording.result.assigned),
                you: PeopleList.load(from: root).you, named: recording.result.names, parameters: parameters)
            guard !fills.isEmpty else { return [] }
            for fill in fills {
                let added = recording.attend(fill.person)
                recording.result.names[fill.voice] = fill.person
                recording.result.provenance[fill.voice] = .init(
                    origin: .filled, addedToWhoWasThere: added, similarity: fill.microphone ? nil : fill.similarity)
                recording.result.suggested[fill.voice] = nil
            }
            _ = try VoiceFiles.apply(recording.writes())
            return fills
        }
    }

    /// Choosing a label also confirms the other fills left standing. Passing
    /// nil unnames only this voice; attendance/count edits never call this.
    @discardableResult
    public func name(_ voice: Int, _ person: String?, in folder: URL) throws -> VoiceFileUndo {
        try change(voice, to: person, in: folder, confirmRemaining: person != nil)
    }

    @discardableResult
    public func unname(_ voice: Int, in folder: URL) throws -> VoiceFileUndo {
        try change(voice, to: nil, in: folder, confirmRemaining: false)
    }

    @discardableResult
    public func correct(_ voice: Int, to person: String, in folder: URL) throws -> VoiceFileUndo {
        try change(voice, to: person, in: folder, confirmRemaining: true)
    }

    @discardableResult
    public func confirm(_ voice: Int, in folder: URL) throws -> VoiceFileUndo {
        try confirm(in: folder, voices: [voice])
    }

    @discardableResult
    public func confirmFills(in folder: URL) throws -> VoiceFileUndo {
        try confirm(in: folder, voices: nil)
    }

    private func confirm(in folder: URL, voices: Set<Int>?) throws -> VoiceFileUndo {
        try VoiceFiles.locked {
            var recording = try Recording(folder)
            var store = try editableStore()
            try learnFills(&recording, store: &store, voices: voices)
            return try VoiceFiles.apply(
                recording.writes() + [(VoiceStore.url(in: root), try JSONEncoder().encode(store))])
        }
    }

    private func learnFills(_ recording: inout Recording, store: inout VoiceStore, voices: Set<Int>? = nil) throws {
        for (voice, person) in recording.result.names.sorted(by: { $0.key < $1.key }) {
            guard voices == nil || voices!.contains(voice), recording.result.provenance(for: voice).origin == .filled
            else { continue }
            var provenance = recording.result.provenance(for: voice)
            if let example = recording.example(voice) { try store.addExample(example, for: person) }
            if let similarity = provenance.similarity {
                store.recordFeedback(
                    for: person, stamp: recording.stamp, voice: voice, similarity: similarity, confirmed: true)
            }
            provenance.origin = .confirmed
            recording.result.provenance[voice] = provenance
        }
    }

    private func choose(_ voice: Int, person: String?, recording: inout Recording, store: inout VoiceStore) throws {
        guard recording.result.voices.contains(where: { $0.id == voice }) else {
            throw VoiceStore.StoreError.invalidExample
        }
        let old = recording.result.names[voice]
        let provenance = recording.result.provenance(for: voice)
        store.removeExample(stamp: recording.stamp, voice: voice)
        if let old, let person, old != person, provenance.origin != .person, let example = recording.example(voice) {
            let score =
                provenance.similarity
                ?? store.people[old].map { VoiceMatching.similarity(example.print, to: $0, parameters: parameters) }
            try store.addNegative(example, for: old)
            if let score {
                store.recordFeedback(
                    for: old, stamp: recording.stamp, voice: voice, similarity: score, confirmed: false)
            }
        }
        recording.result.names[voice] = person
        recording.result.provenance[voice] = person.map { _ in SpeakerProvenance(origin: .person) }
        recording.result.suggested = recording.result.suggested.filter { $0.key != voice && $0.value != person }
        if let old, old != person, provenance.addedToWhoWasThere { recording.removeAttendance(old) }
        if let person {
            _ = recording.attend(person)
            if let example = recording.example(voice) { try store.addExample(example, for: person) }
            // Explicitly choosing an unchanged fill is a confirmation too.
            if old == person, provenance.origin != .person {
                if provenance.origin == .filled, let score = provenance.similarity {
                    store.recordFeedback(
                        for: person, stamp: recording.stamp, voice: voice, similarity: score, confirmed: true)
                }
                recording.result.provenance[voice] = .init(
                    origin: .confirmed, addedToWhoWasThere: provenance.addedToWhoWasThere,
                    similarity: provenance.similarity)
            }
        }
    }

    private func change(_ voice: Int, to person: String?, in folder: URL, confirmRemaining: Bool) throws
        -> VoiceFileUndo
    {
        try VoiceFiles.locked {
            var person = person?.trimmingCharacters(in: .whitespacesAndNewlines)
            if person?.isEmpty == true { throw VoiceStore.StoreError.invalidExample }
            var recording = try Recording(folder)
            var store = try editableStore()
            if let name = person { person = try canonicalPerson(name, store: store) }
            try choose(voice, person: person, recording: &recording, store: &store)
            if confirmRemaining { try learnFills(&recording, store: &store) }
            var writes = try recording.writes() + [(VoiceStore.url(in: root), try JSONEncoder().encode(store))]
            if let person {
                var people = try checkedPeople()
                if !people.contains(person) {
                    people.add(.init(name: person))
                    writes.append((PeopleList.url(in: root), try Self.peopleData(people)))
                }
            }
            return try VoiceFiles.apply(writes)
        }
    }

    private func canonicalPerson(_ name: String, store: VoiceStore) throws -> String {
        let names = try checkedPeople().allNames + store.people.keys.sorted()
        return names.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private func checkedPeople() throws -> PeopleList {
        if let data = try VoiceFiles.read(PeopleList.url(in: root)), String(data: data, encoding: .utf8) == nil {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try PeopleList.loadChecked(from: root)
    }

    private func editableStore() throws -> VoiceStore {
        let store = VoiceStore.load(from: root)
        if FileManager.default.fileExists(atPath: VoiceStore.url(in: root).path) {
            _ = try VoiceStore.loadChecked(from: root)
        }
        return store
    }

    static func peopleData(_ people: PeopleList) throws -> Data {
        var object: [String: Any] = [
            "format": PeopleList.format,
            "people": people.people.map { person -> [String: Any] in
                var entry: [String: Any] = ["name": person.name]
                if let context = person.context { entry["context"] = context }
                return entry
            },
        ]
        if let you = people.you { object["you"] = you }
        return try VoiceFiles.json(object)
    }

    public struct PastFill: Sendable, Equatable {
        public var recording: URL
        public var stamp: String
        public var voice: Int
        public var person: String
        public var similarity: Float
        public var quote: String
        /// A stale proposal must not overwrite a refold or a different fill.
        public var print: [Float]
    }

    /// Preview only. Excludes the source and anything confirmed or chosen.
    public func pastFills(
        of person: String, closeTo print: [Float], excluding source: URL, busy: Set<String> = []
    ) throws -> [PastFill] {
        VoiceFiles.locked {
            var hits: [PastFill] = []
            for folder in RecordingLibrary(root: root).recordingFolders()
            where RecordingLibrary.stamp(of: folder) < RecordingLibrary.stamp(of: source)
                && !busy.contains(RecordingLibrary.stamp(of: folder))
            {
                guard let recording = try? Recording(folder) else { continue }
                for (voice, name) in recording.result.names.sorted(by: { $0.key < $1.key })
                where name == person && recording.result.provenance(for: voice).origin == .filled {
                    guard let candidate = recording.prints[voice] else { continue }
                    let similarity = VoiceMatching.cosine(print, candidate)
                    guard similarity >= parameters.pastFillSimilarity else { continue }
                    let quote = zip(recording.lines, recording.result.assigned).first { $0.1 == voice }?.0.text ?? ""
                    hits.append(
                        PastFill(
                            recording: folder, stamp: recording.stamp, voice: voice, person: person,
                            similarity: similarity, quote: quote, print: candidate))
                }
            }
            return hits
        }
    }

    /// Convenience for the correction strip: the corrected recording still
    /// holds the voice print, so the UI need only retain the previous name.
    public func pastFills(
        afterCorrecting voice: Int, from person: String, in folder: URL, busy: Set<String> = []
    ) throws -> [PastFill] {
        try VoiceFiles.locked {
            let recording = try Recording(folder)
            guard let print = recording.prints[voice] else { return [] }
            return try pastFills(of: person, closeTo: print, excluding: folder, busy: busy)
        }
    }

    public struct PastFillResult: Sendable {
        public var changed: [PastFill]
        public var skipped: [PastFill]
        public var undo: VoiceFileUndo
    }

    public func applyPastFills(_ hits: [PastFill], to person: String, busy: Set<String> = []) throws -> PastFillResult {
        try VoiceFiles.locked {
            let requested = person.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty else { throw VoiceStore.StoreError.invalidExample }
            var store = try editableStore()
            let person = try canonicalPerson(requested, store: store)
            var changed: [PastFill] = []
            var skipped: [PastFill] = []
            var writes: [(URL, Data?)] = []
            for folder in Set(hits.map(\.recording)).sorted(by: { $0.path < $1.path }) {
                let proposed = hits.filter { $0.recording == folder }
                guard !busy.contains(RecordingLibrary.stamp(of: folder)), var recording = try? Recording(folder) else {
                    skipped += proposed
                    continue
                }
                for hit in proposed {
                    guard recording.result.names[hit.voice] == hit.person,
                        recording.result.provenance(for: hit.voice).origin == .filled,
                        recording.prints[hit.voice] == hit.print
                    else {
                        skipped.append(hit)
                        continue
                    }
                    try choose(hit.voice, person: person, recording: &recording, store: &store)
                    changed.append(hit)
                }
                if changed.contains(where: { $0.recording == folder }) {
                    try learnFills(&recording, store: &store)
                    writes += try recording.writes()
                }
            }
            if !changed.isEmpty {
                writes.append((VoiceStore.url(in: root), try JSONEncoder().encode(store)))
                var people = try checkedPeople()
                if !people.contains(person) {
                    people.add(.init(name: person))
                    writes.append((PeopleList.url(in: root), try Self.peopleData(people)))
                }
            }
            return PastFillResult(changed: changed, skipped: skipped, undo: try VoiceFiles.apply(writes))
        }
    }
}
