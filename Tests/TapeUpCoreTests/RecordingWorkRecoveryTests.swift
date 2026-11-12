import Foundation
import Testing

@testable import TapeUpCore

struct RecordingWorkRecoveryTests {
    @Test func deadOwnersAreClearedButLiveOwnersAreLeftAlone() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        try RecordingLibrary.markTranscript("transcribing", in: folder)
        #expect((MetaFile.read(folder)?["transcript"] as? [String: Any])?["pid"] as? Int32 == getpid())
        #expect(try RecordingWork.recover(in: folder) == false)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        try MetaFile.update(folder) {
            $0["transcript"] = ["status": "transcribing", "pid": child.processIdentifier]
            $0["speaker_labels"] = ["status": "finding", "pid": child.processIdentifier]
        }
        #expect(try RecordingWork.recover(in: folder))
        for key in ["transcript", "speaker_labels"] {
            #expect((MetaFile.read(folder)?[key] as? [String: Any])?["status"] as? String == "failed")
            #expect((MetaFile.read(folder)?[key] as? [String: Any])?["pid"] == nil)
        }
    }

    @Test func anOlderRunningAppsUnownedMarkerIsNotReclaimed() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        try MetaFile.update(folder) { $0["transcript"] = ["status": "transcribing"] }
        #expect(try RecordingWork.recover(in: folder, appBusy: true) == false)
        #expect(RecordingLibrary.entry(at: folder)?.transcript == .pending)
        #expect(try RecordingWork.recover(in: folder) == true)
        #expect(RecordingLibrary.entry(at: folder)?.transcript == .failed)
    }

    @Test func appStartupReclaimsInterruptedPendingTranscripts() throws {
        let f = try VoiceFixture()
        defer { f.remove() }
        let folder = try f.recording()
        try MetaFile.update(folder) { $0["transcript"] = ["status": "transcribing", "pid": Int32.max] }
        #expect(try RecordingWork.recover(in: folder, resumeTranscripts: true))
        #expect(RecordingLibrary.entry(at: folder)?.transcript == .pending)
        #expect((MetaFile.read(folder)?["transcript"] as? [String: Any])?["pid"] as? Int32 == getpid())
    }

    @Test func theNextImportRemovesAHalfMadeFolderFromADeadProcess() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let source = try f.tone()
        let candidate = try await RecordingImport.inspect(source)
        let library = RecordingLibrary(root: f.files.root)
        let half = try library.newFolder(at: candidate.started)
        let stamp = RecordingLibrary.stamp(of: half)
        try MetaFile.update(half) {
            $0 = [
                "status": "importing", "started": ISO8601DateFormatter().string(from: candidate.started),
                "imported": ["fingerprint": candidate.fingerprint, "pid": Int32.max],
            ]
        }
        try Data("partial audio".utf8).write(to: half.appendingPathComponent("audio.m4a"))
        #expect(RecordingLibrary.entry(at: half) == nil)
        #expect(library.recording("latest") == nil)
        let copy = try await RecordingImport.copyOnce(candidate, into: library, plan: .init(transcribe: false))
        #expect(copy.imported)
        #expect(RecordingLibrary.stamp(of: copy.folder) == stamp)
        #expect(RecordingLibrary.entry(at: copy.folder)?.status == "recorded")
        #expect(library.recordingFolders().count == 1)
        #expect((try Data(contentsOf: copy.folder.appendingPathComponent("audio.m4a"))).count > 100)
    }

    @Test func aLiveImportIsNotRemovedOrCopiedTwice() async throws {
        let f = try CLIFixture()
        defer { f.remove() }
        let source = try f.tone()
        let candidate = try await RecordingImport.inspect(source)
        let library = RecordingLibrary(root: f.files.root)
        let half = try library.newFolder(at: candidate.started)
        try MetaFile.update(half) {
            $0 = [
                "status": "importing", "started": ISO8601DateFormatter().string(from: candidate.started),
                "imported": ["fingerprint": candidate.fingerprint, "pid": getpid()],
            ]
        }
        await #expect(throws: RecordingImport.Failure.inProgress(RecordingLibrary.stamp(of: half))) {
            try await RecordingImport.copyOnce(candidate, into: library, plan: .init(transcribe: false))
        }
        #expect(library.recordingFolders().count == 1)
    }
}
