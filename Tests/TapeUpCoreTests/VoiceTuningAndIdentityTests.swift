import Foundation
import Testing

@testable import TapeUpCore

struct VoiceTuningAndIdentityTests {
    private func titled(_ folder: URL) throws -> URL {
        let destination = folder.deletingLastPathComponent().appendingPathComponent(
            folder.lastPathComponent + " Meeting", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: destination)
        return destination
    }

    @Test func defaultsPinTheChosenOperatingPoint() {
        let p = VoiceMatching.Parameters()
        #expect(p.topK == 3)
        #expect(p.bar == 0.50)
        #expect(p.margin == 0.25)
        #expect(p.minimumSeconds == 30)
        #expect(p.minimumBar == 0.50)
        #expect(p.maximumBar == 0.85)
    }

    @Test func scoreIsMeanOfThreeBestCosines() throws {
        var store = VoiceStore()
        for (index, cosine) in [Float(0), 0.6, 0.8, 1].enumerated() {
            try store.addExample(
                voiceExample("\(index)", print: voicePrint(cosine, sqrt(1 - cosine * cosine))), for: "Mei")
        }
        #expect(abs(VoiceMatching.similarity(voicePrint(), to: store.people["Mei"]!) - 0.8) < 0.0001)
    }

    @Test func transcriptSpansCannotMakeShortDiarizedSpeechFillOrTeach() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        let heard = VoicePrints(turns: [.init(start: 0, end: 29.99, voice: 1)], prints: [1: voicePrint()])
        try heard.save(in: folder)
        #expect(try f.library.fill(in: folder).isEmpty)
        try f.library.name(1, "Ana", in: folder)
        #expect(VoiceStore.load(from: f.root).people["Ana"]?.examples.isEmpty != false)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
    }

    @Test func allOwnTurnsCountEvenWhenMostSpeechHasNoTranscriptLine() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording()
        let lines = [TranscriptLine(start: 0, end: 5, text: "A short line.")]
        let heard = VoicePrints(
            turns: [.init(start: 0, end: 15, voice: 1), .init(start: 20, end: 35, voice: 1)], prints: [1: voicePrint()])
        try heard.save(in: folder)
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try SpeakerLabels.save(SpeakerLabels.label(lines: lines, heard: heard, count: 1), lines: lines, in: folder)
        #expect(try f.library.fill(in: folder).first?.person == "Mei")
        try f.library.confirm(1, in: folder)
        let example = VoiceStore.load(from: f.root).people["Mei"]?.examples.first {
            $0.stamp == RecordingLibrary.stamp(of: folder)
        }
        #expect(example?.seconds == 30)
    }

    @Test func thirtySecondGateAlsoAppliesToMicrophoneIdentity() {
        func match(_ seconds: Double) -> [VoiceMatching.Fill] {
            VoiceMatching.match(
                prints: [:], seconds: [1: seconds], store: VoiceStore(), allowedPeople: ["Sam"],
                headphones: true, microphoneOnlyVoices: [1], you: "Sam")
        }
        #expect(match(29.99).isEmpty)
        #expect(match(30).first?.person == "Sam")
    }

    @Test func shortExamplesCannotEnterTheStore() {
        var store = VoiceStore()
        #expect(throws: VoiceStore.StoreError.self) { try store.addExample(voiceExample(seconds: 29.99), for: "Mei") }
        #expect(throws: VoiceStore.StoreError.self) { try store.addNegative(voiceExample(seconds: 29.99), for: "Mei") }
    }

    @Test func correctionBeyondCeilingRejectsThatVoiceWithoutDisablingOtherVoices() throws {
        var store = VoiceStore()
        try store.addExample(voiceExample("positive"), for: "Mei")
        try store.addExample(voiceExample("other", print: voicePrint(0, 1)), for: "Mei")
        try store.addNegative(voiceExample("wrong"), for: "Mei")
        store.recordFeedback(for: "Mei", stamp: "wrong", voice: 1, similarity: 0.9, confirmed: false)
        for index in 0..<25 {
            store.recordFeedback(for: "Mei", stamp: "confirmed-\(index)", voice: 1, similarity: 1, confirmed: true)
        }
        var p = VoiceMatching.Parameters()
        p.topK = 1
        p.negativeWeight = 0
        let loaded = try JSONDecoder().decode(VoiceStore.self, from: JSONEncoder().encode(store))
        #expect(VoiceMatching.bar(for: loaded.people["Mei"]!) == 0.85)
        #expect(
            VoiceMatching.match(
                prints: [1: voicePrint()], seconds: [1: 100], store: loaded, allowedPeople: ["Mei"], parameters: p
            ).isEmpty)
        #expect(
            VoiceMatching.match(
                prints: [1: voicePrint(0, 1)], seconds: [1: 100], store: loaded, allowedPeople: ["Mei"], parameters: p
            ).first?.person == "Mei")
    }

    @Test func pastFillAppliesAfterTheRecordingFolderIsTitled() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording("2026-01-01-1200")
        let source = try f.recording("2026-01-02-1200")
        try f.library.fill(in: folder)
        let hits = try f.library.pastFills(of: "Mei", closeTo: voicePrint(), excluding: source)
        let moved = try titled(folder)
        #expect(hits.first?.recording.lastPathComponent == moved.lastPathComponent)
        let result = try f.library.applyPastFills(hits, to: "Sam")
        #expect(result.changed.count == 1)
        #expect(result.skipped.isEmpty)
        #expect(SpeakerLabels.result(in: moved)?.names[1] == "Sam")
    }

    @Test func undoFindsTheRecordingAtItsNewTitleAndRestoresOriginalBytes() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let filenames = ["meta.json", SpeakerLabels.resultFileName, SpeakerLabels.fileName]
        let originals = try filenames.map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let undo = try f.library.name(1, "Mei", in: folder)
        let moved = try titled(folder)
        let result = try undo.restore()
        #expect(result.skipped.isEmpty)
        for (file, original) in zip(filenames, originals) {
            #expect(try Data(contentsOf: moved.appendingPathComponent(file)) == original)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func staleCatchUpURLsAreConvertedToStamps() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let initial = try f.library.renamePerson("Mei", to: "Ana", busy: [RecordingLibrary.stamp(of: folder)])
        let moved = try titled(folder)
        let result = try f.library.renamePerson("Mei", to: "Ana", only: initial.skipped)
        #expect(result.changedRecordings.count == 1)
        #expect(SpeakerLabels.result(in: moved)?.names[1] == "Ana")
    }

    @Test func titleChangeBetweenWritesDoesNotLeaveTheOperationHalfDone() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        var moved: URL?
        let result = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
            if url.lastPathComponent == "meta.json", moved == nil { moved = try titled(folder) }
        }
        let current = try #require(moved)
        #expect(SpeakerLabels.result(in: current)?.names[1] == "Ana")
        #expect(RecordingLibrary.entry(at: current)?.people.names == ["Ana"])
        #expect(try result.undo.restore().skipped.isEmpty)
        #expect(SpeakerLabels.result(in: current)?.names[1] == "Mei")
    }
    @Test func shortConfirmedAndCorrectedVoicesDoNotChangeExamplesOrCalibration() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        for (index, confirm) in [true, false].enumerated() {
            let folder = try f.recording(
                "2026-01-0\(index + 1)-1200", names: [1: "Mei"],
                provenance: [1: .init(origin: .filled, similarity: 0.9)])
            try VoicePrints(turns: [.init(start: 0, end: 20, voice: 1)], prints: [1: voicePrint()]).save(in: folder)
            if confirm { try f.library.confirm(1, in: folder) } else { try f.library.correct(1, to: "Ana", in: folder) }
        }
        let store = VoiceStore.load(from: f.root)
        #expect(store.people["Mei"]?.examples.count == 1)
        #expect(store.people["Mei"]?.negatives.isEmpty == true)
        #expect(store.people["Mei"]?.feedback.isEmpty == true)
        #expect(store.people["Ana"]?.examples.isEmpty != false)
    }

    @Test func diarizedDurationsFollowFoldingAndDisplayedVoiceNumbers() throws {
        let lines = [
            TranscriptLine(start: 0, end: 5, text: "First."), TranscriptLine(start: 10, end: 100, text: "Second."),
        ]
        let heard = VoicePrints(
            turns: [.init(start: 0, end: 5, voice: 101), .init(start: 10, end: 45, voice: 202)],
            prints: [101: voicePrint(), 202: voicePrint(0, 1)])
        let separate = SpeakerLabels.label(lines: lines, heard: heard, count: 2)
        #expect(separate.assigned == [2, 1])
        #expect(SpeakerLabels.diarizedSeconds(of: separate, heard: heard, lines: lines) == [1: 35, 2: 5])
        let folded = SpeakerLabels.label(lines: lines, heard: heard, count: 1)
        #expect(SpeakerLabels.diarizedSeconds(of: folded, heard: heard, lines: lines) == [1: 40])
        var mismatch = separate
        mismatch.assigned = [1, 2]
        #expect(SpeakerLabels.diarizedSeconds(of: mismatch, heard: heard, lines: lines).isEmpty)
    }

    @Test func correctionAtTheCeilingCanStillFillButAboveItCannot() throws {
        var store = VoiceStore()
        try store.addExample(voiceExample("positive"), for: "Mei")
        try store.addNegative(voiceExample("wrong"), for: "Mei")
        store.recordFeedback(for: "Mei", stamp: "wrong", voice: 1, similarity: 0.8, confirmed: false)
        var parameters = VoiceMatching.Parameters()
        parameters.negativeWeight = 0
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) == parameters.maximumBar)
        #expect(
            VoiceMatching.match(
                prints: [1: voicePrint()], seconds: [1: 30], store: store, allowedPeople: ["Mei"],
                parameters: parameters
            ).count == 1)
        store.recordFeedback(for: "Mei", stamp: "wrong", voice: 1, similarity: 0.81, confirmed: false)
        #expect(
            VoiceMatching.match(
                prints: [1: voicePrint()], seconds: [1: 30], store: store, allowedPeople: ["Mei"],
                parameters: parameters
            ).isEmpty)
        #expect(
            VoiceMatching.match(
                prints: [1: voicePrint()], seconds: [1: 30], store: store, allowedPeople: ["MEI"],
                headphones: true, microphoneOnlyVoices: [1], you: "MEI", parameters: parameters
            ).isEmpty)
    }

    @Test func negativeScoreMustBeFiniteAndLegacyShortExamplesAreNotUsed() throws {
        var store = VoiceStore()
        #expect(throws: VoiceStore.StoreError.self) {
            try store.addNegative(voiceExample(), for: "Mei", similarity: .nan)
        }
        var person = VoiceStore.Person()
        person.examples = [voiceExample(seconds: 29.99)]
        #expect(VoiceMatching.similarity(voicePrint(), to: person) == -1)
    }

    @Test func undoPreservesLaterEditsAfterTitlingAndReportsTheCurrentPath() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let undo = try f.library.name(1, "Mei", in: folder)
        let moved = try titled(folder)
        try MetaFile.update(moved) { $0["extra"] = "later edit" }
        let result = try undo.restore()
        #expect(
            result.skipped.contains {
                $0.lastPathComponent == "meta.json"
                    && $0.deletingLastPathComponent().lastPathComponent == moved.lastPathComponent
            })
        #expect(MetaFile.read(moved)?["extra"] as? String == "later edit")
    }

    @Test func undoNeverRecreatesADeletedRecording() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let undo = try f.library.name(1, "Mei", in: folder)
        try FileManager.default.removeItem(at: folder)
        let result = try undo.restore()
        #expect(!result.skipped.isEmpty)
        #expect(RecordingLibrary(root: f.root).folder(withStamp: RecordingLibrary.stamp(of: folder)) == nil)
    }

    @Test func retitledPastFillsStillRespectBusyAndConfirmedGuards() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording("2026-01-01-1200")
        let source = try f.recording("2026-01-02-1200")
        try f.library.fill(in: folder)
        let hits = try f.library.pastFills(of: "Mei", closeTo: voicePrint(), excluding: source)
        let moved = try titled(folder)
        let held = try #require(FolderLock(folder: moved))
        let busy = try f.library.applyPastFills(hits, to: "Sam")
        #expect(busy.changed.isEmpty && busy.skipped.count == 1)
        held.release()
        // Even a caller holding the pre-title URL names the current recording.
        try f.library.confirm(1, in: folder)
        let stale = try f.library.applyPastFills(hits, to: "Sam")
        #expect(stale.changed.isEmpty && stale.skipped.count == 1)
        #expect(SpeakerLabels.result(in: moved)?.names[1] == "Mei")
    }

    @Test func failedRenameRollsBackAtTheRetitledPath() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        try f.seed()
        let folder = try f.recording(names: [1: "Mei"], attendees: ["Mei"])
        let before = try Data(contentsOf: folder.appendingPathComponent("events.jsonl"))
        var moved: URL?
        #expect(throws: CocoaError.self) {
            _ = try f.library.renamePerson("Mei", to: "Ana", busy: [], only: nil) { url in
                if url.lastPathComponent == "events.jsonl" {
                    moved = try titled(folder)
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        }
        let current = try #require(moved)
        #expect(SpeakerLabels.result(in: current)?.names[1] == "Mei")
        #expect(RecordingLibrary.entry(at: current)?.people.names == ["Mei"])
        #expect(try Data(contentsOf: current.appendingPathComponent("events.jsonl")) == before)
        #expect(try f.library.finishPendingRenames().isEmpty)
    }

    @Test func microphoneCorrectionsWithNoEnrollmentRejectTheSameVoiceLater() throws {
        for legacy in [false, true] {
            let f = try VoiceFixture()
            defer { f.remove() }
            try PeopleList(you: "Sam").save(to: f.root)
            func microphoneRecording(_ stamp: String) throws -> URL {
                let folder = try f.recording(stamp)
                var lines = try #require(TranscriptDocument.lines(in: folder))
                lines[0].side = .microphone
                try JSONEncoder().encode(lines).write(
                    to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
                try MetaFile.update(folder) {
                    $0["sources"] = ["microphone", "computer audio"]
                    $0["output_headphones"] = true
                }
                return folder
            }
            let first = try microphoneRecording("2026-01-01-1200")
            #expect(try f.library.fill(in: first).first?.person == "Sam")
            if legacy {
                var old = try #require(SpeakerLabels.result(in: first))
                old.provenance[1]?.similarity = nil
                try SpeakerLabels.save(old, lines: try #require(TranscriptDocument.lines(in: first)), in: first)
            }
            try f.library.correct(1, to: "Mei", in: first)
            #expect(VoiceStore.load(from: f.root).people["Sam"]?.negatives.first?.correctionScore == 1)
            let second = try microphoneRecording("2026-01-02-1200")
            #expect(try f.library.fill(in: second).first?.person == "Mei")
        }
    }

    @Test func titleChangesAndMetadataWritesUseOneConsistentCriticalSection() async throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        let root = f.root
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<40 {
                    _ = try RecordingLibrary.save(title: index.isMultiple(of: 2) ? "Meeting" : nil, in: folder)
                }
            }
            group.addTask {
                for index in 0..<40 {
                    _ = try VoiceFiles.withRootLock(root) {
                        try VoiceFiles.apply([.meta(folder, { $0["test_marker"] = index })])
                    }
                }
            }
            try await group.waitForAll()
        }
        let current = try #require(RecordingLibrary(root: root).folder(withStamp: RecordingLibrary.stamp(of: folder)))
        #expect(MetaFile.read(current)?["test_marker"] as? Int == 39)
        #expect(
            !FileManager.default.fileExists(atPath: folder.path)
                || current.lastPathComponent == folder.lastPathComponent)
    }

}
