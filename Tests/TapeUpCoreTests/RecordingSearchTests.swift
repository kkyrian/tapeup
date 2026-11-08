import Foundation
import Testing

@testable import TapeUpCore

struct RecordingSearchTests {
    private func entry(
        _ day: Double, title: String? = nil, count: Int? = nil, names: [String] = [],
        transcript: RecordingEntry.Transcript = .none
    ) -> RecordingEntry {
        let folder = URL(fileURLWithPath: "/tmp/library/2026/2026-11-\(Int(day))")
        return RecordingEntry(
            folder: folder, started: Date(timeIntervalSince1970: day * 86_400), duration: 60,
            audio: folder.appendingPathComponent("audio.m4a"), status: "recorded",
            people: .init(count: count, names: names), title: title, transcript: transcript)
    }

    @Test func frequentPeopleAreCountedOncePerRecordingMostFirst() {
        let entries = [
            entry(5, names: ["Priya Shah", "Mei"]), entry(4, names: ["mei", "José Ortiz"]),
            entry(3, names: ["Priya Shah", "Priya Shah"]), entry(2, names: ["Mei"]), entry(1, names: ["Ana"]),
        ]
        let people = RecordingSearch.frequentPeople(in: entries, limit: 3)
        #expect(people.map(\.name) == ["Mei", "Priya Shah", "José Ortiz"])
        #expect(people.map(\.count) == [3, 2, 1])
    }

    @Test func tiesGoToWhoeverWasMetMoreRecently() {
        let entries = [entry(9, names: ["Ana"]), entry(8, names: ["Sam"]), entry(1, names: ["Ana", "Sam"])]
        #expect(RecordingSearch.frequentPeople(in: entries).map(\.name) == ["Ana", "Sam"])
    }

    @Test func spellingsDifferingOnlyInAccentsAreOnePersonShownAsLatestWritten() {
        let entries = [entry(9, names: ["José Ortiz"]), entry(1, names: ["jose ortiz"])]
        let people = RecordingSearch.frequentPeople(in: entries)
        #expect(people.count == 1)
        #expect(people.first?.name == "José Ortiz")
        #expect(people.first?.count == 2)
    }

    @Test func noFrequentPeopleWithoutNames() {
        #expect(RecordingSearch.frequentPeople(in: [entry(1, count: 4), entry(2)]).isEmpty)
    }

    @Test func noNamesYetLeavesOutRecordingsOfJustTheUser() {
        #expect(RecordingSearch.needsNames(entry(1)))
        #expect(RecordingSearch.needsNames(entry(1, count: 3)))
        #expect(!RecordingSearch.needsNames(entry(1, count: 1)))
        #expect(!RecordingSearch.needsNames(entry(1, count: 2, names: ["Mei"])))
    }

    @Test func noTranscriptIsAnythingNotFinished() {
        #expect(RecordingSearch.needsTranscript(entry(1, transcript: .none)))
        #expect(RecordingSearch.needsTranscript(entry(1, transcript: .pending)))
        #expect(RecordingSearch.needsTranscript(entry(1, transcript: .failed)))
        #expect(!RecordingSearch.needsTranscript(entry(1, transcript: .done)))
    }

    @Test func chipsCombineSoEveryOneMustHold() {
        let both = entry(3, names: ["Priya Shah", "Mei"], transcript: .done)
        let priya = entry(2, names: ["Priya Shah"])
        let none = entry(1, count: 4)
        let entries = [both, priya, none]
        func shown(_ filter: RecordingFilter) -> [RecordingEntry] {
            entries.filter { filter.matches($0, transcript: nil) }
        }
        #expect(shown(RecordingFilter()) == entries)
        #expect(shown(RecordingFilter(people: ["Priya Shah"])) == [both, priya])
        #expect(shown(RecordingFilter(people: ["Priya Shah", "Mei"])) == [both])
        #expect(shown(RecordingFilter(people: ["priya shah"])) == [both, priya])
        #expect(shown(RecordingFilter(people: ["Priya Shah"], noTranscript: true)) == [priya])
        #expect(shown(RecordingFilter(noNames: true)) == [none])
        #expect(shown(RecordingFilter(people: ["Mei"], noNames: true)).isEmpty)
    }

    @Test func searchFindsTitlesNamesAndTranscriptWordsInAnyCaseOrAccent() {
        let review = entry(2, title: "Design review", names: ["José Ortiz"])
        #expect(RecordingFilter(query: "design").matches(review, transcript: nil))
        #expect(RecordingFilter(query: "JOSE").matches(review, transcript: nil))
        #expect(RecordingFilter(query: "  review   josé ").matches(review, transcript: nil))
        #expect(!RecordingFilter(query: "budget").matches(review, transcript: nil))
        let said = RecordingSearch.fold("We need the Budget numbers before Thursday.")
        #expect(RecordingFilter(query: "budget").matches(review, transcript: said))
        // Every word must be found, across title, names and transcript.
        #expect(RecordingFilter(query: "jose budget").matches(review, transcript: said))
        #expect(!RecordingFilter(query: "jose zebra").matches(review, transcript: said))
    }

    @Test func aSuggestedTitleIsSearchedToo() {
        var memo = entry(1)
        memo.titleSuggestion = "Survey kickoff"
        #expect(RecordingFilter(query: "kickoff").matches(memo, transcript: nil))
    }

    @Test func blankSearchIsNoFilter() {
        #expect(RecordingFilter(query: "   ").isEmpty)
        #expect(!RecordingFilter(query: "a").isEmpty)
        #expect(!RecordingFilter(noNames: true).isEmpty)
    }

    @Test func byPersonPutsSharedRecordingsInEachSectionAndTheRestInOthers() {
        let both = entry(3, names: ["Priya Shah", "Mei"])
        let mei = entry(2, names: ["mei"])
        let solo = entry(1, count: 1)
        let sections = RecordingSearch.byPerson([both, mei, solo], people: ["Priya Shah", "Mei", "Ana"])
        #expect(sections.map(\.person) == ["Priya Shah", "Mei", nil])
        #expect(sections[0].entries == [both])
        #expect(sections[1].entries == [both, mei])
        #expect(sections[2].entries == [solo])
        #expect(RecordingSearch.byPerson([mei], people: ["Mei"]).map(\.person) == ["Mei"])
        #expect(RecordingSearch.byPerson([], people: ["Mei"]).isEmpty)
    }

    @Test func transcriptTextIsTheSpokenLinesOnly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(RecordingSearch.transcriptText(in: folder) == nil)
        let text = TranscriptDocument.render(
            lines: [
                TranscriptLine(start: 0, end: 5, side: .microphone, text: "Thanks for joining, José."),
                TranscriptLine(start: 5, end: 9, side: .computer, text: "Happy to be here."),
            ], labeled: true, model: "Qwen3-ASR 1.7B")
        try text.write(
            to: folder.appendingPathComponent(TranscriptDocument.fileName), atomically: true, encoding: .utf8)
        let folded = try #require(RecordingSearch.transcriptText(in: folder))
        #expect(folded.contains("thanks for joining, jose."))
        #expect(folded.contains("happy to be here"))
        // The heading, the model and the side labels are not what was said.
        #expect(!folded.contains("mac"))
        #expect(!folded.contains("microphone"))
        #expect(!folded.contains("qwen"))
        #expect(RecordingSearch.transcriptModified(in: folder) != nil)
    }
}
