import Foundation
import Testing

@testable import TapeUpCore

/// The review's public command paths, using the same isolated subprocess
/// fixture as CLITests. Its sandbox denies every write to the real Trash.
struct CLIReviewTests {
    @Test func lockCannotBeUnlockedByACommand() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        try RecordingLibrary.save(keepAudio: true, in: folder)
        let stamp = RecordingLibrary.stamp(of: folder)
        let off = try f.run(["keep", stamp, "off"])
        #expect(off.status == 2 && off.object["error"] as? String == "usage")
        #expect(RecordingLibrary.entry(at: folder)?.keepAudio == true)
        let removed = try f.run(["remove-audio", stamp])
        #expect(removed.object["error"] as? String == "kept")
        #expect((removed.object["suggestion"] as? String)?.contains("unlock") == true)
        #expect(removed.object["retryable"] as? Bool == false)
    }

    @Test func namingOneVoiceNeverLearnsOtherFills() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try f.files.seed("Nora Quinn", print: voicePrint(0, 1))
        let folder = try f.files.recording(
            prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "Nora Quinn"],
            provenance: [1: .init(origin: .filled), 2: .init(origin: .filled)])
        let before = VoiceStore.load(from: f.files.root).people["Nora Quinn"]
        let reply = try f.run(["voices", "name", RecordingLibrary.stamp(of: folder), "1", "Ana"])
        #expect(reply.status == 0)
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 2).origin == .filled)
        #expect(VoiceStore.load(from: f.files.root).people["Nora Quinn"] == before)
    }

    @Test func aPastFillCommandCarriesAStaleFillGuard() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let earlier = try f.files.recording(
            "2026-01-01-1200", prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "Nora Quinn"],
            provenance: [1: .init(origin: .filled), 2: .init(origin: .filled)])
        let source = try f.files.recording(names: [1: "Mei"], provenance: [1: .init(origin: .filled)])
        let reply = try f.run(["voices", "name", RecordingLibrary.stamp(of: source), "1", "Ana"])
        let hits = reply.object["past_fills"] as? [[String: Any]]
        let command = try #require(hits?.first?["command"] as? String)
        #expect(command.contains("--if-fill "))
        let before = try #require(SpeakerLabels.result(in: earlier))
        #expect(try f.shell(command).status == 0)
        #expect(SpeakerLabels.result(in: earlier)?.names[1] == "Ana")
        #expect(SpeakerLabels.result(in: earlier)?.provenance(for: 2).origin == .filled)
        #expect(VoiceStore.load(from: f.files.root).people["Nora Quinn"] == nil)
        try SpeakerLabels.save(before, lines: try #require(TranscriptDocument.lines(in: earlier)), in: earlier)
        let heard = try #require(VoicePrints.read(in: earlier))
        try VoicePrints(turns: heard.turns, prints: [1: voicePrint(0, -1), 2: voicePrint(0, 1)]).save(in: earlier)
        let stale = try f.shell(command)
        #expect(stale.object["error"] as? String == "stale_fill" && stale.object["retryable"] as? Bool == false)
        #expect(SpeakerLabels.result(in: earlier)?.names[1] == "Mei")
    }

    @Test func helpAndNextAskForIdentificationAndNeverNameLatest() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        _ = try f.files.recording()
        let help = try f.run(["help"], json: false).out
        #expect(!help.contains("voices name latest"))
        #expect(help.contains("after the user says") || help.contains("After the user says"))
        #expect(help.contains("the recording that started most recently"))
        let next = try f.run(["voices", "latest"]).object["next"] as? String ?? ""
        #expect(next.contains("Ask the user"))
        #expect(next.contains(#"2026-01-02-1200 1 "<name>""#))
        #expect(!next.contains("latest"))
        let placeholder = try f.run(["voices", "name", "latest", "1", "<name>"])
        #expect(placeholder.status == 2 && placeholder.object["error"] as? String == "usage")
        #expect((placeholder.object["suggestion"] as? String)?.contains("user said") == true)
    }

    @Test func deadWorkersDoNotLeaveBusyMarkers() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        try MetaFile.update(folder) { $0["transcript"] = ["status": "transcribing", "pid": Int32.max] }
        let reply = try f.run(["voices", "name", RecordingLibrary.stamp(of: folder), "1", "Mei"])
        #expect(reply.status == 0, "\(reply.err)")
        #expect((MetaFile.read(folder)?["transcript"] as? [String: Any])?["status"] as? String != "transcribing")
    }

    @Test func aloneLabelingFillsRememberedVoicesWithoutTeachingThem() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try f.files.seed("Mei")
        let folder = try f.files.recording()
        try Data("cached prints need no decoder".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let store = VoiceStore.load(from: f.files.root)
        let reply = try f.run(["speakers", RecordingLibrary.stamp(of: folder)])
        #expect(reply.status == 0, "\(reply.err)")
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        #expect(SpeakerLabels.result(in: folder)?.provenance(for: 1).origin == .filled)
        #expect(VoiceStore.load(from: f.files.root) == store)
    }

    @Test func missingAudioIsAPermanentActionableRefusal() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let reply = try f.run(["speakers", RecordingLibrary.stamp(of: folder), "--voices", "2"])
        #expect(reply.status == 1 && reply.object["error"] as? String == "no_audio")
        #expect(reply.object["retryable"] as? Bool == false)
        #expect((reply.object["suggestion"] as? String)?.contains("Put Back") == true)
    }

    @Test func incompleteRecordingsCannotLoseTheirAudio() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        try Data("fixture audio".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        let stamp = RecordingLibrary.stamp(of: folder)
        let incomplete = try f.run(["remove-audio", stamp])
        #expect(incomplete.object["error"] as? String == "incomplete_transcript")
        try MetaFile.update(folder) { $0["transcript"] = ["status": "done", "missing_passages": 0] }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let unlabeled = try f.run(["remove-audio", stamp])
        #expect(unlabeled.object["error"] as? String == "no_speakers")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.m4a").path))
    }

    @Test func nextUsesExecutableAndDoesNotStartUnrequestedWork() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let voices = try f.run(["voices", RecordingLibrary.stamp(of: folder)])
        let next = voices.object["next"] as? String ?? ""
        let binary = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["TAPEUP_CLI_BINARY"] ?? ".build/debug/TapeUp"
        ).resolvingSymlinksInPath().path
        #expect(next.contains(binary))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let kept = try f.run(["keep", RecordingLibrary.stamp(of: folder)])
        #expect(kept.object["next"] == nil)
    }

    @Test func punctuatedSuggestionsUseTheRunningExecutable() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let reply = try f.run(["unknown-command"])
        #expect(reply.status == 2)
        #expect(reply.object["suggestion"] as? String == "Run \(f.command("help")).")
    }

    @Test func jsonErrorsAreEntirelyParseable() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let reply = try f.run(["import", f.files.root.appendingPathComponent("missing.wav").path])
        let whole = try? JSONSerialization.jsonObject(with: Data(reply.err.utf8)) as? [String: Any]
        #expect(whole?["error"] as? String == "not_found")
        #expect((whole?["message"] as? String)?.contains("No file at") == true)
        #expect(reply.out.isEmpty)
    }

    @Test func unknownPeopleAndHistoricalDestinationsAreRefused() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try f.files.seed("Mei")
        for words in [["people", "remove", "Mie"], ["people", "rename", "Mie", "Ana"]] {
            let reply = try f.run(words)
            #expect(reply.object["error"] as? String == "not_found")
            #expect((reply.object["message"] as? String)?.contains("Mei") == true)
        }
        _ = try f.files.recording(names: [1: "Nora Quinn"])
        #expect(try f.run(["people", "rename", "Mei", "Nora Quinn"]).object["error"] as? String == "name_taken")
    }

    @Test func duplicateImportReportsIgnoredTitleAndDocumentPaths() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let source = try f.tone()
        let candidate = try await RecordingImport.inspect(source)
        let folder = try f.files.recording()
        try RecordingLibrary.markTranscript("done", in: folder)
        try MetaFile.update(folder) {
            $0["imported"] = ["fingerprint": candidate.fingerprint]
            $0["title"] = "Mei interview"
        }
        let reply = try f.run(["import", source.path, "--title", "Ana interview"])
        #expect(reply.object["title_applied"] as? Bool == false)
        #expect(reply.object["title"] as? String == "Mei interview")
        #expect(
            URL(fileURLWithPath: try #require(reply.object["transcript"] as? String)).resolvingSymlinksInPath()
                == folder.appendingPathComponent(TranscriptDocument.fileName).resolvingSymlinksInPath())
        #expect(
            URL(fileURLWithPath: try #require(reply.object["labeled_transcript"] as? String)).resolvingSymlinksInPath()
                == folder.appendingPathComponent(SpeakerLabels.fileName).resolvingSymlinksInPath())
    }

    @Test func executableRenderingPreservesQuotedSourceAndTitle() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let original = try f.tone()
        let source = original.deletingLastPathComponent().appendingPathComponent("TapeUp interview.wav")
        try FileManager.default.moveItem(at: original, to: source)
        let candidate = try await RecordingImport.inspect(source)
        let folder = try f.files.recording()
        try MetaFile.update(folder) { $0["imported"] = ["fingerprint": candidate.fingerprint] }
        try Data("fixture audio".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let held = try #require(FolderLock(folder: folder))
        defer { held.release() }
        let reply = try f.run(["import", source.path, "--title", "TapeUp review"])
        #expect(
            reply.object["suggestion"] as? String
                == "Run the same import again: \(f.command("import \"\(source.path)\" --title \"TapeUp review\""))")
    }

    @Test func aRunnablePathCanAlsoUseTheSameExecutableOnPATH() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let reply = try f.shell(f.command("voices \(RecordingLibrary.stamp(of: folder))"))
        #expect(reply.status == 0)
        #expect((reply.object["next"] as? String)?.contains("TapeUp voices name") == true)
        #expect((reply.object["next"] as? String)?.contains(f.tool) == false)
    }

    @Test func busyRefusalsExplainTheHolderAndNextAction() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let held = try #require(FolderLock(folder: folder))
        defer { held.release() }
        let reply = try f.run(["keep", RecordingLibrary.stamp(of: folder)])
        #expect((reply.object["message"] as? String)?.contains("lock") == true)
        #expect(!(reply.object["suggestion"] as? String ?? "").isEmpty)
    }

    @Test func removalUsesOnlyTheFixtureTrashAndReportsItsPath() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        try MetaFile.update(folder) { $0["transcript"] = ["status": "done", "missing_passages": 0] }
        try Data("fixture audio".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        let realTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let before = (try? FileManager.default.contentsOfDirectory(atPath: realTrash.path)) ?? []
        let reply = try f.run(["remove-audio", RecordingLibrary.stamp(of: folder)])
        #expect(reply.status == 0, "\(reply.err)")
        let location = reply.object["trash"] as? String ?? ""
        #expect(location.hasPrefix(f.files.root.appendingPathComponent("FixtureTrash").path + "/"))
        #expect(FileManager.default.fileExists(atPath: location))
        let after = (try? FileManager.default.contentsOfDirectory(atPath: realTrash.path)) ?? []
        #expect(Set(after).subtracting(before).isEmpty)
    }

    @Test func provenanceDoesNotAttributeAnAgentsChoiceToTheUser() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording(names: [1: "Mei"])
        let reply = try f.run(["voices", RecordingLibrary.stamp(of: folder)], json: false)
        #expect(!reply.out.contains("named by the user"))
        #expect(reply.out.contains("(named)"))
    }
}
