import Foundation
import Testing

@testable import TapeUpCore

struct VoiceReviewTests {
    @Test func undoPreservesLaterPeopleAndStoreEdits() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let first = try f.recording("2026-01-01-1200")
        let second = try f.recording("2026-01-02-1200")
        let undo = try f.library.name(1, "Mei", in: first)
        try f.library.name(1, "Sam", in: second)
        let people = try Data(contentsOf: PeopleList.url(in: f.root))
        let store = try Data(contentsOf: VoiceStore.url(in: f.root))
        try undo.restore()
        #expect(try Data(contentsOf: PeopleList.url(in: f.root)) == people)
        #expect(try Data(contentsOf: VoiceStore.url(in: f.root)) == store)
    }

    @Test func recordingLockIsRespectedWithoutCallerBusyHint() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let held = try #require(FolderLock(folder: folder))
        defer { held.release() }
        let result = try f.library.renamePerson("Mei", to: "Ana")
        #expect(result.changedRecordings.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
    }

    @Test func renameKeepsTranscriptCompletionWrittenJustBeforeMetaWrite() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        try MetaFile.update(folder) { $0["transcript"] = ["status": "transcribing"] }
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            if url.lastPathComponent == "meta.json" {
                try MetaFile.update(folder) { $0["transcript"] = ["status": "done", "model": "test model"] }
            }
        }
        #expect((MetaFile.read(folder)?["transcript"] as? [String: Any])?["status"] as? String == "done")
    }

    @Test func renameAppendsWithoutReplacingAnOpenEventFile() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(attendees: ["Mei"])
        let events = folder.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: events)
        defer { try? handle.close() }
        _ = try f.library.renamePerson("Mei", to: "Ana")
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"event\":\"later\"}\n".utf8))
        #expect(try String(contentsOf: events, encoding: .utf8).contains("later"))
    }

    @Test func applyingPastFillDoesNotConfirmOtherFills() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Mei")
        try f.seed("Ana", print: voicePrint(0, 1))
        let past = try f.recording("2026-01-01-1200", prints: [1: voicePrint(), 2: voicePrint(0, 1)])
        let source = try f.recording("2026-01-02-1200")
        try f.library.fill(in: past)
        let hits = try f.library.pastFills(of: "Mei", closeTo: voicePrint(), excluding: source)
        _ = try f.library.applyPastFills(hits, to: "Sam")
        #expect(SpeakerLabels.result(in: past)?.provenance(for: 2).origin == .filled)
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
    }

    @Test func storeEntryWithoutAPeopleEntryCannotFill() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        var people = PeopleList.load(from: f.root)
        people.remove("Mei")
        try people.save(to: f.root)
        let folder = try f.recording()
        #expect(try f.library.fill(in: folder).isEmpty)
    }

    @Test func confirmingAHighScoringFillNeverRaisesTheBar() throws {
        var store = VoiceStore()
        try store.addExample(voiceExample(), for: "Mei")
        let before = VoiceMatching.bar(for: store.people["Mei"]!)
        store.recordFeedback(for: "Mei", stamp: "confirmed", voice: 1, similarity: 0.9, confirmed: true)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) <= before)
        store.recordFeedback(for: "Mei", stamp: "corrected", voice: 1, similarity: 0.8, confirmed: false)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) > 0.8)
    }

    @Test func unnamingAFillTeachesNotMe() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        try f.library.fill(in: folder)
        try f.library.unname(1, in: folder)
        #expect(VoiceStore.load(from: f.root).people["Mei"]?.negatives.count == 1)
        #expect(try f.library.fill(in: folder).isEmpty)
    }

    @Test func oneUnreadableRecordingDoesNotBlockHealthyRename() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let bad = try f.recording("2026-01-01-1200", names: [1: "Mei"])
        let good = try f.recording("2026-01-02-1200", names: [1: "Mei"])
        try Data("broken".utf8).write(to: bad.appendingPathComponent(SpeakerLabels.resultFileName))
        let result = try f.library.renamePerson("Mei", to: "Ana")
        #expect(result.skipped.count == 1)
        #expect(SpeakerLabels.result(in: good)?.names[1] == "Ana")
    }
    @Test func undoReportsTheFilesWhoseBytesChanged() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let undo = try f.library.name(1, "Mei", in: folder)
        let people = Data(#"{"format":"tapeup-people/1","people":["Sam"]}"#.utf8)
        try people.write(to: PeopleList.url(in: f.root))
        let result = try undo.restore()
        #expect(result.skipped.contains { $0.lastPathComponent == PeopleList.fileName })
        #expect(try Data(contentsOf: PeopleList.url(in: f.root)) == people)
        #expect(!result.restored.isEmpty)
    }

    @Test func forgettingPersonAtomicallyRemovesRootIdentitiesButKeepsHistory() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let undo = try f.library.forgetPerson("mei")
        #expect(!PeopleList.load(from: f.root).contains("Mei"))
        #expect(VoiceStore.load(from: f.root).people["Mei"] == nil)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        try undo.restore()
        #expect(PeopleList.load(from: f.root).contains("Mei"))
        #expect(VoiceStore.load(from: f.root).count == 1)
        try PeopleList(you: "Sam").save(to: f.root)
        try f.library.forgetPerson("Sam")
        #expect(PeopleList.load(from: f.root).you == nil)
    }

    @Test func directStoreForgettingStillWorksAndStaleSavesAreRejected() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        var forgotten = VoiceStore.load(from: f.root)
        forgotten.forgetPerson("Mei")
        try forgotten.save(to: f.root)
        #expect(VoiceStore.load(from: f.root).count == 0)
        var first = VoiceStore.load(from: f.root)
        var second = VoiceStore.load(from: f.root)
        try first.addExample(voiceExample("a"), for: "Ana")
        try first.save(to: f.root)
        try second.addExample(voiceExample("b"), for: "Sam")
        #expect(throws: VoiceLibrary.Failure.concurrentChange) { try second.save(to: f.root) }
        #expect(VoiceStore.load(from: f.root).people["Ana"] != nil)
        var firstPeople = PeopleList.load(from: f.root)
        var secondPeople = PeopleList.load(from: f.root)
        firstPeople.add(.init(name: "Ana"))
        try firstPeople.save(to: f.root)
        secondPeople.add(.init(name: "Sam"))
        #expect(throws: VoiceLibrary.Failure.concurrentChange) { try secondPeople.save(to: f.root) }
        #expect(PeopleList.load(from: f.root).contains("Ana"))
    }

    @Test func namingAMissedVoiceLowersBarUsingScoreBeforeLearning() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(prints: [1: voicePrint(0.6, 0.8)])
        #expect(try f.library.fill(in: folder).isEmpty)
        let initial = VoiceMatching.bar(for: VoiceStore.load(from: f.root).people["Mei"]!)
        try f.library.name(1, "Mei", in: folder)
        let person = try #require(VoiceStore.load(from: f.root).people["Mei"])
        let bar = VoiceMatching.bar(for: person)
        #expect(bar < initial)
        #expect(bar >= 0.6)
        #expect(person.feedback.last?.missed == true)
        #expect(abs((person.feedback.last?.similarity ?? 0) - 0.6) < 0.001)
    }

    @Test func pendingRenamesSurviveRelaunchAndFolderTitleChanges() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let skipped = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        #expect(skipped.skipped.count == 1)
        let pending = f.root.appendingPathComponent(VoiceLibrary.pendingRenamesFileName)
        #expect(FileManager.default.fileExists(atPath: pending.path))
        let titled = folder.deletingLastPathComponent().appendingPathComponent(
            folder.lastPathComponent + " Meeting", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: titled)
        let fresh = VoiceLibrary(root: f.root)
        let result = try fresh.finishPendingRenames()
        #expect(result.count == 1)
        #expect(result.first?.changedRecordings.count == 1)
        #expect(SpeakerLabels.result(in: titled)?.names[1] == "Ana")
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        #expect(try fresh.finishPendingRenames().isEmpty)
    }

    @Test func renamePersistsIntentFirstAndWritesRootIdentitiesLast() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"])
        var names: [String] = []
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            names.append(url.lastPathComponent)
            #expect(
                FileManager.default.fileExists(
                    atPath: f.root.appendingPathComponent(VoiceLibrary.pendingRenamesFileName).path))
            if url.lastPathComponent == "events.jsonl" {
                #expect(PeopleList.load(from: f.root).contains("Mei"))
                #expect(VoiceStore.load(from: f.root).people["Mei"] != nil)
            }
            if url.lastPathComponent == PeopleList.fileName {
                #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
            }
        }
        #expect(names.last == PeopleList.fileName)
    }

    @Test func busyCatchUpRemainsPendingAndUnreadableFolderCanBeRepaired() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(names: [1: "Mei"])
        let url = folder.appendingPathComponent(SpeakerLabels.resultFileName)
        let good = try Data(contentsOf: url)
        try Data("broken".utf8).write(to: url)
        let initial = try f.library.renamePerson("Mei", to: "Ana")
        #expect(initial.failures.count == 1)
        try good.write(to: url)
        let held = try #require(FolderLock(folder: folder))
        let stillBusy = try f.library.finishPendingRenames()
        #expect(stillBusy.first?.skipped.count == 1)
        held.release()
        let finished = try f.library.finishPendingRenames()
        #expect(finished.first?.changedRecordings.count == 1)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
    }

    @Test func metadataPatchesPreserveConcurrentAttendanceCountAndUnknownFields() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(attendees: ["Mei"])
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            if url.lastPathComponent == "meta.json" {
                try MetaFile.update(folder) { meta in
                    var who = meta["who_was_there"] as? [String: Any] ?? [:]
                    who["count"] = 7
                    who["names"] = ["Mei", "Sam"]
                    meta["who_was_there"] = who
                    meta["extra"] = "retained"
                }
            }
        }
        #expect(RecordingLibrary.entry(at: folder)?.people.count == 7)
        #expect(Set(RecordingLibrary.entry(at: folder)?.people.names ?? []) == ["Ana", "Sam"])
        #expect(MetaFile.read(folder)?["extra"] as? String == "retained")
    }

    @Test func aLaterFolderIsReadOnlyWhenItsTurnArrives() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let first = try f.recording("2026-01-01-1200", names: [1: "Mei"])
        let later = try f.recording("2026-01-02-1200", attendees: ["Mei"])
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            if url.lastPathComponent == "events.jsonl",
                url.deletingLastPathComponent().lastPathComponent == first.lastPathComponent
            {
                try MetaFile.update(later) { $0["who_was_there"] = ["count": 8, "names": ["Mei", "Sam"]] }
            }
        }
        #expect(RecordingLibrary.entry(at: later)?.people.count == 8)
        #expect(Set(RecordingLibrary.entry(at: later)?.people.names ?? []) == ["Ana", "Sam"])
    }

    @Test func attendanceRetainsAnotherVoiceWithDifferentlyCasedName() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(
            prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "MEI"],
            provenance: [1: .init(origin: .filled, addedToWhoWasThere: true)], attendees: ["Mei"])
        try f.library.correct(1, to: "Sam", in: folder)
        #expect(RecordingLibrary.entry(at: folder)?.people.names.contains("Mei") == true)
    }

    @Test func rootLockSerializesASecondProcessBeforeReadModifyWrite() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, json, pathlib, sys, time
            root = pathlib.Path(sys.argv[1])
            with (root / '.voices.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                print('locked', flush=True)
                time.sleep(0.2)
                people = json.loads((root / 'people.json').read_text())
                people['people'].append({'name': 'Ana'})
                (root / 'people.json').write_text(json.dumps(people))
                store = json.loads((root / '.voices.json').read_text())
                store['people']['Ana'] = {'examples': [], 'negatives': [], 'feedback': []}
                (root / '.voices.json').write_text(json.dumps(store))
            """, f.root.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        #expect(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)?.contains("locked") == true)
        try f.library.name(1, "Sam", in: folder)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(Set(PeopleList.load(from: f.root).allNames) == ["Mei", "Ana", "Sam"])
        #expect(VoiceStore.load(from: f.root).people["Ana"] != nil)
    }

    @Test func crashBetweenSpeakerAndTranscriptWritesCanFinishAfterRelaunch() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        var result = try #require(SpeakerLabels.result(in: folder))
        result.names[1] = "Ana"
        // This is the on-disk state after the first write and a process exit.
        try JSONEncoder().encode(result).write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        try VoiceFiles.json([
            [
                "id": UUID().uuidString, "old": "Mei", "new": "Ana",
                "stamps": [RecordingLibrary.stamp(of: folder)], "globalsPending": true,
                "activeStamp": RecordingLibrary.stamp(of: folder),
            ]
        ])
        .write(to: f.root.appendingPathComponent(VoiceLibrary.pendingRenamesFileName))
        _ = try VoiceLibrary(root: f.root).finishPendingRenames()
        let text = try String(contentsOf: folder.appendingPathComponent(SpeakerLabels.fileName), encoding: .utf8)
        #expect(text.contains("Ana:"))
        #expect(!text.contains("Mei:"))
        #expect(PeopleList.load(from: f.root).allNames == ["Ana"])
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
    }

    @Test func aGlobalWriteFailureRollsBackAlreadyWrittenRecordingsAndJournal() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        _ = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let before = try f.bytes()
        #expect(throws: CocoaError.self) {
            _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
                if url.lastPathComponent == PeopleList.fileName { throw CocoaError(.fileWriteNoPermission) }
            }
        }
        #expect(try f.bytes() == before)
        #expect(try f.library.finishPendingRenames().isEmpty)
    }

    @Test func recoveryAfterMetaWriteLogsRenameExactlyOnce() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed("Ana")
        let folder = try f.recording(names: [1: "Ana"], attendees: ["Ana"])
        let id = UUID().uuidString
        let journal = try VoiceFiles.json([
            [
                "id": id, "old": "Mei", "new": "Ana",
                "stamps": [RecordingLibrary.stamp(of: folder)], "globalsPending": false,
                "activeStamp": RecordingLibrary.stamp(of: folder),
            ]
        ])
        let pending = f.root.appendingPathComponent(VoiceLibrary.pendingRenamesFileName)
        try journal.write(to: pending)
        _ = try f.library.finishPendingRenames()
        let events = folder.appendingPathComponent("events.jsonl")
        let first = try Data(contentsOf: events)
        #expect(String(decoding: first, as: UTF8.self).contains(id))
        // Replay the pre-progress journal: the event's operation ID prevents a duplicate.
        try journal.write(to: pending)
        _ = try f.library.finishPendingRenames()
        #expect(try Data(contentsOf: events) == first)
    }

    @Test func mismatchedLabelsAreSkippedAndCorruptRelabelClearsAllStampEvidence() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(names: [1: "Mei"])
        try f.library.name(1, "Mei", in: folder)
        let stamp = RecordingLibrary.stamp(of: folder)
        var store = VoiceStore.load(from: f.root)
        try store.addNegative(voiceExample(stamp, print: voicePrint(0, 1)), for: "Sam")
        store.recordFeedback(for: "Mei", stamp: stamp, voice: 1, similarity: 0.7, confirmed: true)
        try store.save(to: f.root)
        let lines = folder.appendingPathComponent(TranscriptDocument.linesFileName)
        try JSONEncoder().encode([TranscriptLine]()).write(to: lines)
        let skipped = try f.library.renamePerson("Mei", to: "Ana")
        #expect(skipped.skipped.count == 1)
        let heard = try #require(VoicePrints.read(in: folder))
        try Data("broken".utf8).write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        _ = try SpeakerLabels.relabel(heard, count: 1, in: folder)
        let cleared = VoiceStore.load(from: f.root)
        #expect(
            cleared.people.values.allSatisfy { person in
                !person.examples.contains { $0.stamp == stamp } && !person.negatives.contains { $0.stamp == stamp }
                    && !person.feedback.contains { $0.stamp == stamp }
            })
    }

    @Test func pendingRenameChainsCatchUpToTheLatestName() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        _ = try f.library.renamePerson("Ana", to: "Sam")
        _ = try VoiceLibrary(root: f.root).finishPendingRenames()
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Sam")
        #expect(PeopleList.load(from: f.root).allNames == ["Sam"])
        #expect(try f.library.finishPendingRenames().isEmpty)
    }

    @Test func metadataPatchDoesNotResurrectAnUnrelatedRemovedAttendee() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(attendees: ["Mei", "Sam"])
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            if url.lastPathComponent == "meta.json" {
                try MetaFile.update(folder) { $0["who_was_there"] = ["names": ["Mei"]] }
            }
        }
        #expect(RecordingLibrary.entry(at: folder)?.people.names == ["Ana"])
    }

    @Test func feedbackRolloverCannotRaiseBarOnConfirmation() throws {
        var store = VoiceStore()
        try store.addExample(voiceExample(), for: "Mei")
        store.recordFeedback(for: "Mei", stamp: "low", voice: 1, similarity: 0.6, confirmed: true)
        for index in 0..<19 {
            store.recordFeedback(for: "Mei", stamp: "high-\(index)", voice: 1, similarity: 0.9, confirmed: true)
        }
        let before = VoiceMatching.bar(for: store.people["Mei"]!)
        store.recordFeedback(for: "Mei", stamp: "next", voice: 1, similarity: 0.9, confirmed: true)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) <= before)
        let encoded = try JSONEncoder().encode(store)
        let loaded = try JSONDecoder().decode(VoiceStore.self, from: encoded)
        #expect(VoiceMatching.bar(for: loaded.people["Mei"]!) == VoiceMatching.bar(for: store.people["Mei"]!))
    }

    @Test func assistantMergeCannotDiscardAConcurrentPeopleEdit() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let prepared = PeopleList.load(from: f.root).merged(with: PeopleList(people: [.init(name: "Sam")]))
        var concurrent = PeopleList.load(from: f.root)
        concurrent.add(.init(name: "Ana"))
        try concurrent.save(to: f.root)
        #expect(throws: VoiceLibrary.Failure.concurrentChange) { try prepared.save(to: f.root) }
        #expect(PeopleList.load(from: f.root).contains("Ana"))
    }

    @Test func eventUndoPreservesLaterAppendsAndReportsThem() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(attendees: ["Mei"])
        let rename = try f.library.renamePerson("Mei", to: "Ana")
        #expect(EventLog.append("later", in: folder))
        let events = folder.appendingPathComponent("events.jsonl")
        let bytes = try Data(contentsOf: events)
        let result = try rename.undo.restore()
        #expect(result.skipped.contains { $0.lastPathComponent == "events.jsonl" })
        #expect(try Data(contentsOf: events) == bytes)
    }

    @Test func eventUndoPreservesAnExistingEventHandle() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(attendees: ["Mei"])
        let url = folder.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let rename = try f.library.renamePerson("Mei", to: "Ana")
        try rename.undo.restore()
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"event\":\"after undo\"}\n".utf8))
        #expect(try String(contentsOf: url, encoding: .utf8).contains("after undo"))
    }

    @Test func pendingRenamesMoveWithTheLibrary() throws {
        let f = try VoiceFixture()
        let target = try VoiceFixture()
        defer {
            f.remove()
            target.remove()
        }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"])
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        _ = try RecordingLibrary(root: f.root).move(to: target.root)
        let result = try target.library.finishPendingRenames()
        #expect(result.first?.changedRecordings.count == 1)
        let moved = try #require(
            RecordingLibrary(root: target.root).folder(withStamp: RecordingLibrary.stamp(of: folder)))
        #expect(SpeakerLabels.result(in: moved)?.names[1] == "Ana")
    }

    @Test func customTuningAppliesToPersistedThresholdChanges() throws {
        var p = VoiceMatching.Parameters()
        p.bar = 0.7
        p.feedbackStep = 0.5
        p.feedbackPadding = 0.02
        var store = VoiceStore()
        try store.addExample(voiceExample(), for: "Mei")
        store.recordFeedback(for: "Mei", stamp: "wrong", voice: 1, similarity: 0.8, confirmed: false, parameters: p)
        #expect(abs(VoiceMatching.bar(for: store.people["Mei"]!, parameters: p) - 0.82) < 0.001)
        store.recordMiss(for: "Mei", stamp: "missed", voice: 1, similarity: 0.72, parameters: p)
        #expect(abs(VoiceMatching.bar(for: store.people["Mei"]!, parameters: p) - 0.77) < 0.001)
    }

    @Test func corruptLabelRecoveryDiscardsCalibrationFromInvalidatedHistory() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        let stamp = RecordingLibrary.stamp(of: folder)
        var store = VoiceStore.load(from: f.root)
        store.recordFeedback(for: "Mei", stamp: stamp, voice: 1, similarity: 0.8, confirmed: false)
        for index in 0..<25 {
            store.recordFeedback(for: "Mei", stamp: "valid-\(index)", voice: 1, similarity: 0.9, confirmed: true)
        }
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) > 0.8)
        #expect(!store.people["Mei"]!.feedback.contains { $0.stamp == stamp })
        try store.save(to: f.root)
        try Data("broken".utf8).write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let heard = try #require(VoicePrints.read(in: folder))
        _ = try SpeakerLabels.relabel(heard, count: 1, in: folder)
        let recovered = try #require(VoiceStore.load(from: f.root).people["Mei"])
        #expect(VoiceMatching.bar(for: recovered) == VoiceMatching.Parameters().bar)
        #expect(recovered.feedback.count == 20)
    }

    @Test func busyRecountKeepsChosenSamplesWhileRenameIsPending() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        try f.library.name(1, "Mei", in: folder)
        _ = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        let heard = try #require(VoicePrints.read(in: folder))
        _ = try SpeakerLabels.relabel(heard, count: 1, in: folder)
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
        _ = try f.library.finishPendingRenames()
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.count == 1)
    }

}
