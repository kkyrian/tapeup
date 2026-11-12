import Foundation
import Testing

@testable import TapeUpCore

struct PersonRenameTests {
    @Test func renameThenInverseRestoresIdentityAndKeepsAudit() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        let first = try fixture.recording(
            names: [1: "Mei"], provenance: [1: .init(origin: .filled, addedToWhoWasThere: true)], attendees: ["Mei"])
        let second = try fixture.recording("2026-01-03-1200", names: [1: "Mei"], attendees: ["Mei"])
        let beforeStore = VoiceStore.load(from: fixture.root)
        let result = try fixture.library.renamePerson("Mei", to: "Priya Shah")
        #expect(result.changedRecordings.count == 2)
        #expect(result.skipped.isEmpty)
        #expect(PeopleList.load(from: fixture.root).allNames == ["Priya Shah"])
        #expect(VoiceStore.load(from: fixture.root).people["Priya Shah"]?.examples.count == 1)
        for folder in [first, second] {
            #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Priya Shah"])
            #expect(SpeakerLabels.result(in: folder)?.names[1] == "Priya Shah")
            #expect(
                try String(contentsOf: folder.appendingPathComponent(SpeakerLabels.fileName), encoding: .utf8).contains(
                    "Priya Shah:"))
            #expect(
                try String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8).contains(
                    "person renamed"))
            #expect(MetaFile.read(folder)?["custom_field"] as? Bool == true)
            #expect(
                try String(contentsOf: folder.appendingPathComponent(TranscriptDocument.fileName), encoding: .utf8)
                    == "original transcript")
        }
        #expect(SpeakerLabels.result(in: first)?.provenance(for: 1).origin == .filled)
        try result.undo.restore()
        #expect(VoiceStore.load(from: fixture.root) == beforeStore)
        #expect(PeopleList.load(from: fixture.root).allNames == ["Mei"])
        for folder in [first, second] {
            #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
            #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Mei"])
        }
    }

    @Test func mergeUnifiesPeopleAttendanceAndVoiceStore() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        try fixture.seed("Ana", print: voicePrint(0, 1))
        var people = PeopleList.load(from: fixture.root)
        _ = people.update("Mei", to: .init(name: "Mei", context: "A note"))
        try people.save(to: fixture.root)
        let folder = try fixture.recording(
            prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "Ana"], attendees: ["Mei", "Ana"])
        let beforeStore = VoiceStore.load(from: fixture.root)
        let result = try fixture.library.renamePerson("Mei", to: "Ana")
        #expect(PeopleList.load(from: fixture.root).people == [.init(name: "Ana", context: "A note")])
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana"])
        #expect(Set(SpeakerLabels.result(in: folder)?.names.values.map { $0 } ?? []) == ["Ana"])
        #expect(VoiceStore.load(from: fixture.root).people["Ana"]?.examples.count == 2)
        try result.undo.restore()
        #expect(VoiceStore.load(from: fixture.root) == beforeStore)
        #expect(Set(PeopleList.load(from: fixture.root).allNames) == ["Mei", "Ana"])
        #expect(SpeakerLabels.result(in: folder)?.names == [1: "Mei", 2: "Ana"])
    }

    @Test func busyFolderIsSkippedAndCanBeCaughtUp() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording(names: [1: "Mei"], attendees: ["Mei"])
        let result = try fixture.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        #expect(result.skipped.map(RecordingLibrary.stamp(of:)) == [RecordingLibrary.stamp(of: folder)])
        #expect(result.changedRecordings.isEmpty)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(PeopleList.load(from: fixture.root).allNames == ["Ana"])
        let caughtUp = try fixture.library.renamePerson("Mei", to: "Ana", only: result.skipped)
        #expect(caughtUp.changedRecordings.map(RecordingLibrary.stamp(of:)) == [RecordingLibrary.stamp(of: folder)])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
    }

    @Test func failureAfterSuccessfulWritesRollsBackExactly() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        _ = try fixture.recording(names: [1: "Mei"], attendees: ["Mei"])
        let before = try fixture.bytes()
        var calls = 0
        #expect(throws: CocoaError.self) {
            _ = try fixture.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
                calls += 1
                if url.lastPathComponent == "events.jsonl" { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        #expect(calls >= 4)
        #expect(try fixture.bytes() == before)
    }

    @Test func inverseRenameAppendsAuditEvenWhenNoEventFileExisted() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording(attendees: ["Mei"])
        let events = folder.appendingPathComponent("events.jsonl")
        try FileManager.default.removeItem(at: events)
        let result = try fixture.library.renamePerson("Mei", to: "Ana")
        #expect(FileManager.default.fileExists(atPath: events.path))
        try result.undo.restore()
        #expect(FileManager.default.fileExists(atPath: events.path))
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Mei"])
    }

    @Test func unreadableLabelsOrMissingLinesAreReportedWithoutChangingThatFolder() throws {
        for breakLines in [false, true] {
            let fixture = try VoiceFixture()
            defer { fixture.remove() }
            try fixture.seed()
            let folder = try fixture.recording(names: [1: "Mei"])
            let target = folder.appendingPathComponent(
                breakLines ? TranscriptDocument.linesFileName : SpeakerLabels.resultFileName)
            try Data("broken".utf8).write(to: target)
            let before = try Data(contentsOf: target)
            let result = try fixture.library.renamePerson("Mei", to: "Ana")
            #expect(result.skipped.count == 1)
            #expect(result.failures.count == 1)
            #expect(try Data(contentsOf: target) == before)
        }
    }

    @Test func renameYourselfAndMergeIntoYou() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try PeopleList(you: "Sam", people: [.init(name: "Ana")]).save(to: fixture.root)
        let folder = try fixture.recording(names: [1: "Sam"], attendees: ["Sam", "Ana"])
        _ = try fixture.library.renamePerson("Sam", to: "Ana")
        #expect(PeopleList.load(from: fixture.root).you == "Ana")
        #expect(PeopleList.load(from: fixture.root).people.isEmpty)
        #expect(MetaFile.read(folder)?["you"] as? String == "Ana")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana"])
    }

    @Test func sameNameIsNoOpAndEmptyNameFails() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let before = try fixture.bytes()
        #expect(try fixture.library.renamePerson("Mei", to: "Mei").undo.fileCount == 0)
        #expect(throws: (any Error).self) { try fixture.library.renamePerson("Mei", to: " ") }
        #expect(try fixture.bytes() == before)
    }

    @Test func movingLibraryCarriesVoiceStore() throws {
        let fixture = try VoiceFixture()
        let destination = try VoiceFixture()
        defer {
            fixture.remove()
            destination.remove()
        }
        try fixture.seed()
        let before = try Data(contentsOf: VoiceStore.url(in: fixture.root))
        _ = try RecordingLibrary(root: fixture.root).move(to: destination.root)
        #expect(try Data(contentsOf: VoiceStore.url(in: destination.root)) == before)
        #expect(!FileManager.default.fileExists(atPath: VoiceStore.url(in: fixture.root).path))
    }
    @Test func listedPersonCanMergeIntoYouWithoutCreatingDuplicate() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try PeopleList(you: "Sam", people: [.init(name: "Ana")]).save(to: fixture.root)
        _ = try fixture.library.renamePerson("Ana", to: "Sam")
        let people = PeopleList.load(from: fixture.root)
        #expect(people.you == "Sam")
        #expect(people.people.isEmpty)
    }

    @Test func unreadableEventTargetIsReportedAndSkipped() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording(names: [1: "Mei"])
        let events = folder.appendingPathComponent("events.jsonl")
        try FileManager.default.removeItem(at: events)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: false)
        let before = try Data(contentsOf: MetaFile.url(in: folder))
        let result = try fixture.library.renamePerson("Mei", to: "Ana")
        #expect(result.skipped.count == 1)
        #expect(result.failures.count == 1)
        #expect(try Data(contentsOf: MetaFile.url(in: folder)) == before)
    }

    @Test func caseOnlyRenameRetainsThePersonAndRawPeopleFields() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        try VoiceFiles.json(["format": PeopleList.format, "custom": "kept", "people": ["Mei", "Ana"]])
            .write(to: PeopleList.url(in: fixture.root))
        let result = try fixture.library.renamePerson("Mei", to: "MEI")
        #expect(Set(PeopleList.load(from: fixture.root).allNames) == ["MEI", "Ana"])
        #expect(VoiceStore.load(from: fixture.root).people["MEI"]?.examples.count == 1)
        #expect(try VoiceFiles.object(PeopleList.url(in: fixture.root))["custom"] as? String == "kept")
        try result.undo.restore()
        #expect(Set(PeopleList.load(from: fixture.root).allNames) == ["Mei", "Ana"])
    }

    @Test func differentlyCasedMergeRekeysExistingVoiceProfileToo() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        try fixture.seed("Ana", print: voicePrint(0, 1))
        _ = try fixture.library.renamePerson("Mei", to: "ana")
        #expect(PeopleList.load(from: fixture.root).allNames == ["ana"])
        let store = VoiceStore.load(from: fixture.root)
        #expect(store.count == 1)
        #expect(store.people["ana"]?.examples.count == 2)
    }

    @Test func mergingAutomaticAttendanceIntoManualAttendanceKeepsItManual() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        try fixture.seed("Ana", print: voicePrint(0, 1))
        let folder = try fixture.recording(attendees: ["Ana"])
        try fixture.library.fill(in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).addedToWhoWasThere == true)
        _ = try fixture.library.renamePerson("Mei", to: "Ana")
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).addedToWhoWasThere == false)
        try fixture.library.correct(1, to: "Nora Quinn", in: folder)
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana", "Nora Quinn"])
    }

    @Test func mergingDifferentCaseNormalizesExistingTargetRecordingNames() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        try fixture.seed("Ana", print: voicePrint(0, 1))
        let folder = try fixture.recording(
            prints: [1: voicePrint(0, 1), 2: voicePrint(0, 1)], names: [1: "Ana"], attendees: ["Ana"])
        _ = try fixture.library.renamePerson("Mei", to: "ana")
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "ana")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["ana"])
        #expect(try fixture.library.fill(in: folder).isEmpty)
    }

}
