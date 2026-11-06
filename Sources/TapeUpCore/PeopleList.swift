import Foundation

/// The people the user records with, kept in `<root>/people.json` so the
/// user's own AI assistant can write it, and used to suggest who was there.
public struct PeopleList: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Codable {
        public var name: String
        public var context: String?

        public init(name: String, context: String? = nil) {
            self.name = name
            self.context = context
        }
    }

    public static let format = "tapeup-people/1"
    public static let fileName = "people.json"

    public var you: String?
    public var people: [Person]

    public init(you: String? = nil, people: [Person] = []) {
        self.you = you
        self.people = people
    }

    public var isEmpty: Bool { people.isEmpty && (you ?? "").isEmpty }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Reads a list from an assistant's reply: the JSON alone, inside a code
    /// block, or with prose around it.
    public static func parse(_ text: String) throws -> PeopleList {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw ParseError(description: "no list found")
        }
        guard let data = String(text[start...end]).data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw ParseError(description: "the list is not valid JSON") }
        let entries = object["people"] as? [Any] ?? []
        var list = PeopleList(you: clean(object["you"] as? String))
        for entry in entries {
            switch entry {
            case let name as String:
                list.add(Person(name: name))
            case let fields as [String: Any]:
                if let name = fields["name"] as? String {
                    list.add(Person(name: name, context: fields["context"] as? String))
                }
            default: continue
            }
        }
        guard !list.isEmpty else { throw ParseError(description: "the list has no names") }
        return list
    }

    /// Adds a person unless the name is already there (ignoring case), in
    /// which case a missing context is filled in.
    public mutating func add(_ person: Person) {
        guard let name = Self.clean(person.name), name.lowercased() != you?.lowercased() else { return }
        let context = Self.clean(person.context)
        if let index = people.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            if people[index].context == nil { people[index].context = context }
        } else {
            people.append(Person(name: name, context: context))
        }
    }

    /// Keeps everyone here and adds anyone new from `other`.
    public func merged(with other: PeopleList) -> PeopleList {
        var result = PeopleList(you: other.you ?? you, people: [])
        for person in people + other.people { result.add(person) }
        return result
    }

    public mutating func remove(_ name: String) {
        people.removeAll { $0.name == name }
    }

    // MARK: File

    public static func url(in root: URL) -> URL { root.appendingPathComponent(fileName) }

    public static func load(from root: URL) -> PeopleList {
        guard let text = try? String(contentsOf: url(in: root), encoding: .utf8) else { return PeopleList() }
        return (try? parse(text)) ?? PeopleList()
    }

    public func save(to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var object: [String: Any] = [
            "format": Self.format,
            "people": people.map { person -> [String: Any] in
                var fields: [String: Any] = ["name": person.name]
                if let context = person.context { fields["context"] = context }
                return fields
            },
        ]
        if let you { object["you"] = you }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: Self.url(in: root), options: .atomic)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    // MARK: Instructions for the user's assistant

    /// What Copy for AI puts on the clipboard. It is an interface the user's
    /// own assistant reads, so it states the goal, the exact format and both
    /// ways to deliver.
    public static func assistantPrompt(root: URL) -> String {
        let path = url(in: root).path
        return """
            I'm setting up TapeUp, a Mac app that records my calls and meetings (my microphone \
            and my computer's audio) into folders that AI agents transcribe later. When a \
            recording ends, TapeUp suggests names for "who was there", and the transcripts use \
            them to label speakers. Please give it the list of people I talk with, so I never \
            have to type them.

            1. Make the list from what you know about me: my own name, then the people I meet, \
            call, study or work with (colleagues, classmates, teachers, clients, friends, \
            family), most frequent first. Never invent anyone. If you know too little about me, \
            first ask me a few quick questions, then build the list from my answers.

            2. Use exactly this JSON. "name" is how the person is called in conversation (a \
            first name, or a full name when two people share it). "context" is optional, a few \
            words such as "advisor", "lab mate" or "sister".

            {"format": "tapeup-people/1", "you": "<my name>", "people": [{"name": "<name>", "context": "<optional>"}]}

            3. Deliver it in one of two ways:
            - If you can write files on this Mac (for example Claude Code or Codex), save it to \
            \(path). If that file already exists, keep everyone in it and add the new people, \
            matching names without regard to case. Then tell me how many people it holds. \
            TapeUp picks the file up by itself.
            - Otherwise, reply with only the JSON in one code block, nothing else, so I can copy \
            your answer and paste it into TapeUp.
            """
    }
}
