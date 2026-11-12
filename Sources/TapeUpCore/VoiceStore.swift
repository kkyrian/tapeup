import Foundation

/// Chosen voice examples survive removal of the recording and its audio.
public struct VoiceStore: Sendable, Equatable, Codable {
    public static let fileName = ".voices.json"
    public static let exampleLimit = 20
    public static let dimensions = 256

    public struct Example: Sendable, Equatable, Codable {
        public var print: [Float]
        public var stamp: String
        public var voice: Int
        public var seconds: Double
        /// On a negative, the score of the corrected fill, before penalization.
        public var correctionScore: Float? = nil

        public init(print: [Float], stamp: String, voice: Int, seconds: Double) {
            self.print = print
            self.stamp = stamp
            self.voice = voice
            self.seconds = seconds
        }
    }

    public struct Feedback: Sendable, Equatable, Codable {
        public var stamp: String
        public var voice: Int
        public var similarity: Float
        public var confirmed: Bool
        public var missed: Bool? = nil
    }

    public struct Person: Sendable, Equatable, Codable {
        public var examples: [Example] = []
        public var negatives: [Example] = []
        public var feedback: [Feedback] = []
        public var threshold: Float? = nil
        public init() {}
    }

    private var baseline: [String: Person]?
    private enum CodingKeys: String, CodingKey { case people }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        people = try values.decode([String: Person].self, forKey: .people)
        baseline = people
    }
    public static func == (lhs: VoiceStore, rhs: VoiceStore) -> Bool { lhs.people == rhs.people }

    public private(set) var people: [String: Person] = [:]
    public var count: Int { people.values.filter { !$0.examples.isEmpty }.count }
    public init() {}

    public enum StoreError: Error { case invalidExample, unreadableFile }

    public static func validPrint(_ print: [Float]) -> Bool {
        print.count == dimensions && print.allSatisfy(\.isFinite)
            && print.reduce(Double(0)) { $0 + Double($1) * Double($1) } > 0
    }

    public mutating func addExample(
        _ example: Example, for person: String, parameters: VoiceMatching.Parameters = .init()
    ) throws {
        let person = key(person)
        try validate(example, person: person)
        guard example.seconds >= parameters.minimumSeconds else { throw StoreError.invalidExample }
        // A voice can teach only one person, even after a manual rename.
        removeExample(stamp: example.stamp, voice: example.voice)
        var entry = people[person] ?? Person()
        entry.examples = Self.retained(entry.examples + [example])
        entry.negatives.removeAll { $0.stamp == example.stamp && $0.voice == example.voice }
        people[person] = entry
    }

    public mutating func removeExample(stamp: String, voice: Int) {
        for name in people.keys {
            people[name]?.examples.removeAll { $0.stamp == stamp && $0.voice == voice }
        }
    }

    public mutating func addNegative(
        _ example: Example, for person: String,
        similarity: Float? = nil, parameters: VoiceMatching.Parameters = .init()
    ) throws {
        let person = key(person)
        try validate(example, person: person)
        guard example.seconds >= parameters.minimumSeconds, similarity?.isFinite != false else {
            throw StoreError.invalidExample
        }
        var entry = people[person] ?? Person()
        var example = example
        example.correctionScore =
            similarity
            ?? (entry.examples.isEmpty
                ? nil : VoiceMatching.similarity(example.print, to: entry, parameters: parameters))
        entry.examples.removeAll { $0.stamp == example.stamp && $0.voice == example.voice }
        entry.negatives = Self.retained(entry.negatives + [example])
        people[person] = entry
    }

    public mutating func recordFeedback(
        for person: String, stamp: String, voice: Int, similarity: Float, confirmed: Bool,
        parameters: VoiceMatching.Parameters = .init()
    ) {
        recordObservation(
            for: person, stamp: stamp, voice: voice, similarity: similarity,
            confirmed: confirmed, missed: false, parameters: parameters)
    }

    mutating func recordMiss(
        for person: String, stamp: String, voice: Int, similarity: Float,
        parameters: VoiceMatching.Parameters = .init()
    ) {
        recordObservation(
            for: person, stamp: stamp, voice: voice, similarity: similarity,
            confirmed: true, missed: true, parameters: parameters)
    }

    private mutating func recordObservation(
        for person: String, stamp: String, voice: Int, similarity: Float,
        confirmed: Bool, missed: Bool, parameters: VoiceMatching.Parameters
    ) {
        guard similarity.isFinite else { return }
        let name = key(person)
        var entry = people[name] ?? Person()
        entry.threshold = VoiceMatching.updatedBar(
            VoiceMatching.bar(for: entry, parameters: parameters),
            similarity: similarity, confirmed: confirmed, missed: missed, parameters: parameters)
        if !confirmed, !missed,
            let index = entry.negatives.firstIndex(where: { $0.stamp == stamp && $0.voice == voice })
        {
            entry.negatives[index].correctionScore = similarity
        }
        entry.feedback.removeAll { $0.stamp == stamp && $0.voice == voice }
        entry.feedback.append(
            Feedback(
                stamp: stamp, voice: voice, similarity: similarity, confirmed: confirmed, missed: missed ? true : nil))
        entry.feedback = Array(entry.feedback.suffix(Self.exampleLimit))
        people[name] = entry
    }

    /// An aggregate can include a stamp whose feedback has aged out. On
    /// invalidation discard aggregate calibration and replay retained valid
    /// feedback lazily, rather than keeping an untraceable contribution.
    mutating func forgetRecording(_ stamp: String) {
        for name in people.keys {
            people[name]?.threshold = nil
            people[name]?.examples.removeAll { $0.stamp == stamp }
            people[name]?.negatives.removeAll { $0.stamp == stamp }
            people[name]?.feedback.removeAll { $0.stamp == stamp }
        }
    }

    public mutating func renamePerson(_ old: String, to new: String) { mergePersons(old, into: new) }

    public mutating func mergePersons(_ old: String, into new: String) {
        guard old != new, let source = people.removeValue(forKey: old) else { return }
        var target = people[new] ?? Person()
        target.examples = Self.retained(source.examples + target.examples)
        target.negatives = Self.retained(source.negatives + target.negatives).filter { negative in
            !target.examples.contains { $0.stamp == negative.stamp && $0.voice == negative.voice }
        }
        target.feedback = Array((source.feedback + target.feedback).suffix(Self.exampleLimit))
        target.threshold = [source.threshold, target.threshold].compactMap { $0 }.max()
        people[new] = target
    }

    /// Recounts renumber displayed voices. Move identities simultaneously so
    /// a swap cannot remove another person's chosen example.
    mutating func relabel(
        stamp: String, voices: [Int: Int], chosen: [Int: Int], names: [Int: String],
        aliases: [String: Set<String>] = [:]
    ) {
        for name in people.keys {
            var person = people[name]!
            person.examples = Self.retained(
                person.examples.compactMap { example in
                    guard example.stamp == stamp else { return example }
                    guard let voice = chosen[example.voice], let assignedName = names[voice],
                        assignedName == name || aliases[name.lowercased()]?.contains(assignedName.lowercased()) == true
                    else { return nil }
                    var moved = example
                    moved.voice = voice
                    return moved
                })
            person.negatives = Self.retained(
                person.negatives.compactMap { example in
                    guard example.stamp == stamp else { return example }
                    guard let voice = voices[example.voice] else { return nil }
                    var moved = example
                    moved.voice = voice
                    return moved
                })
            person.feedback = person.feedback.compactMap { feedback in
                guard feedback.stamp == stamp else { return feedback }
                guard let voice = voices[feedback.voice] else { return nil }
                var moved = feedback
                moved.voice = voice
                return moved
            }
            people[name] = person
        }
    }

    public mutating func forgetPerson(_ person: String) { people[key(person)] = nil }
    public mutating func forgetAll() { people = [:] }

    public static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

    /// Corrupt files are preserved beside the store. If preserving fails, a
    /// later save throws rather than overwriting the unreadable original.
    public static func load(from root: URL) -> VoiceStore {
        (try? VoiceFiles.withRootLock(root) {
            do { return try loadChecked(from: root) } catch {
                let aside = root.appendingPathComponent(".voices-unreadable-\(UUID().uuidString).json")
                try? FileManager.default.moveItem(at: url(in: root), to: aside)
                var empty = VoiceStore()
                empty.baseline = [:]
                return empty
            }
        }) ?? VoiceStore()
    }

    static func loadChecked(from root: URL) throws -> VoiceStore {
        let url = url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            var empty = VoiceStore()
            empty.baseline = [:]
            return empty
        }
        let store = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        for (name, person) in store.people {
            guard person.examples.count <= exampleLimit, person.negatives.count <= exampleLimit,
                person.feedback.count <= exampleLimit, person.feedback.allSatisfy({ $0.similarity.isFinite }),
                person.threshold?.isFinite != false
            else { throw StoreError.unreadableFile }
            for example in person.examples + person.negatives { try store.validate(example, person: name) }
        }
        return store
    }

    /// A loaded snapshot must still be current. Reload before another edit;
    /// stale saves throw instead of discarding another process's changes.
    public func save(to root: URL) throws {
        try VoiceFiles.withRootLock(root) {
            let current = try Self.loadChecked(from: root)
            if let baseline, current.people != baseline, current.people != people {
                throw VoiceLibrary.Failure.concurrentChange
            }
            try JSONEncoder().encode(self).write(to: Self.url(in: root), options: .atomic)
        }
    }

    private func key(_ name: String) -> String {
        people.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private func validate(_ example: Example, person: String) throws {
        guard !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !example.stamp.isEmpty, Self.validPrint(example.print), example.seconds.isFinite, example.seconds > 0,
            example.correctionScore?.isFinite != false
        else { throw StoreError.invalidExample }
    }

    private static func retained(_ examples: [Example]) -> [Example] {
        var unique: [Example] = []
        for example in examples.reversed() {
            if !unique.contains(where: { $0.stamp == example.stamp && $0.voice == example.voice }) {
                unique.append(example)
            }
        }
        return Array(
            unique.sorted {
                if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
                return ($0.stamp, $0.voice) < ($1.stamp, $1.voice)
            }.prefix(exampleLimit))
    }
}
