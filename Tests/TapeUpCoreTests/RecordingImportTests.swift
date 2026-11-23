import AVFoundation
import Foundation
import Testing

@testable import TapeUpCore

struct RecordingImportTests {
    private let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "tapeup-import-\(UUID().uuidString)")

    /// A mono tone at 44.1 kHz, as a phone or another recorder might save.
    private func tone(_ name: String, seconds: Double = 2, rate: Double = 44_100) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = 0.3 * sin(Float(index) * 2 * .pi * 440 / Float(rate)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func energy(_ url: URL) throws -> (rate: Double, channels: Int, left: Float, right: Float) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let data = try #require(buffer.floatChannelData)
        func sum(_ channel: Int) -> Float { (0..<count).reduce(0) { $0 + abs(data[channel][$1]) } / Float(count) }
        return (format.sampleRate, Int(format.channelCount), sum(0), format.channelCount > 1 ? sum(1) : 0)
    }

    @Test func monoFileBecomesARecordingWithItsSoundInBothChannels() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try tone("Team call.wav")
        let before = try RecordingImport.fingerprint(of: source)
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        let candidate = try await RecordingImport.inspect(source)
        #expect(abs(candidate.duration - 2) < 0.05)
        #expect(candidate.bytes > 0)
        #expect(!candidate.isMovie)

        let reported = Reported()
        let folder = try await RecordingImport.copy(candidate, into: library, plan: .init(transcribe: false)) {
            reported.add($0)
        }
        #expect(folder.lastPathComponent.hasSuffix(" Team call"))
        #expect(reported.values.last == 1)
        #expect(reported.values == reported.values.sorted())
        let audio = try energy(folder.appendingPathComponent("audio.m4a"))
        #expect(audio.rate == 48_000)
        #expect(audio.channels == 2)
        #expect(audio.left > 0.1)
        #expect(abs(audio.left - audio.right) < 0.01)

        let entry = try #require(RecordingLibrary.entry(at: folder))
        #expect(entry.title == "Team call")
        #expect(entry.status == "recorded")
        #expect(abs(entry.duration - 2) < 0.6)
        #expect(entry.transcript == .none)
        let meta = try #require(MetaFile.read(folder))
        #expect(meta["sources"] as? [String] == [])
        let imported = try #require(meta["imported"] as? [String: Any])
        #expect(imported["file"] as? String == "Team call.wav")
        #expect(RecordingImport.imported(in: library) == [before])
        // The original is only read.
        #expect(try RecordingImport.fingerprint(of: source) == before)
    }

    /// Different sound in each ear, as 48 kHz stereo AAC.
    private func stereoAAC(_ name: String, seconds: Double = 2) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try #require(buffer.floatChannelData)
        for index in 0..<Int(frames) {
            data[0][index] = 0.4 * sin(Float(index) * 2 * .pi * 440 / 48_000)
            data[1][index] = 0.1 * sin(Float(index) * 2 * .pi * 660 / 48_000)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try #require(buffer.floatChannelData)
        return (0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
    }

    @Test func soundAlreadyInTheRecordersFormatIsCopiedWithoutEncoding() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try stereoAAC("Call.m4a")
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        let candidate = try await RecordingImport.inspect(source)
        let reported = Reported()
        let folder = try await RecordingImport.copy(candidate, into: library, plan: .init(transcribe: false)) {
            reported.add($0)
        }
        #expect(reported.values.last == 1)
        let before = try samples(source)
        let after = try samples(folder.appendingPathComponent("audio.m4a"))
        #expect(abs(before[0].count - after[0].count) <= 2048)
        // A second encoding would change the samples; the same packets don't.
        let shared = min(before[0].count, after[0].count)
        for channel in 0..<2 {
            let difference = (0..<shared).map { abs(before[channel][$0] - after[channel][$0]) }.max() ?? 1
            #expect(difference < 0.0001)
        }
    }

    @Test func inspectingTellsWhichFilesNeedEncoding() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try await RecordingImport.inspect(stereoAAC("Matching.m4a")).needsEncoding == false)
        #expect(try await RecordingImport.inspect(tone("Mono.wav")).needsEncoding == true)
    }

    @Test func encodingReportsProgressBeforeItFinishes() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try tone("Memo.wav", seconds: 3)
        let reported = Reported()
        let destination = base.appendingPathComponent("out.m4a")
        try await RecordingImport.encode(source, to: destination, duration: 3) { reported.add($0) }
        #expect(reported.values.count > 2)
        #expect(reported.values.first ?? 1 < 1)
        #expect(reported.values.last == 1)
        #expect(reported.values == reported.values.sorted())
    }

    @Test func severalFilesCanCopyAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        var candidates: [RecordingImport.Candidate] = []
        for index in 0..<4 {
            candidates.append(
                try await RecordingImport.inspect(tone("Memo \(index).wav", seconds: 1 + Double(index) / 10)))
        }
        let folders = try await withThrowingTaskGroup(of: URL.self) { group in
            for candidate in candidates {
                group.addTask {
                    try await RecordingImport.copy(candidate, into: library, plan: .init(transcribe: false))
                }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        #expect(Set(folders).count == 4)
        #expect(RecordingImport.imported(in: library) == Set(candidates.map(\.fingerprint)))
        for folder in folders { #expect(try energy(folder.appendingPathComponent("audio.m4a")).left > 0.1) }
    }

    @Test func transcribingKeepsTheFileNameAndMarksItWaiting() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        let candidate = try await RecordingImport.inspect(try tone("memo.m4a.wav", seconds: 1))
        let folder = try await RecordingImport.copy(
            candidate, into: library, plan: .init(transcribe: true, labelSpeakers: true, people: .init(count: 3)))
        let entry = try #require(RecordingLibrary.entry(at: folder))
        #expect(entry.title == "memo.m4a")
        #expect(entry.transcript == .pending)
        #expect(entry.people == .init(count: 3))
        #expect(RecordingImport.wantsSpeakerLabels(folder))
    }

    @Test func twoFilesOfTheSameNameAndMinuteGetTheirOwnFolders() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        var folders: [URL] = []
        for (index, path) in ["a/Team call.wav", "b/Team call.wav"].enumerated() {
            let source = try tone(path, seconds: 0.3 + Double(index) * 0.2)
            try FileManager.default.setAttributes(
                [.creationDate: made, .modificationDate: made], ofItemAtPath: source.path)
            let candidate = try await RecordingImport.inspect(source)
            folders.append(try await RecordingImport.copy(candidate, into: library, plan: .init(transcribe: false)))
        }
        let names = folders.map(\.lastPathComponent)
        let stamps = folders.map { RecordingLibrary.stamp(of: $0) }
        #expect(Set(stamps).count == 2)
        #expect(names[1] == stamps[0] + "-2 Team call")
        #expect(folders.map { RecordingLibrary.entry(at: $0)?.title } == ["Team call", "Team call"])
        #expect(library.folder(withStamp: stamps[1]) == folders[1])
    }

    @Test func startsWhenTheFileWasMade() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try tone("old.wav", seconds: 0.5)
        let made = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: made, .modificationDate: made], ofItemAtPath: source.path)
        let candidate = try await RecordingImport.inspect(source)
        #expect(abs(candidate.started.timeIntervalSince(made)) < 1)
        let library = RecordingLibrary(root: base.appendingPathComponent("TapeUp"))
        let folder = try await RecordingImport.copy(candidate, into: library, plan: .init(transcribe: false))
        #expect(folder.deletingLastPathComponent().lastPathComponent == "2023")
    }

    @Test func aFileWithoutSoundIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let text = base.appendingPathComponent("notes.txt")
        try "not audio".write(to: text, atomically: true, encoding: .utf8)
        await #expect(throws: RecordingImport.Failure.self) { try await RecordingImport.inspect(text) }
    }

    @Test func foldersExpandToTheirAudioInNameOrder() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Old calls")
        let ten = try tone("Old calls/Call 10.wav", seconds: 0.1)
        let two = try tone("Old calls/sub/Call 2.wav", seconds: 0.1)
        try "x".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        _ = try tone("Old calls/.hidden.wav", seconds: 0.1)
        let loose = try tone("loose.wav", seconds: 0.1)
        let found = RecordingImport.files(in: [loose, folder]).map(\.lastPathComponent)
        #expect(found == [loose.lastPathComponent, ten.lastPathComponent, two.lastPathComponent])
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func add(_ value: Double) { lock.withLock { list.append(value) } }
    var values: [Double] { lock.withLock { list } }
}
