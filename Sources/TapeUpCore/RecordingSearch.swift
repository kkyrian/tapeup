import Foundation

/// Finding a recording in the whole library: the chips to narrow by, what
/// each one keeps, and a search over titles, names and transcript text.
public struct RecordingFilter: Sendable, Equatable {
    /// Words typed into the search field; every one must be found.
    public var query: String
    /// People who must all have been there, as their chips name them.
    public var people: Set<String>
    /// Only recordings without a finished transcript.
    public var noTranscript: Bool
    /// Only recordings with other people there and none of them named.
    public var noNames: Bool

    public init(query: String = "", people: Set<String> = [], noTranscript: Bool = false, noNames: Bool = false) {
        self.query = query
        self.people = people
        self.noTranscript = noTranscript
        self.noNames = noNames
    }

    /// Nothing typed and no chip on.
    public var isEmpty: Bool { words.isEmpty && people.isEmpty && !noTranscript && !noNames }

    /// The typed words, folded for matching.
    public var words: [String] {
        RecordingSearch.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether the recording passes every chip that is on and holds every
    /// typed word in its title, its people's names or its transcript.
    /// `transcript` is the folded text from `RecordingSearch.transcriptText`,
    /// nil while it is still being read.
    public func matches(_ entry: RecordingEntry, transcript: String?) -> Bool {
        if noTranscript, !RecordingSearch.needsTranscript(entry) { return false }
        if noNames, !RecordingSearch.needsNames(entry) { return false }
        if !people.isEmpty {
            let there = Set(entry.people.names.map(RecordingSearch.fold))
            guard people.allSatisfy({ there.contains(RecordingSearch.fold($0)) }) else { return false }
        }
        let words = words
        guard !words.isEmpty else { return true }
        let known = RecordingSearch.known(entry)
        // Literal: the texts are folded already, and an hour of talk is
        // searched on every keystroke.
        return words.allSatisfy { word in
            known.range(of: word, options: .literal) != nil
                || transcript?.range(of: word, options: .literal) != nil
        }
    }
}

extension RecordingFilter {
    /// The first typed word found only in the transcript, not in the title
    /// or names: the row matched by what was said, and this word shows why.
    /// Nil when the title or names hold every word.
    public func transcriptOnlyWord(_ entry: RecordingEntry, transcript: String?) -> String? {
        guard let transcript else { return nil }
        let known = RecordingSearch.known(entry)
        return words.first { word in
            known.range(of: word, options: .literal) == nil && transcript.range(of: word, options: .literal) != nil
        }
    }
}

public enum RecordingSearch {
    /// The title, suggested title and names, folded.
    static func known(_ entry: RecordingEntry) -> String {
        fold(([entry.title, entry.titleSuggestion].compactMap { $0 } + entry.people.names).joined(separator: "\n"))
    }

    /// Lowercased, without accents or width differences, so "jose" finds "José".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// No finished transcript yet: never made, waiting, being made, or failed.
    public static func needsTranscript(_ entry: RecordingEntry) -> Bool { entry.transcript != .done }

    /// Other people were there, or may have been, and no one is named. A
    /// recording of just the user has no one to name.
    public static func needsNames(_ entry: RecordingEntry) -> Bool {
        entry.people.names.isEmpty && entry.people.count != 1
    }

    /// The people named at the most recordings, most first; a tie goes to
    /// whoever was met more recently. Names that differ only in case or
    /// accents are one person, shown as most recently written.
    public static func frequentPeople(in entries: [RecordingEntry], limit: Int = 5) -> [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int, latest: Date)] = [:]
        for entry in entries {
            for key in Set(entry.people.names.map(fold)) {
                let name = entry.people.names.first { fold($0) == key } ?? key
                if let seen = counts[key] {
                    let newer = entry.started > seen.latest
                    counts[key] = (newer ? name : seen.name, seen.count + 1, max(seen.latest, entry.started))
                } else {
                    counts[key] = (name, 1, entry.started)
                }
            }
        }
        return counts.values
            .sorted {
                ($0.count, $0.latest, $1.name) > ($1.count, $1.latest, $0.name)
            }
            .prefix(limit)
            .map { ($0.name, $0.count) }
    }

    /// A section for each of `people` with the recordings they were at, in
    /// the order given, then one (named nil) for recordings with none of
    /// them. A recording with two of them is in both sections; empty
    /// sections are left out.
    public static func byPerson(_ entries: [RecordingEntry], people: [String]) -> [(
        person: String?, entries: [RecordingEntry]
    )] {
        let keys = people.map(fold)
        var sections: [(person: String?, entries: [RecordingEntry])] = people.map { ($0, []) }
        var others: [RecordingEntry] = []
        for entry in entries {
            let there = Set(entry.people.names.map(fold))
            var placed = false
            for (index, key) in keys.enumerated() where there.contains(key) {
                sections[index].entries.append(entry)
                placed = true
            }
            if !placed { others.append(entry) }
        }
        sections.append((nil, others))
        return sections.filter { !$0.entries.isEmpty }
    }

    /// What a transcript says: the spoken lines only, without the file's
    /// heading, times or side labels. Nil when there is none.
    public static func spokenText(in folder: URL) -> String? {
        TranscriptDocument.lines(in: folder).map { $0.map(\.text).joined(separator: "\n") }
    }

    /// The spoken text folded for matching.
    public static func transcriptText(in folder: URL) -> String? { spokenText(in: folder).map(fold) }

    /// A few words around where `word` is said, for a row found by its
    /// transcript: a little before, the words as said, and what follows,
    /// cut at word edges with an ellipsis. Nil when it is not said.
    public static func excerpt(of word: String, in spoken: String, before: Int = 14, after: Int = 90) -> Excerpt? {
        let text = spoken.replacingOccurrences(of: "\n", with: " ")
        guard !word.isEmpty,
            let match = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
        else { return nil }
        // Before: the last few whole words.
        var start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        var lead = ""
        if start > text.startIndex {
            if let space = text[start..<match.lowerBound].firstIndex(of: " ") {
                start = text.index(after: space)
            } else {
                start = match.lowerBound
            }
            lead = "…"
        }
        // After: as many whole words as fit.
        var end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var tail = ""
        if end < text.endIndex {
            if let space = text[match.upperBound..<end].lastIndex(of: " ") { end = space }
            tail = "…"
        }
        return Excerpt(
            before: lead + text[start..<match.lowerBound], match: String(text[match]),
            after: text[match.upperBound..<end] + tail)
    }

    public struct Excerpt: Sendable, Equatable {
        public var before: String
        public var match: String
        public var after: String
    }

    /// When the recording's transcript last changed, to know a cached text is stale.
    public static func transcriptModified(in folder: URL) -> Date? {
        let file = folder.appendingPathComponent(TranscriptDocument.fileName)
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
