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
    }

    public struct Person: Sendable, Equatable, Codable {
        public var examples: [Example] = []
        public var negatives: [Example] = []
        public var feedback: [Feedback] = []
        public init() {}
    }

    public private(set) var people: [String: Person] = [:]
    public var count: Int { people.values.filter { !$0.examples.isEmpty }.count }
    public init() {}

    public enum StoreError: Error { case invalidExample, unreadableFile }

    public static func validPrint(_ print: [Float]) -> Bool {
        print.count == dimensions && print.allSatisfy(\.isFinite)
            && print.reduce(Double(0)) { $0 + Double($1) * Double($1) } > 0
    }

    public mutating func addExample(_ example: Example, for person: String) throws {
        let person = key(person)
        try validate(example, person: person)
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

    public mutating func addNegative(_ example: Example, for person: String) throws {
        let person = key(person)
        try validate(example, person: person)
        var entry = people[person] ?? Person()
        entry.examples.removeAll { $0.stamp == example.stamp && $0.voice == example.voice }
        entry.negatives = Self.retained(entry.negatives + [example])
        people[person] = entry
    }

    public mutating func recordFeedback(
        for person: String, stamp: String, voice: Int, similarity: Float, confirmed: Bool
    ) {
        guard similarity.isFinite else { return }
        let person = key(person)
        var entry = people[person] ?? Person()
        entry.feedback.removeAll { $0.stamp == stamp && $0.voice == voice }
        entry.feedback.append(Feedback(stamp: stamp, voice: voice, similarity: similarity, confirmed: confirmed))
        entry.feedback = Array(entry.feedback.suffix(Self.exampleLimit))
        people[person] = entry
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
        people[new] = target
    }

    /// Recounts renumber displayed voices. Move identities simultaneously so
    /// a swap cannot remove another person's chosen example.
    mutating func relabel(stamp: String, voices: [Int: Int], chosen: [Int: Int], names: [Int: String]) {
        for name in people.keys {
            var person = people[name]!
            person.examples = Self.retained(
                person.examples.compactMap { example in
                    guard example.stamp == stamp else { return example }
                    guard let voice = chosen[example.voice], names[voice] == name else { return nil }
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
        do { return try loadChecked(from: root) } catch {
            let aside = root.appendingPathComponent(".voices-unreadable-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url(in: root), to: aside)
            return VoiceStore()
        }
    }

    static func loadChecked(from root: URL) throws -> VoiceStore {
        let url = url(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceStore() }
        let store = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        for (name, person) in store.people {
            guard person.examples.count <= exampleLimit, person.negatives.count <= exampleLimit,
                person.feedback.count <= exampleLimit, person.feedback.allSatisfy({ $0.similarity.isFinite })
            else { throw StoreError.unreadableFile }
            for example in person.examples + person.negatives { try store.validate(example, person: name) }
        }
        return store
    }

    public func save(to root: URL) throws {
        if FileManager.default.fileExists(atPath: Self.url(in: root).path) {
            _ = try Self.loadChecked(from: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(in: root), options: .atomic)
    }

    private func key(_ name: String) -> String {
        people.keys.sorted().first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
    }

    private func validate(_ example: Example, person: String) throws {
        guard !person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !example.stamp.isEmpty, Self.validPrint(example.print), example.seconds.isFinite, example.seconds > 0
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
