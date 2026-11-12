import Foundation
import Testing

@testable import TapeUpCore

struct VoiceSecondReviewTests {
    @Test func choosingTheSamePersonOnAnotherVoiceDoesNotConfirmThatFill() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Ana", print: voicePrint(0, 1))
        let folder = try f.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        try f.library.fill(in: folder)
        try f.library.name(1, "ANA", in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 2).origin == .filled)
        let examples = VoiceStore.load(from: f.root).people["Ana"]?.examples ?? []
        #expect(!examples.contains { $0.stamp == RecordingLibrary.stamp(of: folder) && $0.voice == 2 })
    }

    @Test func renameUndoAppliesAnInverseAndPreservesUnrelatedEdits() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let renamed = try f.library.renamePerson("Mei", to: "Nora Quinn")
        var people = PeopleList.load(from: f.root)
        people.add(.init(name: "Sam"))
        try people.save(to: f.root)
        try MetaFile.update(folder) { $0["extra"] = "later" }
        _ = try renamed.undo.restore()
        #expect(Set(PeopleList.load(from: f.root).allNames) == ["Mei", "Sam"])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Mei"])
        #expect(MetaFile.read(folder)?["extra"] as? String == "later")
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.count == 1)
    }

    @Test func undoCancelsPendingRenameAndAStaleOnlyCallCannotRedoIt() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"])
        let renamed = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        _ = try renamed.undo.restore()
        _ = try VoiceLibrary(root: f.root).finishPendingRenames()
        _ = try f.library.renamePerson("Mei", to: "Ana", only: renamed.skipped)
        #expect(PeopleList.load(from: f.root).allNames == ["Mei"])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
    }

    @Test func recoveryRecognizesIntermediateAliasesInAPendingChain() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let busy: Set<String> = [RecordingLibrary.stamp(of: folder)]
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: busy)
        // A pre-crash partial write already used the intermediate identity.
        try SpeakerLabels.name(1, "Ana", in: folder)
        _ = try f.library.renamePerson("Ana", to: "Sam", busy: busy)
        _ = try VoiceLibrary(root: f.root).finishPendingRenames()
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Sam")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Sam"])
        #expect(PeopleList.load(from: f.root).allNames == ["Sam"])
    }

    @Test func labelUndoRemovesItsLearningWhileKeepingLaterMeetingLearning() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let first = try f.recording("2026-01-01-1200")
        let second = try f.recording("2026-01-02-1200")
        let undo = try f.library.name(1, "Mei", in: first)
        try f.library.name(1, "Sam", in: second)
        _ = try undo.restore()
        let store = VoiceStore.load(from: f.root)
        #expect(store.people["Mei"]?.examples.isEmpty != false)
        #expect(store.people["Sam"]?.examples.count == 1)
        #expect(SpeakerLabels.result(in: first)?.names[1] == nil)
        #expect(SpeakerLabels.result(in: second)?.names[1] == "Sam")
    }

    @Test func microphoneCorrectionKeepsNegativeWithoutMovingAcousticBar() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Sam", print: voicePrint(0, 1))
        try PeopleList(you: "Sam").save(to: f.root)
        let folder = try f.recording()
        var lines = try #require(TranscriptDocument.lines(in: folder))
        lines[0].side = .microphone
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try MetaFile.update(folder) {
            $0["sources"] = ["microphone", "computer audio"]
            $0["output_headphones"] = true
        }
        let before = VoiceMatching.bar(for: VoiceStore.load(from: f.root).people["Sam"]!)
        try f.library.fill(in: folder)
        try f.library.correct(1, to: "Mei", in: folder)
        let sam = try #require(VoiceStore.load(from: f.root).people["Sam"])
        #expect(sam.negatives.count == 1)
        #expect(VoiceMatching.bar(for: sam) == before)
        #expect(sam.feedback.isEmpty)
    }

    @Test func lookupIgnoresArchivesAndEmptyFoldersButRejectsDuplicateRecordings() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let year = folder.deletingLastPathComponent()
        let stamp = RecordingLibrary.stamp(of: folder)
        try Data().write(to: year.appendingPathComponent(stamp + " Archive.zip"))
        try FileManager.default.createDirectory(
            at: year.appendingPathComponent(stamp + " Empty"), withIntermediateDirectories: false)
        let bogus = year.appendingPathComponent(stamp + " Metadata directory")
        try FileManager.default.createDirectory(
            at: bogus.appendingPathComponent("meta.json"), withIntermediateDirectories: true)
        #expect(RecordingLibrary(root: f.root).folder(withStamp: stamp)?.lastPathComponent == folder.lastPathComponent)
        #expect(RecordingLibrary(root: f.root).recordingFolders().count == 1)
        let copy = year.appendingPathComponent(stamp + " Copy")
        try FileManager.default.copyItem(at: folder, to: copy)
        #expect(RecordingLibrary(root: f.root).folder(withStamp: stamp) == nil)
        let result = try f.library.renamePerson("Mei", to: "Ana")
        #expect(!result.failures.isEmpty)
    }

    @Test func permanentFailuresRetireAliasesAndDoNotForgetAnotherPerson() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"])
        try Data("broken".utf8).write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let result = try f.library.renamePerson("Mei", to: "Ana")
        #expect(result.failures.count == 1)
        #expect(try f.library.finishPendingRenames().isEmpty)
        try f.seed("Mei", print: voicePrint(0, 1))
        try f.library.forgetPerson("Ana")
        #expect(PeopleList.load(from: f.root).contains("Mei"))
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.count == 1)
    }

    @Test func eventRollbackOnlyTruncatesAnActualAppendedSuffix() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let url = folder.appendingPathComponent("events.jsonl")
        let original = try Data(contentsOf: url)
        #expect(EventLog.append("later", in: folder))
        let written = try Data(contentsOf: url)
        #expect(try EventLog.restore(original, ifCurrentIs: written, in: folder))
        #expect(try Data(contentsOf: url) == original)
        #expect(try !EventLog.restore(Data("different prefix".utf8), ifCurrentIs: original, in: folder))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func metadataUpdatesSerializeAgainstAnotherProcess() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, json, pathlib, sys, time
            folder = pathlib.Path(sys.argv[1])
            with (folder / '.meta.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                meta = json.loads((folder / 'meta.json').read_text())
                print('locked', flush=True)
                time.sleep(0.2)
                meta['child'] = True
                (folder / 'meta.json').write_text(json.dumps(meta))
            """, folder.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        #expect(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)?.contains("locked") == true)
        try MetaFile.update(folder) { $0["parent"] = true }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(MetaFile.read(folder)?["child"] as? Bool == true)
        #expect(MetaFile.read(folder)?["parent"] as? Bool == true)
    }

    @Test func forgettingOneRecordingDoesNotResetUnrelatedCalibration() throws {
        var store = VoiceStore()
        store.recordFeedback(for: "Mei", stamp: "affected", voice: 1, similarity: 0.8, confirmed: false)
        store.recordFeedback(for: "Sam", stamp: "old", voice: 1, similarity: 0.8, confirmed: false)
        for index in 0..<25 {
            store.recordFeedback(for: "Sam", stamp: "valid-\(index)", voice: 1, similarity: 1, confirmed: true)
        }
        let before = VoiceMatching.bar(for: store.people["Sam"]!)
        store.forgetRecording("affected")
        #expect(VoiceMatching.bar(for: store.people["Sam"]!) == before)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) == VoiceMatching.Parameters().bar)
    }

    @Test func correctingToAPersonIsAlsoAMissForThatPerson() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0.6, 0.8))
        var store = VoiceStore.load(from: f.root)
        store.recordFeedback(for: "Mei", stamp: "old", voice: 1, similarity: 0.7, confirmed: false)
        try store.save(to: f.root)
        let before = VoiceMatching.bar(for: store.people["Mei"]!)
        let folder = try f.recording(prints: [1: voicePrint(0.6, 0.8)])
        #expect(try f.library.fill(in: folder).first?.person == "Ana")
        try f.library.correct(1, to: "Mei", in: folder)
        let mei = try #require(VoiceStore.load(from: f.root).people["Mei"])
        #expect(mei.feedback.last?.missed == true)
        #expect(VoiceMatching.bar(for: mei) < before)
    }
    @Test func correctionUndoReversesOnlyItsPairsAndKeepsLaterFeedback() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let first = try f.recording("2026-01-01-1200")
        let later = try f.recording("2026-01-02-1200")
        try f.library.fill(in: first)
        let undo = try f.library.correct(1, to: "Ana", in: first)
        try f.library.name(1, "Sam", in: later)
        var store = VoiceStore.load(from: f.root)
        store.recordFeedback(for: "Mei", stamp: "later-feedback", voice: 1, similarity: 0.82, confirmed: false)
        let threshold = VoiceMatching.bar(for: store.people["Mei"]!)
        try store.save(to: f.root)
        let result = try undo.restore()
        let restored = VoiceStore.load(from: f.root)
        #expect(restored.people["Mei"]?.negatives.isEmpty == true)
        #expect(restored.people["Mei"]?.feedback.map(\.stamp) == ["later-feedback"])
        #expect(VoiceMatching.bar(for: restored.people["Mei"]!) == threshold)
        #expect(restored.people["Ana"]?.examples.isEmpty != false)
        #expect(restored.people["Sam"]?.examples.count == 1)
        #expect(SpeakerLabels.result(in: first)?.names[1] == "Mei")
        #expect(result.skipped.contains { $0.lastPathComponent == VoiceStore.fileName })
    }

    @Test func semanticUndoKeepsOtherVoiceEditsInTheSameRecording() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        let undo = try f.library.name(1, "Mei", in: folder)
        try f.library.name(2, "Sam", in: folder)
        try MetaFile.update(folder) { $0["extra"] = "preserved" }
        _ = try undo.restore()
        #expect(SpeakerLabels.result(in: folder)?.names == [2: "Sam"])
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Sam"])
        #expect(MetaFile.read(folder)?["extra"] as? String == "preserved")
        #expect(VoiceStore.load(from: f.root).people["Sam"]?.examples.count == 1)
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.isEmpty != false)
    }

    @Test func mergeUndoIncludesCatchUpsCompletedAfterTheOriginalOperation() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0, 1))
        let folder = try f.recording(
            prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "Ana"], attendees: ["Mei", "Ana"])
        let result = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        _ = try f.library.finishPendingRenames()
        var people = PeopleList.load(from: f.root)
        people.add(.init(name: "Sam"))
        try people.save(to: f.root)
        _ = try result.undo.restore()
        #expect(SpeakerLabels.result(in: folder)?.names == [1: "Mei", 2: "Ana"])
        #expect(Set(RecordingLibrary.entry(at: folder)?.people.names ?? []) == ["Mei", "Ana"])
        #expect(Set(PeopleList.load(from: f.root).allNames) == ["Mei", "Ana", "Sam"])
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.count == 1)
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
    }

    @Test func readonlyPeopleAndVoiceSnapshotsNeverCreateALibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(VoiceStore.count(in: root) == 0)
        #expect(VoiceStore.load(from: root).count == 0)
        #expect(PeopleList.load(from: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func busyInverseRenameStaysPendingWithoutRedoingTheOriginal() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"])
        let forward = try f.library.renamePerson("Mei", to: "Ana")
        let result = try forward.undo.restore(busy: [RecordingLibrary.stamp(of: folder)])
        #expect(result.problem != nil)
        #expect(PeopleList.load(from: f.root).allNames == ["Mei"])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
        _ = try f.library.finishPendingRenames()
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(PeopleList.load(from: f.root).allNames == ["Mei"])
        #expect(try f.library.finishPendingRenames().isEmpty)
    }

    @Test func correctingToTheNameOfAnotherFillLeavesThatFillUnchecked() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0, 1))
        let folder = try f.recording(prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        try f.library.fill(in: folder)
        try f.library.correct(1, to: "ANA", in: folder)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 2).origin == .filled)
        let examples = VoiceStore.load(from: f.root).people["Ana"]?.examples ?? []
        #expect(examples.contains { $0.stamp == RecordingLibrary.stamp(of: folder) && $0.voice == 1 })
        #expect(!examples.contains { $0.stamp == RecordingLibrary.stamp(of: folder) && $0.voice == 2 })
    }

    @Test func mergeUndoRestoresAttendanceWithoutSpeakerFilesAndKeepsFreshMetadata() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0, 1))
        let folder = try f.recording(attendees: ["Mei", "Ana"])
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let rename = try f.library.renamePerson("Mei", to: "Ana")
        try MetaFile.update(folder) {
            $0["extra"] = "later"
            var who = $0["who_was_there"] as? [String: Any] ?? [:]
            who["count"] = 7
            who["names"] = ["Ana", "Sam"]
            $0["who_was_there"] = who
        }
        let undo = try rename.undo.restore()
        #expect(undo.problem == nil)
        #expect(Set(RecordingLibrary.entry(at: folder)?.people.names ?? []) == ["Mei", "Ana", "Sam"])
        #expect(RecordingLibrary.entry(at: folder)?.people.count == 7)
        #expect(MetaFile.read(folder)?["extra"] as? String == "later")
    }

    @Test func labelUndoRestoresCalibrationOnlyIfThereWasNoLaterObservation() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        let before = VoiceStore.load(from: f.root)
        try f.library.fill(in: folder)
        let undo = try f.library.correct(1, to: "Ana", in: folder)
        #expect(VoiceMatching.bar(for: VoiceStore.load(from: f.root).people["Mei"]!) > 0.5)
        #expect(try undo.restore().problem == nil)
        #expect(VoiceStore.load(from: f.root) == before)
        // A retry is harmless, including after the receipt's samples disappeared.
        #expect(try undo.restore().problem == nil)
    }

    @Test func busyLabelUndoKeepsItsTeachingUntilTheRecordingCanBeReversed() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let undo = try f.library.name(1, "Mei", in: folder)
        #expect(try undo.restore(busy: [RecordingLibrary.stamp(of: folder)]).problem != nil)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.count == 1)
        #expect(try undo.restore().problem == nil)
        #expect(SpeakerLabels.result(in: folder)?.names.isEmpty == true)
        #expect(VoiceStore.load(from: f.root).count == 0)
    }

    @Test func undoReportsAnAmbiguousStampAndPreservesBothRecordingsAndLearning() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let undo = try f.library.name(1, "Mei", in: folder)
        let copy = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + " Copy")
        try FileManager.default.copyItem(at: folder, to: copy)
        let result = try undo.restore()
        #expect(result.failures.values.contains { $0.contains("More than one recording") })
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(SpeakerLabels.result(in: copy)?.names[1] == "Mei")
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.examples.count == 1)
    }

    @Test func mergeUndoRestoresFeedbackWhenBothPeopleObservedTheSamePair() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0, 1))
        var store = VoiceStore.load(from: f.root)
        store.recordFeedback(for: "Mei", stamp: "shared", voice: 1, similarity: 0.6, confirmed: false)
        store.recordFeedback(for: "Ana", stamp: "shared", voice: 1, similarity: 0.7, confirmed: true)
        try store.save(to: f.root)
        let rename = try f.library.renamePerson("Mei", to: "Ana")
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.feedback.count == 1)
        #expect(try rename.undo.restore().problem == nil)
        #expect(VoiceStore.load(from: f.root) == store)
    }

    @Test func skippedLabelUndoDoesNotRestoreThatVoicesOldAttendance() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        try f.library.fill(in: folder)
        let undo = try f.library.correct(1, to: "Ana", in: folder)
        try f.library.name(1, "Sam", in: folder)
        try MetaFile.update(folder) { $0["who_was_there"] = ["count": 4, "names": ["Sam"]] }
        #expect(try undo.restore().problem != nil)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Sam")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Sam"])
        #expect(VoiceStore.load(from: f.root).people["Sam"]?.examples.count == 1)
    }

    @Test(arguments: [false, true]) func undoMergeRestoresTheDestinationOfAnOlderRename(catchUpFirst: Bool) throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Sam", print: voicePrint(0, 1))
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let busy: Set<String> = [RecordingLibrary.stamp(of: folder)]
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: busy)
        let merge = try f.library.renamePerson("Ana", to: "Sam", busy: busy)
        if catchUpFirst { _ = try f.library.finishPendingRenames() }
        #expect(try merge.undo.restore().problem == nil)
        _ = try f.library.finishPendingRenames()
        #expect(Set(PeopleList.load(from: f.root).allNames) == ["Ana", "Sam"])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana"])
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
    }

}
