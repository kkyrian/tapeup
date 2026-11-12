import Foundation
import Testing

@testable import TapeUpCore

struct VoiceFixture {
    let root: URL
    var library: VoiceLibrary { VoiceLibrary(root: root) }
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
            "voices-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func recording(
        _ stamp: String = "2026-01-02-1200", prints: [Int: [Float]] = [1: voicePrint()], names: [Int: String] = [:],
        provenance: [Int: SpeakerProvenance] = [:], attendees: [String] = []
    ) throws -> URL {
        let folder = root.appendingPathComponent("2026/\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = prints.keys.sorted().enumerated().map { index, voice in
            TranscriptLine(
                start: Double(index * 100), end: Double((index + 1) * 100), text: "A quoted line from voice \(voice).")
        }
        let turns = zip(lines, prints.keys.sorted()).map { VoiceTurn(start: $0.0.start, end: $0.0.end, voice: $0.1) }
        let heard = VoicePrints(turns: turns, prints: prints)
        var result = SpeakerLabels.label(lines: lines, heard: heard, count: prints.count)
        result.names = names
        result.provenance = provenance
        try VoiceFiles.json([
            "status": "transcribed", "started": "2026-01-02T12:00:00Z", "you": "Sam", "custom_field": true,
            "who_was_there": ["count": 4, "names": attendees],
            "transcript": ["status": "done", "model": "test model", "missing_passages": 1],
        ]).write(to: MetaFile.url(in: folder))
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try heard.save(in: folder)
        try SpeakerLabels.save(result, lines: lines, in: folder)
        try Data("original transcript".utf8).write(to: folder.appendingPathComponent(TranscriptDocument.fileName))
        try Data("{\"event\":\"saved\"}\n".utf8).write(to: folder.appendingPathComponent("events.jsonl"))
        return folder
    }

    func seed(_ name: String = "Mei", print: [Float] = voicePrint()) throws {
        var store = VoiceStore.load(from: root)
        try store.addExample(voiceExample("seed-\(name)", print: print), for: name)
        try store.save(to: root)
        var people = PeopleList.load(from: root)
        people.add(.init(name: name))
        try people.save(to: root)
    }

    func bytes() throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }
}

