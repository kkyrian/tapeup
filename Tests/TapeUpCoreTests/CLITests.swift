import AVFoundation
import Foundation
import Testing

@testable import TapeUpCore

/// Runs the real command parser and alone path against an isolated settings
/// domain and recordings root, just as UITest does for the app route.
struct CLIFixture {
    let files: VoiceFixture
    let domain: String

    init() throws {
        files = try VoiceFixture()
        // A path-backed defaults domain stays wholly inside the fixture and
        // works without asking the preferences daemon to persist test settings.
        domain = "/tmp/TapeUp-cli-settings-\(UUID())"
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["recordingsRoot": files.root.path], format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: domain + ".plist"))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: domain + ".plist")
        files.remove()
    }

    func start(_ words: [String], json: Bool = true) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        let binary = ProcessInfo.processInfo.environment["TAPEUP_CLI_BINARY"] ?? ".build/debug/TapeUp"
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = words + (json ? ["--json"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["TAPEUP_STAGED_SETTINGS"] = domain
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        return (process, out, err)
    }

    struct Reply {
        let status: Int32
        let out: String
        let err: String
        var object: [String: Any] {
            (try? JSONSerialization.jsonObject(
                with: Data((status == 0 ? out : String(err.split(separator: "\n").last ?? "")).utf8))) as? [String: Any]
                ?? [:]
        }
        var rows: [[String: Any]] {
            object["voices"] as? [[String: Any]] ?? []
        }
    }

    func finish(_ running: (Process, Pipe, Pipe)) -> Reply {
        let (process, out, err) = running
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return Reply(
            status: process.terminationStatus,
            out: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            err: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func run(_ words: [String], json: Bool = true) throws -> Reply { finish(try start(words, json: json)) }

    func tone() throws -> URL {
        let url = files.root.appendingPathComponent("Mei.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = 0.2 * sin(Float(index) * 0.1) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

struct CLITests {
    @Test func importEnsuresExistingStagesAndCanResumeAfterAFailure() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let source = try f.tone()
        let candidate = try await RecordingImport.inspect(source)
        let folder = try f.files.recording(names: [1: "Mei"])
        try MetaFile.update(folder) { $0["imported"] = ["fingerprint": candidate.fingerprint] }
        let original = try Data(contentsOf: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let first = try f.start(["import", source.path, "--title", "Another title"])
        let second = try f.start(["import", source.path])
        for reply in [f.finish(first), f.finish(second)] {
            #expect(reply.status == 0 && reply.object["imported"] as? Bool == false, "\(reply.err)")
            #expect(reply.object["next"] as? String == "TapeUp voices \(RecordingLibrary.stamp(of: folder))")
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(SpeakerLabels.resultFileName)) == original)
        // Missing labels resume from the saved voice prints without a speech model.
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let held = try #require(FolderLock(folder: folder))
        let failed = try f.run(["import", source.path])
        held.release()
        #expect(failed.status == 1 && failed.object["error"] as? String == "busy")
        #expect(failed.object["stamp"] as? String == RecordingLibrary.stamp(of: folder))
        #expect(failed.object["suggestion"] as? String == "Run the same import again: TapeUp import \"\(source.path)\"")
        let retry = try f.run(["import", source.path])
        #expect(retry.status == 0 && retry.object["imported"] as? Bool == false, "\(retry.err)")
        #expect(SpeakerLabels.result(in: folder) != nil)
        #expect(RecordingLibrary(root: f.files.root).recordingFolders().count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func failedTranscriptWithOlderLabelsIsNotACompleteImport() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let source = try f.tone()
        let candidate = try await RecordingImport.inspect(source)
        let folder = try f.files.recording(names: [1: "Mei"])
        try MetaFile.update(folder) { $0["imported"] = ["fingerprint": candidate.fingerprint] }
        try TranscriptDocument.save(lines: [], failures: 1, pieces: 1, model: .large, in: folder)
        #expect(RecordingLibrary.entry(at: folder)?.transcript == .failed)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        let held = try #require(FolderLock(folder: folder))
        defer { held.release() }
        let reply = try f.run(["import", source.path])
        #expect(reply.status == 1 && reply.object["error"] as? String == "busy")
        #expect(reply.object["stamp"] as? String == RecordingLibrary.stamp(of: folder))
        #expect(reply.object["suggestion"] as? String == "Run the same import again: TapeUp import \"\(source.path)\"")
    }

    @Test func importRejectsUnreadableAndUnsupportedFiles() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let missing = try f.run(["import", f.files.root.appendingPathComponent("missing.wav").path])
        #expect(missing.status == 1 && missing.object["error"] as? String == "unreadable")
        #expect(missing.object["retryable"] as? Bool == false)
        let bad = f.files.root.appendingPathComponent("unsupported.txt")
        try Data("not audio".utf8).write(to: bad)
        #expect(try f.run(["import", bad.path]).object["error"] as? String == "unreadable")
    }

    @Test func voicesAndNamingConfirmCorrectAndClearWithoutChangingPastFills() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try f.files.seed("Mei")
        let earlier = try f.files.recording(
            "2026-01-01-1200", names: [1: "Mei"], provenance: [1: .init(origin: .filled)])
        let folder = try f.files.recording(names: [1: "Mei"], provenance: [1: .init(origin: .filled)])
        let stamp = RecordingLibrary.stamp(of: folder)
        let voices = try f.run(["voices", stamp])
        #expect(voices.status == 0 && voices.rows.count == 1, "\(voices.err)")
        #expect(voices.rows.first?["voice"] as? Int == 1)
        #expect(voices.rows.first?["provenance"] as? String == "filled")
        #expect(voices.rows.first?["seconds"] as? Double == 100)
        #expect(voices.rows.first?["quote"] as? String == "A quoted line from voice 1.")
        let named = try f.run(["voices", "name", stamp, "mei", "Ana"])
        #expect(named.status == 0)
        let hits = named.object["past_fills"] as? [[String: Any]]
        #expect(hits?.count == 1)
        #expect(hits?.first?["stamp"] as? String == "2026-01-01-1200")
        #expect(hits?.first?["voice"] as? Int == 1)
        #expect(hits?.first?["command"] as? String == "TapeUp voices name 2026-01-01-1200 1 \"Ana\"")
        #expect(
            named.object["suggestion"] as? String == "Ask the user first before changing any earlier fill.")
        #expect(SpeakerLabels.result(in: earlier)?.names[1] == "Mei")
        #expect(VoiceStore.load(from: f.files.root).people["Mei"]?.negatives.count == 1)
        #expect(try f.run(["voices", "name", stamp, "1", ""]).status == 0)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == nil)
        #expect(try f.run(["voices", stamp]).rows.first?["name"] is NSNull)
        #expect(try f.run(["voices", "name", "2026-01-01-1200", "1", "Mei"]).status == 0)
        #expect(SpeakerLabels.result(in: earlier)?.provenance(for: 1).origin == .confirmed)
        #expect(try f.run(["voices", "name", stamp, "99", "Ana"]).object["error"] as? String == "not_found")
        try FileManager.default.removeItem(at: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let absent = try f.run(["voices", stamp])
        #expect(absent.object["error"] as? String == "no_speakers")
        #expect(absent.object["suggestion"] as? String == "TapeUp speakers \(stamp)")
    }

    @Test func peopleAddUpdatesContextRenameMergesAndRemovalForgetsOnlyTheVoice() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try PeopleList(you: "Sam").save(to: f.files.root)
        #expect(try f.run(["people", "add", "Mei", "--context", "lab mate"]).status == 0)
        #expect(try f.run(["people", "add", "mei", "--context", "advisor"]).status == 0)
        #expect(try f.run(["people", "add", "MEI"]).status == 0)
        #expect(PeopleList.load(from: f.files.root).people == [.init(name: "Mei", context: "advisor")])
        let list = try f.run(["people"])
        let rows = list.object["people"] as? [[String: Any]]
        #expect(rows?.first?["name"] as? String == "Sam")
        #expect(rows?.first?["you"] as? Bool == true)
        #expect(rows?.last?["context"] as? String == "advisor")
        let folder = try f.files.recording(names: [1: "Mei"], attendees: ["Mei"])
        try f.files.seed("Mei")
        #expect(try f.run(["people", "add", "Ana"]).status == 0)
        let taken = try f.run(["people", "rename", "Mei", "ana"])
        #expect(taken.object["error"] as? String == "name_taken")
        #expect(
            taken.object["suggestion"] as? String
                == "Ask the user whether they are the same person before adding --merge.")
        let rename = try f.run(["people", "rename", "mei", "ana", "--merge"])
        #expect(rename.status == 0 && rename.object["recordings_changed"] as? Int == 1)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
        #expect(VoiceStore.load(from: f.files.root).people["Ana"] != nil)
        #expect(try f.run(["people", "remove", "ANA"]).status == 0)
        #expect(try f.run(["people", "remove", "Ana"]).status == 0)
        #expect(VoiceStore.load(from: f.files.root).people["Ana"] == nil)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
    }

    @Test func keepAndRemoveAudioAreIdempotentAndRespectRefusals() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let stamp = RecordingLibrary.stamp(of: folder)
        try Data("audio fixture".utf8).write(to: folder.appendingPathComponent("audio.m4a"))
        for _ in 0..<2 { #expect(try f.run(["keep", stamp]).object["keep_audio"] as? Bool == true) }
        #expect(try f.run(["remove-audio", stamp]).object["error"] as? String == "kept")
        for _ in 0..<2 { #expect(try f.run(["keep", stamp, "off"]).object["keep_audio"] as? Bool == false) }
        try RecordingLibrary.markTranscript("transcribing", in: folder)
        #expect(try f.run(["remove-audio", stamp]).object["error"] as? String == "busy")
        try MetaFile.update(folder) {
            $0["transcript"] = nil
            $0["status"] = "recorded"
        }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(TranscriptDocument.fileName))
        #expect(try f.run(["remove-audio", stamp]).object["error"] as? String == "no_transcript")
        try Data("transcript".utf8).write(to: folder.appendingPathComponent(TranscriptDocument.fileName))
        try RecordingLibrary.markTranscript("done", in: folder)
        try SpeakerLabels.mark("finding", in: folder)
        #expect(try f.run(["remove-audio", stamp]).object["error"] as? String == "busy")
        try SpeakerLabels.mark("done", in: folder)
        let first = try f.run(["remove-audio", stamp])
        #expect(first.status == 0 && first.object["removed"] as? Bool == true, "\(first.err)")
        let again = try f.run(["remove-audio", stamp])
        #expect(again.status == 0 && again.object["removed"] as? Bool == false)
        #expect(try f.run(["remove-audio", stamp], json: false).out.contains("already has no audio"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(TranscriptDocument.fileName).path))
        try MetaFile.update(folder) { $0["status"] = "recording" }
        #expect(try f.run(["voices", "name", stamp, "1", "Mei"]).object["error"] as? String == "recording")
    }

    @Test func aPartialRenameCanBeRetriedWithoutMerging() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        try f.files.seed("Mei")
        let folder = try f.files.recording(names: [1: "Mei"], attendees: ["Mei"])
        let stamp = RecordingLibrary.stamp(of: folder)
        let held = try #require(FolderLock(folder: folder))
        let first = try f.run(["people", "rename", "mei", "Ana"])
        #expect(first.status == 0 && first.object["recordings_changed"] as? Int == 0)
        #expect(first.object["skipped"] as? [String] == [stamp])
        #expect(PeopleList.load(from: f.files.root).contains("Ana"))
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
        held.release()
        let retry = try f.run(["people", "rename", "mei", "Ana"])
        #expect(retry.status == 0 && retry.object["recordings_changed"] as? Int == 1)
        #expect(retry.object["still_to_catch_up"] as? [String] == [])
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Ana")
    }

    @Test func audioWorkCannotStartWhileAnotherCommandHoldsTheFolder() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let held = try #require(FolderLock(folder: folder))
        defer { held.release() }
        let stamp = RecordingLibrary.stamp(of: folder)
        for command in ["transcribe", "keep", "voices"] {
            let words = command == "voices" ? [command, "name", stamp, "1", "Mei"] : [command, stamp]
            let reply = try f.run(words)
            #expect(reply.status == 1 && reply.object["error"] as? String == "busy")
            #expect(reply.object["retryable"] as? Bool == true)
        }
        #expect(RecordingLibrary.entry(at: folder)?.transcript == .done)
    }

    @Test func concurrentPeopleAndMetadataEditsKeepBothChanges() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let names = ["Priya Shah", "Mei", "José Ortiz", "Ana", "Sam", "Nora Quinn"]
        let adds = try names.map { try f.start(["people", "add", $0]) }
        for process in adds { #expect(f.finish(process).status == 0) }
        #expect(Set(PeopleList.load(from: f.files.root).allNames) == Set(names))
        let folder = try f.files.recording()
        let stamp = RecordingLibrary.stamp(of: folder)
        let title = try f.start(["title", stamp, "Lab sync"])
        let keep = try f.start(["keep", stamp])
        #expect(f.finish(title).status == 0)
        #expect(f.finish(keep).status == 0)
        let renamed = try #require(RecordingLibrary(root: f.files.root).folder(withStamp: stamp))
        let entry = try #require(RecordingLibrary.entry(at: renamed))
        #expect(entry.title == "Lab sync" && entry.keepAudio)
    }

    @Test func alreadyMissingAudioSucceedsEvenWithoutATranscriptOrWithAKeepLock() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording()
        let stamp = RecordingLibrary.stamp(of: folder)
        try RecordingLibrary.save(keepAudio: true, in: folder)
        try RecordingLibrary.markTranscript("waiting", in: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(TranscriptDocument.fileName))
        for _ in 0..<2 {
            let reply = try f.run(["remove-audio", stamp])
            #expect(reply.status == 0 && reply.object["removed"] as? Bool == false)
        }
        #expect(try f.run(["remove-audio", stamp], json: false).out.contains("already has no audio"))
        #expect(try f.run(["keep", stamp]).status == 0)
        #expect(try f.run(["keep", stamp, "off"]).status == 0)
    }

    @Test func speakersEnsurePreservesNamedBytesAndRecountsOnlyWhenRequested() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let folder = try f.files.recording(
            prints: [1: voicePrint(), 2: voicePrint(0, 1)], names: [1: "Mei", 2: "Ana"])
        let stamp = RecordingLibrary.stamp(of: folder)
        let original = try Data(contentsOf: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        let before = try f.files.bytes()
        for words in [["speakers", stamp], ["speakers", stamp, "--voices", "2"]] {
            let reply = try f.run(words)
            #expect(reply.status == 0 && reply.object["labeled"] as? Bool == false)
            #expect(reply.object["next"] as? String == "TapeUp voices \(stamp)")
        }
        #expect(try f.files.bytes() == before)
        let changed = try f.run(["speakers", stamp, "--voices", "1"])
        #expect(changed.status == 0 && changed.object["labeled"] as? Bool == true, "\(changed.err)")
        #expect(SpeakerLabels.result(in: folder)?.voices.count == 1)
        // Neither name owns a strict majority after an equal two-way merge.
        #expect(SpeakerLabels.result(in: folder)?.names.isEmpty == true)
        let lines = [
            TranscriptLine(start: 0, end: 100, text: "Mei speaks longer."),
            TranscriptLine(start: 100, end: 140, text: "Ana replies."),
        ]
        try JSONEncoder().encode(lines).write(to: folder.appendingPathComponent(TranscriptDocument.linesFileName))
        try original.write(to: folder.appendingPathComponent(SpeakerLabels.resultFileName))
        #expect(try f.run(["speakers", stamp, "--voices", "1"]).object["labeled"] as? Bool == true)
        #expect(SpeakerLabels.result(in: folder)?.names[1] == "Mei")
    }

    @Test func latestExcludesActiveRecordingsAndNextCommandsAreCopyable() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let saved = try f.files.recording("2026-01-02-1200")
        let active = try f.files.recording("2026-01-03-1200")
        try MetaFile.update(active) {
            $0["status"] = "recording"
            $0["started"] = "2026-01-03T12:00:00Z"
        }
        let voices = try f.run(["voices", "latest"])
        #expect(voices.status == 0)
        #expect(voices.object["next"] as? String == "TapeUp voices name 2026-01-02-1200 1 \"<person>\"")
        let plain = try f.run(["voices", "latest"], json: false)
        #expect(plain.out.hasSuffix("Next: TapeUp voices name 2026-01-02-1200 1 \"<person>\"\n"))
        #expect(try f.run(["voices", "name", "latest", "1", "Mei"]).status == 0)
        #expect(SpeakerLabels.result(in: saved)?.names[1] == "Mei")
        #expect(SpeakerLabels.result(in: active)?.names.isEmpty == true)
        let renamed = try f.run(["people", "rename", "Mei", "Nora Quinn"])
        #expect(renamed.object["undo"] as? String == "TapeUp people rename \"Nora Quinn\" \"Mei\"")
        #expect(renamed.object["next"] as? String == "TapeUp people")
        let removed = try f.run(["people", "remove", "Nora Quinn"], json: false)
        #expect(removed.out.contains("cannot be undone from the command line"))
        #expect(removed.out.hasSuffix("Next: TapeUp people\n"))
    }

    @Test func malformedCommandsAreUsageErrorsAndMissingRecordingsAreNotFound() throws {
        let f = try CLIFixture()
        defer { f.remove() }
        for words in [
            ["import"], ["import", "x", "--title"], ["voices"], ["voices", "name", "x", "1"],
            ["name", "x", "1", "Mei"],
            ["people", "add", ""], ["people", "rename", "Ana"], ["people", "add", "Ana", "--merge"],
            ["people", "--context", "x"], ["remove-audio"], ["keep", "x", "yes"], ["voices", "x", "--bad"],
        ] {
            let reply = try f.run(words)
            #expect(
                reply.status == 2 && reply.out.isEmpty && reply.object["error"] as? String == "usage",
                "\(words): \(reply.err)")
        }
        for command in ["voices", "remove-audio", "keep"] {
            let reply = try f.run([command, "1999-01-01-0000"])
            #expect(reply.status == 1 && reply.object["error"] as? String == "not_found")
            #expect(reply.object["retryable"] as? Bool == false)
        }
    }
}
