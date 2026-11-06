import Foundation
import Testing

@testable import TapeUpCore

struct RecordingLibraryTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tapeup-test-\(UUID().uuidString)/2026-11-06-1000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "status": "recorded", "audio": "audio.m4a", "duration_seconds": 61.0,
            "started": "2026-11-06T10:00:00Z", "devices": ["inputs": ["Mic"]],
        ]
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        return folder
    }

    @Test func titleSavesTrimmedAndKeepsOtherFields() throws {
        var folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        folder = try RecordingLibrary.save(title: "  Lab sync \n", in: folder)
        #expect(folder.lastPathComponent == "2026-11-06-1000 Lab sync")
        try RecordingLibrary.save(people: .init(count: 3, names: ["Bea"]), in: folder)
        let entry = try #require(RecordingLibrary.entry(at: folder))
        #expect(entry.title == "Lab sync")
        #expect(entry.people == .init(count: 3, names: ["Bea"]))
        let meta = try #require(MetaFile.read(folder))
        #expect(meta["devices"] != nil)
    }

    @Test func emptyTitleRemovesIt() throws {
        var folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        folder = try RecordingLibrary.save(title: "Call", in: folder)
        folder = try RecordingLibrary.save(title: "   ", in: folder)
        #expect(folder.lastPathComponent == "2026-11-06-1000")
        #expect(RecordingLibrary.entry(at: folder)?.title == nil)
        #expect(MetaFile.read(folder)?["title"] == nil)
    }

    @Test func moveTakesRecordingsAndKeepsWhatTheNewRootHas() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("tapeup-move-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        let old = RecordingLibrary(root: base.appendingPathComponent("old"))
        let new = base.appendingPathComponent("new")
        let first = try old.newFolder(at: Date(timeIntervalSince1970: 1_800_000_000))
        let second = try old.newFolder(at: Date(timeIntervalSince1970: 1_800_090_000))
        for folder in [first, second] {
            let meta: [String: Any] = ["status": "recorded", "started": "2026-11-06T10:00:00Z"]
            try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        }
        try "notes".write(to: old.root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try PeopleList(you: "Sam", people: [.init(name: "Bea")]).save(to: old.root)
        // The new root already holds a recording named like the second one, and its own guide.
        let inNew = { (folder: URL) in
            new.appendingPathComponent(
                "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)")
        }
        try manager.createDirectory(at: inNew(second), withIntermediateDirectories: true)
        try "mine".write(to: new.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let result = try old.move(to: new)

        #expect(result.moved == 1)
        #expect(result.skipped == [second.lastPathComponent])
        #expect(manager.fileExists(atPath: inNew(first).path))
        #expect(manager.fileExists(atPath: second.path))
        #expect(try String(contentsOf: new.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "mine")
        #expect(PeopleList.load(from: new).people.map(\.name) == ["Bea"])
        #expect(manager.fileExists(atPath: old.root.appendingPathComponent("summary.md").path))
    }

    @Test func recordingsAreFiledByYear() throws {
        let manager = FileManager.default
        let library = RecordingLibrary(
            root: manager.temporaryDirectory.appendingPathComponent("tapeup-years-\(UUID().uuidString)"))
        defer { try? manager.removeItem(at: library.root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let lastYear = try #require(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23)))
        let thisYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9)))
        let old = try library.newFolder(at: lastYear)
        let new = try library.newFolder(at: thisYear)
        #expect(old.path.hasSuffix("/2025/2025-12-31-2300"))
        #expect(new.path.hasSuffix("/2026/2026-01-01-0900"))
        for (folder, started) in [(old, "2025-12-31T23:00:00Z"), (new, "2026-01-01T09:00:00Z")] {
            let meta: [String: Any] = ["status": "recorded", "started": started]
            try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        }
        // Folders that are not years, such as the user's own, are not recordings.
        try manager.createDirectory(
            at: library.root.appendingPathComponent("notes/2026-01-02-0900"), withIntermediateDirectories: true)
        #expect(library.entries().map(\.folder.lastPathComponent) == ["2026-01-01-0900", "2025-12-31-2300"])
    }

    @Test func folderNamesStayValidAndKeepTheirStamp() {
        #expect(RecordingLibrary.stamp(of: "2026-11-06-1000-2 Old name") == "2026-11-06-1000-2")
        #expect(RecordingLibrary.folderName(stamp: "2026-11-06-1000", title: "a/b: c") == "2026-11-06-1000 a-b- c")
        #expect(RecordingLibrary.folderName(stamp: "2026-11-06-1000", title: "..") == "2026-11-06-1000")
    }

    @Test func renameKeepsTheFolderWhenTheNameIsTaken() throws {
        var folder = try folder()
        let parent = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("2026-11-06-1000 Call"), withIntermediateDirectories: false)
        folder = try RecordingLibrary.save(title: "Call", in: folder)
        #expect(folder.lastPathComponent == "2026-11-06-1000")
        #expect(RecordingLibrary.entry(at: folder)?.title == "Call")
    }
}