struct VoiceLibraryTests {
    @Test func oldSpeakerFilesDefaultToPersonAndNewProvenanceRoundTrips() throws {
        let data = Data(#"{"count":1,"estimated":true,"voices":[],"assigned":[],"names":{"1":"Mei"}}"#.utf8)
        var result = try JSONDecoder().decode(SpeakerResult.self, from: data)
        #expect(result.provenance(for: 1).origin == .person)
        result.provenance[1] = .init(origin: .filled, addedToWhoWasThere: true, similarity: 0.8)
        #expect(try JSONDecoder().decode(SpeakerResult.self, from: JSONEncoder().encode(result)) == result)
    }

    @Test func fillsAttendButDoNotLearnOrAddPeople() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording()
        let store = try Data(contentsOf: VoiceStore.url(in: fixture.root))
        let people = try Data(contentsOf: PeopleList.url(in: fixture.root))
        #expect(try fixture.library.fill(in: folder).first?.person == "Mei")
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .filled)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).addedToWhoWasThere == true)
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Mei"])
        #expect(RecordingLibrary.entry(at: folder)?.people.count == 4)
        #expect(try Data(contentsOf: VoiceStore.url(in: fixture.root)) == store)
        #expect(try Data(contentsOf: PeopleList.url(in: fixture.root)) == people)
        #expect(try fixture.library.fill(in: folder).isEmpty)
    }

    @Test func namingLearnsReplacesAndUnnamingRemoves() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording()
        try fixture.library.name(1, "Mei", in: folder)
        #expect(VoiceStore.load(from: fixture.root).people["Mei"]?.examples.count == 1)
        #expect(PeopleList.load(from: fixture.root).contains("Mei"))
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Mei"])
        try fixture.library.name(1, "Ana", in: folder)
        #expect(VoiceStore.load(from: fixture.root).people["Mei"]?.examples.isEmpty == true)
        #expect(VoiceStore.load(from: fixture.root).people["Ana"]?.examples.count == 1)
        try fixture.library.unname(1, in: folder)
        #expect(VoiceStore.load(from: fixture.root).count == 0)
        #expect(SpeakerLabels.result(in: folder)?.names.isEmpty == true)
    }

    @Test func confirmationLearnsOnceAndMovesPersonalBar() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording()
        try fixture.library.fill(in: folder)
        try fixture.library.confirm(1, in: folder)
        let store = VoiceStore.load(from: fixture.root)
        #expect(store.people["Mei"]?.examples.count == 2)
        #expect(store.people["Mei"]?.feedback.count == 1)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .confirmed)
        try fixture.library.confirmFills(in: folder)
        #expect(VoiceStore.load(from: fixture.root) == store)
    }

    @Test func correctionAddsNegativeAndCleansOnlyAutomaticAttendance() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording()
        try fixture.library.fill(in: folder)
        let undo = try fixture.library.correct(1, to: "Ana", in: folder)
        let store = VoiceStore.load(from: fixture.root)
        #expect(store.people["Mei"]?.negatives.count == 1)
        #expect(store.people["Mei"]?.feedback.last?.confirmed == false)
        #expect(store.people["Ana"]?.examples.count == 1)
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana"])
        try undo.restore()
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        let attended = try fixture.recording("2026-01-03-1200", attendees: ["Mei"])
        try fixture.library.fill(in: attended)
        try fixture.library.correct(1, to: "Ana", in: attended)
        #expect(RecordingLibrary.entry(at: attended)?.people.names == ["Mei", "Ana"])
    }

    @Test func aLabelChoiceConfirmsOnlyFillsLeftStanding() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        try fixture.library.fill(in: folder)
        try fixture.library.name(2, "Ana", in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .confirmed)
        #expect(VoiceStore.load(from: fixture.root).people["Mei"]?.examples.count == 2)
        #expect(VoiceStore.load(from: fixture.root).people["Ana"]?.examples.count == 1)
    }

    @Test func explicitConfirmAllAndUnnameDoNotConfirmOtherVoices() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        try fixture.seed("Ana", print: voicePrint(0, 1))
        let folder = try fixture.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        try fixture.library.fill(in: folder)
        try fixture.library.unname(2, in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .filled)
        try fixture.library.confirmFills(in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .confirmed)
    }

    @Test func missingAudioStillAllowsLabelLearningFromSavedPrints() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording()
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
        try fixture.library.name(1, "Nora Quinn", in: folder)
        #expect(VoiceStore.load(from: fixture.root).count == 1)
    }

    @Test func recountPreservesUnconfirmedProvenance() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording()
        try fixture.library.fill(in: folder)
        let heard = try #require(VoicePrints.read(in: folder))
        let result = try SpeakerLabels.relabel(heard, count: 1, in: folder)
        #expect(result.provenance(for: 1).origin == .filled)
        #expect(result.provenance(for: 1).addedToWhoWasThere)
    }

    @Test func invalidVoiceOrEmptyPersonLeavesFilesUntouched() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording()
        let before = try fixture.bytes()
        #expect(throws: (any Error).self) { try fixture.library.name(3, "Ana", in: folder) }
        #expect(throws: (any Error).self) { try fixture.library.name(1, " ", in: folder) }
        #expect(try fixture.bytes() == before)
    }

    @Test func pastFillsPreviewApplyAndUndoExcludeConfirmedAndNewer() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let first = try fixture.recording("2026-01-01-1200")
        let confirmed = try fixture.recording("2026-01-02-1200")
        let source = try fixture.recording("2026-01-03-1200")
        let newer = try fixture.recording("2026-01-04-1200")
        for folder in [first, confirmed, source, newer] { try fixture.library.fill(in: folder) }
        try fixture.library.confirm(1, in: confirmed)
        try fixture.library.correct(1, to: "Ana", in: source)
        let before = try fixture.bytes()
        let hits = try fixture.library.pastFills(of: "Mei", closeTo: voicePrint(), excluding: source)
        #expect(hits.count == 1)
        #expect(hits.first?.stamp == RecordingLibrary.stamp(of: first))
        #expect(hits.first?.quote == "A quoted line from voice 1.")
        #expect(hits.first?.similarity == 1)
        #expect(try fixture.bytes() == before)
        let applied = try fixture.library.applyPastFills(hits, to: "Ana")
        #expect(applied.changed.count == 1)
        #expect(SpeakerLabels.result(in: first)?.names[1] == "Ana")
        #expect(RecordingLibrary.entry(at: first)?.people.names == ["Ana"])
        #expect(VoiceStore.load(from: fixture.root).people["Mei"]?.negatives.count == 2)
        try applied.undo.restore()
        #expect(try fixture.bytes() == before)
    }

    @Test func staleOrBusyPastFillsAreSkipped() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed()
        let folder = try fixture.recording("2026-01-01-1200")
        let source = try fixture.recording("2026-01-02-1200")
        try fixture.library.fill(in: folder)
        let hits = try fixture.library.pastFills(of: "Mei", closeTo: voicePrint(), excluding: source)
        let busy = try fixture.library.applyPastFills(hits, to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        #expect(busy.changed.isEmpty)
        #expect(busy.skipped.count == 1)
        try fixture.library.confirm(1, in: folder)
        let stale = try fixture.library.applyPastFills(hits, to: "Ana")
        #expect(stale.changed.isEmpty)
        #expect(stale.skipped.count == 1)
    }
    @Test func concurrentLabelChoicesDoNotLoseStoreOrPeopleUpdates() async throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let first = try fixture.recording("2026-01-01-1200")
        let second = try fixture.recording("2026-01-02-1200")
        let library = fixture.library
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try library.name(1, "Mei", in: first) }
            group.addTask { _ = try library.name(1, "Ana", in: second) }
            try await group.waitForAll()
        }
        #expect(VoiceStore.load(from: fixture.root).count == 2)
        #expect(Set(PeopleList.load(from: fixture.root).allNames) == ["Mei", "Ana"])
    }

    @Test func microphonesCanFillWithoutExamplesButOnlyConfirmOnLabelAction() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try PeopleList(you: "Sam").save(to: fixture.root)
        let folder = try fixture.recording()
        var lines = try #require(TranscriptDocument.lines(in: folder))
        lines[0].side = .microphone
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try MetaFile.update(folder) { meta in
            meta["sources"] = ["microphone", "computer audio"]
            meta["output_headphones"] = true
        }
        #expect(try fixture.library.fill(in: folder).first?.person == "Sam")
        #expect(VoiceStore.load(from: fixture.root).count == 0)
        try fixture.library.name(1, "Sam", in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .confirmed)
        #expect(VoiceStore.load(from: fixture.root).count == 1)
    }

    @Test func recountMovesChosenExamplesBeforeUnnamingAndDropsLostExamples() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1), 3: voicePrint(0, 1)])
        let lines = [
            TranscriptLine(start: 0, end: 100, text: "First voice."),
            TranscriptLine(start: 100, end: 190, text: "Second voice."),
            TranscriptLine(start: 190, end: 270, text: "Third voice."),
        ]
        let heard = VoicePrints(
            turns: [
                VoiceTurn(start: 0, end: 100, voice: 1),
                VoiceTurn(start: 100, end: 190, voice: 2),
                VoiceTurn(start: 190, end: 270, voice: 3),
            ], prints: [1: voicePrint(), 2: voicePrint(0, 1), 3: voicePrint(0, 1)])
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try heard.save(in: folder)
        try SpeakerLabels.save(SpeakerLabels.label(lines: lines, heard: heard, count: 3), lines: lines, in: folder)
        try fixture.library.name(1, "Mei", in: folder)
        try fixture.library.name(2, "Ana", in: folder)
        try fixture.library.name(3, "Sam", in: folder)
        let result = try SpeakerLabels.relabel(heard, count: 2, in: folder)
        #expect(result.names == [1: "Ana", 2: "Mei"])
        let moved = VoiceStore.load(from: fixture.root)
        #expect(moved.people["Mei"]?.examples.first?.voice == 2)
        #expect(moved.people["Ana"]?.examples.first?.voice == 1)
        #expect(moved.people["Sam"]?.examples.isEmpty == true)
        try fixture.library.unname(1, in: folder)
        let store = VoiceStore.load(from: fixture.root)
        #expect(store.people["Mei"]?.examples.count == 1)
        #expect(store.people["Ana"]?.examples.isEmpty == true)
    }

    @Test func manualChoicesReuseKnownNameSpellingAndStoreIdentity() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        try fixture.seed("Mei")
        let folder = try fixture.recording()
        try fixture.library.name(1, "mei", in: folder)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(VoiceStore.load(from: fixture.root).count == 1)
        #expect(VoiceStore.load(from: fixture.root).people["Mei"]?.examples.count == 2)
        let store = VoiceStore.load(from: fixture.root)
        #expect(
            VoiceMatching.match(prints: [2: voicePrint()], seconds: [2: 100], store: store, named: [1: "MEI"]).isEmpty)
    }

    @Test func unreadableEarlierLabelsCannotLeaveLearningAttachedToReplacedVoices() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let folder = try fixture.recording()
        try fixture.library.name(1, "Mei", in: folder)
        try Data("broken".utf8).write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let heard = try #require(VoicePrints.read(in: folder))
        let before = try fixture.bytes()
        #expect(throws: (any Error).self) { try SpeakerLabels.relabel(heard, count: 1, in: folder) }
        #expect(try fixture.bytes() == before)
    }

}
