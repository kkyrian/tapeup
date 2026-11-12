import Foundation

public enum VoiceMatching {
    /// Tuning changes one value type; no model weights are changed.
    public struct Parameters: Sendable, Equatable {
        public var bar: Float = 0.50
        public var margin: Float = 0.25
        public var minimumSeconds: Double = 30
        public var topK: Int = 3
        public var negativeStart: Float = 0.5
        public var negativeWeight: Float = 0.5
        public var minimumBar: Float = 0.5
        public var maximumBar: Float = 0.85
        public var feedbackStep: Float = 0.2
        public var feedbackPadding: Float = 0.05
        public var pastFillSimilarity: Float = 0.8
        public var microphoneScore: Float = 1
        public init() {}
    }

    public struct Fill: Sendable, Equatable {
        public var voice: Int
        public var person: String
        public var similarity: Float
        public var microphone: Bool
        public init(voice: Int, person: String, similarity: Float, microphone: Bool = false) {
            self.voice = voice
            self.person = person
            self.similarity = similarity
            self.microphone = microphone
        }
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard VoiceStore.validPrint(a), VoiceStore.validPrint(b) else { return -1 }
        var dot = Double(0)
        var aa = Double(0)
        var bb = Double(0)
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            aa += Double(x) * Double(x)
            bb += Double(y) * Double(y)
        }
        return Float(max(-1, min(1, dot / sqrt(aa * bb))))
    }

    /// A centroid can erase channel-dependent modes; a single best example
    /// rewards outliers. The top-k mean retains modes with some corroboration.
    /// Negatives penalize nearby prints without suppressing unrelated voices.
    public static func similarity(
        _ print: [Float], to person: VoiceStore.Person, parameters p: Parameters = Parameters()
    ) -> Float {
        let examples = person.examples.filter { $0.seconds >= p.minimumSeconds }
        guard VoiceStore.validPrint(print), !examples.isEmpty else { return -1 }
        let scores = examples.map { cosine(print, $0.print) }.sorted(by: >).prefix(max(1, p.topK))
        let positive = scores.reduce(0, +) / Float(scores.count)
        let negative =
            person.negatives.filter { $0.seconds >= p.minimumSeconds }.map { cosine(print, $0.print) }.max() ?? -1
        let penalty = max(0, negative - p.negativeStart) / max(Float.ulpOfOne, 1 - p.negativeStart)
        return max(-1, positive - penalty * p.negativeWeight)
    }

    /// A correction whose required bar exceeds the ceiling remains a scoped
    /// veto for that voice, rather than accepting it at a clamped threshold.
    /// Reuse the past-fill closeness gate to identify the corrected voice.
    static func rejectedAtCeiling(_ print: [Float], by person: VoiceStore.Person, parameters p: Parameters) -> Bool {
        person.negatives.contains { negative in
            guard negative.seconds >= p.minimumSeconds else { return false }
            let score =
                negative.correctionScore
                ?? person.feedback.last {
                    $0.stamp == negative.stamp && $0.voice == negative.voice && !$0.confirmed
                }?.similarity
            guard let score, score + p.feedbackPadding > p.maximumBar else { return false }
            return cosine(print, negative.print) >= p.pastFillSimilarity
        }
    }

    /// Confirmations can only lower the bar. A correction at score s raises
    /// it immediately to at least s + padding. A manually named miss between
    /// the minimum and the current bar lowers it partway toward s. Every step
    /// stays within the configured bounds; the accumulated bar is persisted
    /// independently of capped feedback, so trimming history cannot raise it.
    /// No model weights change.
    public static func bar(for person: VoiceStore.Person, parameters p: Parameters = Parameters()) -> Float {
        if let threshold = person.threshold { return min(p.maximumBar, max(p.minimumBar, threshold)) }
        // Migrate old stores by replaying their retained evidence once. New
        // observations persist the resulting bar before history is trimmed.
        return person.feedback.reduce(min(p.maximumBar, max(p.minimumBar, p.bar))) { current, feedback in
            updatedBar(
                current, similarity: feedback.similarity, confirmed: feedback.confirmed,
                missed: feedback.missed == true, parameters: p)
        }
    }

    static func updatedBar(_ current: Float, similarity: Float, confirmed: Bool, missed: Bool, parameters p: Parameters)
        -> Float
    {
        var bar = current
        if missed {
            if similarity > p.minimumBar, similarity < bar { bar += p.feedbackStep * (similarity - bar) }
        } else if confirmed {
            bar = min(bar, similarity - p.feedbackPadding)
        } else {
            bar = max(bar, similarity + p.feedbackPadding)
        }
        return min(p.maximumBar, max(p.minimumBar, bar))
    }

    /// Inputs use the displayed voice numbers, after folding. Existing names
    /// reserve people, so calling this never fills a person twice in a meeting.
    public static func match(
        prints: [Int: [Float]], seconds: [Int: Double], store: VoiceStore, allowedPeople: Set<String>,
        headphones: Bool = false, microphoneOnlyVoices: Set<Int> = [], you: String? = nil,
        named: [Int: String] = [:], parameters p: Parameters = Parameters()
    ) -> [Fill] {
        let allowed = Set(allowedPeople.map { $0.lowercased() })
        var fills: [Fill] = []
        var taken = Set(named.values.map { $0.lowercased() })
        if headphones, microphoneOnlyVoices.count == 1, let voice = microphoneOnlyVoices.first,
            named[voice] == nil, let you, allowed.contains(you.lowercased()), !you.isEmpty,
            !taken.contains(you.lowercased()),
            let talk = seconds[voice], talk.isFinite, talk >= p.minimumSeconds,
            !(prints[voice].flatMap { print in
                store.people.first { $0.key.caseInsensitiveCompare(you) == .orderedSame }
                    .map { rejectedAtCeiling(print, by: $0.value, parameters: p) }
            } ?? false)
        {
            fills.append(Fill(voice: voice, person: you, similarity: p.microphoneScore, microphone: true))
            taken.insert(you.lowercased())
        }
        let voices = prints.keys.sorted().filter { voice in
            named[voice] == nil && !fills.contains { $0.voice == voice }
                && (seconds[voice] ?? 0).isFinite && (seconds[voice] ?? 0) >= p.minimumSeconds
                && VoiceStore.validPrint(prints[voice]!)
        }
        let people = store.people.keys.sorted().filter {
            allowed.contains($0.lowercased()) && !taken.contains($0.lowercased()) && !store.people[$0]!.examples.isEmpty
        }
        guard !voices.isEmpty, !people.isEmpty else { return fills }
        var weights = Array(
            repeating: Array(repeating: Double(0), count: people.count + voices.count), count: voices.count)
        var eligible: [Int: [Int: Float]] = [:]
        for (row, voice) in voices.enumerated() {
            // Reserved people still compete in the margin: being named on a
            // different voice cannot turn an ambiguous print into a clear one.
            let scores = store.people.filter { allowed.contains($0.key.lowercased()) && !$0.value.examples.isEmpty }.map
            { name, person in
                (name, similarity(prints[voice]!, to: person, parameters: p))
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            for (column, person) in people.enumerated() {
                let score = scores.first { $0.0 == person }!.1
                let runnerUp = scores.first { $0.0 != person }?.1 ?? -1
                if score >= bar(for: store.people[person]!, parameters: p), score - runnerUp >= p.margin,
                    !rejectedAtCeiling(prints[voice]!, by: store.people[person]!, parameters: p)
                {
                    eligible[row, default: [:]][column] = score
                    weights[row][column] = Double(score)
                } else {
                    weights[row][column] = -1
                }
            }
        }
        for (row, column) in assignment(weights).enumerated() {
            if let score = eligible[row]?[column] {
                fills.append(Fill(voice: voices[row], person: people[column], similarity: score))
            }
        }
        return fills.sorted { $0.voice < $1.voice }
    }

    /// Hungarian assignment, with an unmatched dummy column for every voice.
    /// Maximizes total eligible similarity, independent of voice iteration order.
    static func assignment(_ weights: [[Double]]) -> [Int] {
        let n = weights.count
        guard n > 0 else { return [] }
        let m = weights[0].count
        var u = Array(repeating: 0.0, count: n + 1)
        var v = Array(repeating: 0.0, count: m + 1)
        var owner = Array(repeating: 0, count: m + 1)
        var way = Array(repeating: 0, count: m + 1)
        for row in 1...n {
            owner[0] = row
            var column = 0
            var distance = Array(repeating: Double.infinity, count: m + 1)
            var used = Array(repeating: false, count: m + 1)
            repeat {
                used[column] = true
                let current = owner[column]
                var delta = Double.infinity
                var next = 0
                for j in 1...m where !used[j] {
                    let cost = -weights[current - 1][j - 1] - u[current] - v[j]
                    if cost < distance[j] {
                        distance[j] = cost
                        way[j] = column
                    }
                    if distance[j] < delta {
                        delta = distance[j]
                        next = j
                    }
                }
                for j in 0...m {
                    if used[j] {
                        u[owner[j]] += delta
                        v[j] -= delta
                    } else {
                        distance[j] -= delta
                    }
                }
                column = next
            } while owner[column] != 0
            repeat {
                let previous = way[column]
                owner[column] = owner[previous]
                column = previous
            } while column != 0
        }
        var result = Array(repeating: -1, count: n)
        for j in 1...m where owner[j] != 0 { result[owner[j] - 1] = j - 1 }
        return result
    }
}
