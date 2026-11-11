import Foundation

/// Suggests who was there from past recordings and the people list.
///
/// With nothing typed: people named most often in past recordings first,
/// then the people list in its own order (most frequent first, as the
/// assistant was asked). The user's own name, when set, comes first: they
/// are in most of their meetings, though not all. While typing, a forgiving match: the start of the
/// name, the start of any word, initials ("ps" for Priya Shah), the letters
/// in order ("prya"), or the context ("advisor").
public struct NameSuggester: Sendable {
    struct Candidate {
        let name: String
        let folded: String
        let words: [String]
        let context: String
        var uses = 0
        var lastUsed = Date.distantPast
        var listOrder = Int.max
        var isYou = false
    }

    private var candidates: [String: Candidate] = [:]

    public init(entries: [RecordingEntry], people: PeopleList) {
        for entry in entries {
            for name in entry.people.names {
                update(name, context: nil) { candidate in
                    candidate.uses += 1
                    candidate.lastUsed = max(candidate.lastUsed, entry.started)
                }
            }
        }
        for (index, person) in people.people.enumerated() {
            update(person.name, context: person.context) { $0.listOrder = min($0.listOrder, index) }
        }
        if let you = people.you, !you.trimmingCharacters(in: .whitespaces).isEmpty {
            update(you, context: nil) { $0.isYou = true }
        }
    }

    private mutating func update(_ name: String, context: String?, _ change: (inout Candidate) -> Void) {
        let key = Self.fold(name)
        var candidate =
            candidates[key]
            ?? Candidate(
                name: name, folded: key,
                words: key.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init),
                context: Self.fold(context ?? ""))
        if candidate.context.isEmpty, let context { candidate = candidate.with(context: Self.fold(context)) }
        change(&candidate)
        candidates[key] = candidate
    }

    public func suggestions(matching query: String, excluding chosen: [String], limit: Int = 6) -> [String] {
        let taken = Set(chosen.map(Self.fold))
        let needle = Self.fold(query).trimmingCharacters(in: .whitespaces)
        let ranked =
            candidates.values
            .filter { !taken.contains($0.folded) }
            .compactMap { candidate -> (Candidate, Int)? in
                guard !needle.isEmpty else { return (candidate, 0) }
                return Self.score(candidate, needle).map { (candidate, $0) }
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.isYou != b.0.isYou { return a.0.isYou }
                if a.0.uses != b.0.uses { return a.0.uses > b.0.uses }
                if a.0.lastUsed != b.0.lastUsed { return a.0.lastUsed > b.0.lastUsed }
                if a.0.listOrder != b.0.listOrder { return a.0.listOrder < b.0.listOrder }
                return a.0.name < b.0.name
            }
        return ranked.prefix(limit).map(\.0.name)
    }

    /// The spelling already known for a typed name, if any.
    public func knownSpelling(of name: String) -> String? {
        candidates[Self.fold(name)]?.name
    }

    static func score(_ candidate: Candidate, _ needle: String) -> Int? {
        if candidate.folded == needle { return 1000 }
        if candidate.folded.hasPrefix(needle) { return 900 }
        if candidate.words.contains(where: { $0.hasPrefix(needle) }) { return 800 }
        let compact = needle.replacingOccurrences(of: " ", with: "")
        if compact.count >= 2, String(candidate.words.compactMap(\.first)).hasPrefix(compact) { return 700 }
        if let gaps = subsequenceGaps(compact, in: candidate.folded) { return 500 - min(gaps, 200) }
        if !candidate.context.isEmpty, candidate.context.contains(needle) { return 300 }
        return nil
    }

    /// How many letters were skipped matching `needle` in order, or nil when
    /// the letters do not all appear in order.
    static func subsequenceGaps(_ needle: String, in text: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        var gaps = 0
        var index = text.startIndex
        for character in needle {
            guard let found = text[index...].firstIndex(of: character) else { return nil }
            gaps += text.distance(from: index, to: found)
            index = text.index(after: found)
        }
        return gaps
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NameSuggester.Candidate {
    fileprivate func with(context: String) -> Self {
        var copy = Self(name: name, folded: folded, words: words, context: context)
        copy.uses = uses
        copy.lastUsed = lastUsed
        copy.listOrder = listOrder
        copy.isYou = isYou
        return copy
    }
}
