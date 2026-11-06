import Foundation
import Testing

@testable import TapeUpCore

struct PeopleListTests {
    @Test func parsesAnAnswerInsideACodeBlockWithProse() throws {
        let answer = """
            Here is your list:
            ```json
            {"format": "tapeup-people/1", "you": "Sam", "people": [{"name": "Priya", "context": "advisor"}, {"name": "Mei"}]}
            ```
            Let me know if you want changes.
            """
        let list = try PeopleList.parse(answer)
        #expect(list.you == "Sam")
        #expect(list.people == [.init(name: "Priya", context: "advisor"), .init(name: "Mei")])
    }

    @Test func acceptsPlainNamesAndSkipsJunk() throws {
        let list = try PeopleList.parse(#"{"people": ["Ana", " ", 4, {"context": "x"}, {"name": "Bo "}]}"#)
        #expect(list.people.map(\.name) == ["Ana", "Bo"])
    }

    @Test func dropsDuplicatesAndTheUserThemselves() throws {
        let list = try PeopleList.parse(
            #"{"you": "Sam", "people": [{"name": "sam"}, {"name": "Ana"}, {"name": "ANA", "context": "TA"}]}"#)
        #expect(list.people == [.init(name: "Ana", context: "TA")])
    }

    @Test func rejectsTextWithoutAList() {
        #expect(throws: PeopleList.ParseError.self) { try PeopleList.parse("Sorry, I can't help with that.") }
        #expect(throws: PeopleList.ParseError.self) { try PeopleList.parse(#"{"people": []}"#) }
        #expect(throws: PeopleList.ParseError.self) { try PeopleList.parse("{not json}") }
    }

    @Test func mergeKeepsEveryoneAndAddsNewPeople() {
        let old = PeopleList(you: "Sam", people: [.init(name: "Ana"), .init(name: "Bo")])
        let new = PeopleList(you: nil, people: [.init(name: "bo", context: "TA"), .init(name: "Cy")])
        let merged = old.merged(with: new)
        #expect(merged.you == "Sam")
        #expect(merged.people == [.init(name: "Ana"), .init(name: "Bo", context: "TA"), .init(name: "Cy")])
    }

    @Test func savesAndLoadsTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let list = PeopleList(you: "Sam", people: [.init(name: "Ana", context: "advisor")])
        try list.save(to: root)
        #expect(PeopleList.load(from: root) == list)
    }

    @Test func promptNamesTheFileAndTheFormat() {
        let prompt = PeopleList.assistantPrompt(root: URL(fileURLWithPath: "/Users/x/TapeUp"))
        #expect(prompt.contains("/Users/x/TapeUp/people.json"))
        #expect(prompt.contains(PeopleList.format))
    }

    @Test func takesTheFilledListAfterARepeatedTemplate() throws {
        let answer = """
            You asked for {"format": "tapeup-people/1", "you": "<my name>", "people": [{"name": "<name>"}]}.
            Here it is {as requested}:
            {"format": "tapeup-people/1", "you": "Sam", "people": [{"name": "Ana {the TA}"}]}
            Hope that helps!}
            """
        let list = try PeopleList.parse(answer)
        #expect(list.you == "Sam")
        #expect(list.people.map(\.name) == ["Ana {the TA}"])
    }

    @Test func rejectsTheBareTemplate() {
        #expect(throws: PeopleList.ParseError.self) {
            try PeopleList.parse(#"{"you": "<my name>", "people": [{"name": "<name>"}]}"#)
        }
    }

    @Test func refusesToLoadAnUnreadableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #"{"people": [{"name": "Ana"}"#.write(to: PeopleList.url(in: root), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try PeopleList.loadChecked(from: root) }
        let aside = try PeopleList.setAsideUnreadable(in: root)
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(try PeopleList.loadChecked(from: root).isEmpty)
    }
}
