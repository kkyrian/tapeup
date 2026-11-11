import Foundation
import Testing

@testable import TapeUpCore

struct NameSuggesterTests {
    let people = PeopleList(
        you: "Sam",
        people: [
            .init(name: "Priya Shah", context: "advisor"), .init(name: "Mei"), .init(name: "José Ortiz"),
            .init(name: "Bo"),
        ])

    func entry(_ day: Int, _ names: [String]) -> RecordingEntry {
        let folder = URL(fileURLWithPath: "/tmp/\(day)")
        return RecordingEntry(
            folder: folder, started: Date(timeIntervalSince1970: Double(day) * 86_400), duration: 60,
            audio: folder.appendingPathComponent("audio.m4a"), status: "recorded",
            people: .init(count: names.count + 1, names: names))
    }

    @Test func withNothingTypedYouThenPastRecordingsThenTheList() {
        let suggester = NameSuggester(entries: [entry(1, ["Bo"]), entry(2, ["Bo", "Ana"])], people: people)
        #expect(
            suggester.suggestions(matching: "", excluding: [], limit: 5) == ["Sam", "Bo", "Ana", "Priya Shah", "Mei"])
    }

    @Test func youCanBeTypedAndLeaveOnceChosen() {
        let suggester = NameSuggester(entries: [entry(1, ["Bo"])], people: people)
        #expect(suggester.suggestions(matching: "sa", excluding: []).first == "Sam")
        #expect(!suggester.suggestions(matching: "", excluding: ["sam"]).contains("Sam"))
        let unnamed = NameSuggester(entries: [], people: PeopleList(you: nil, people: [.init(name: "Bo")]))
        #expect(unnamed.suggestions(matching: "", excluding: []) == ["Bo"])
    }

    @Test func matchesStartOfAnyWord() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(suggester.suggestions(matching: "sha", excluding: []) == ["Priya Shah"])
    }

    @Test func matchesInitialsAndLettersInOrder() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(suggester.suggestions(matching: "ps", excluding: []).first == "Priya Shah")
        #expect(suggester.suggestions(matching: "prya", excluding: []) == ["Priya Shah"])
    }

    @Test func ignoresAccentsAndCase() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(suggester.suggestions(matching: "JOSE", excluding: []) == ["José Ortiz"])
    }

    @Test func matchesContext() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(suggester.suggestions(matching: "advis", excluding: []) == ["Priya Shah"])
    }

    @Test func prefixBeatsLooseMatches() {
        let suggester = NameSuggester(
            entries: [], people: PeopleList(people: [.init(name: "Abel"), .init(name: "Bea")]))
        #expect(suggester.suggestions(matching: "be", excluding: []) == ["Bea", "Abel"])
    }

    @Test func leavesOutChosenNames() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(!suggester.suggestions(matching: "", excluding: ["mei"]).contains("Mei"))
    }

    @Test func knowsTheStoredSpelling() {
        let suggester = NameSuggester(entries: [], people: people)
        #expect(suggester.knownSpelling(of: "jose ortiz") == "José Ortiz")
    }
}
