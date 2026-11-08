import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Recordings made elsewhere, copied in as ordinary TapeUp recordings. The
/// original file is only read, never moved or changed. The copy's audio is
/// re-encoded as the recorder writes it (48 kHz stereo AAC) so transcripts
/// and speaker labels work the same; the same sound is in both channels,
/// so an imported recording has no sides.
public enum RecordingImport {
    /// What can be imported: any audio, and the sound of any movie.
    public static let contentTypes: [UTType] = [.audio, .movie]

    /// A file looked at before importing.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let name: String
        /// When it was recorded: the file's own creation date, else the
        /// file system's, else when it was last changed.
        public let started: Date
        public let duration: Double
        public let bytes: Int64
        /// The file's SHA-256, so the same file is never imported twice.
        public let fingerprint: String
        public let isMovie: Bool
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noSound
        case unreadable

        public var description: String {
            switch self {
            case .noSound: "No sound in this file"
            case .unreadable: "Can't read this file"
            }
        }
    }

    /// The files to look at: each file given, and every audio or movie file
    /// inside a folder given, in name order. Hidden files are skipped.
    public static func files(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isFolder {
                found.append(url)
                continue
            }
            let walker = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var inside: [URL] = []
            while let next = walker?.nextObject() as? URL {
                guard let values = try? next.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
                    values.isRegularFile == true, let type = values.contentType,
                    contentTypes.contains(where: { type.conforms(to: $0) })
                else { continue }
                inside.append(next)
            }
            found += inside.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return found
    }

    /// Reads what the list shows about a file, and its fingerprint.
    public static func inspect(_ url: URL) async throws -> Candidate {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw Failure.unreadable
        }
        guard !tracks.isEmpty else { throw Failure.noSound }
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
        var started = values?.creationDate ?? values?.contentModificationDate ?? Date()
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            started = date
        }
        let fingerprint = try await Task.detached(priority: .utility) { try Self.fingerprint(of: url) }.value
        return Candidate(
            url: url, name: url.lastPathComponent, started: started,
            duration: duration.isNumeric ? duration.seconds : 0, bytes: Int64(values?.fileSize ?? 0),
            fingerprint: fingerprint, isMovie: !video.isEmpty)
    }

    static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprints of everything already imported into this library.
    public static func imported(in library: RecordingLibrary) -> Set<String> {
        Set(
            library.recordingFolders().compactMap { folder in
                (MetaFile.read(folder)?["imported"] as? [String: Any])?["fingerprint"] as? String
            })
    }

    /// What to do with a file once it is in.
    public struct Plan: Sendable, Equatable {
        /// Mark the transcript waiting.
        public var transcribe: Bool
        /// Label speakers once the transcript is done; kept in `meta.json`
        /// so a quit before then does not lose it.
        public var labelSpeakers: Bool
        /// Saved as who was there: the voice count, when one was picked.
        public var people: RecordingEntry.People

        public init(
            transcribe: Bool, labelSpeakers: Bool = false, people: RecordingEntry.People = .init()
        ) {
            self.transcribe = transcribe
            self.labelSpeakers = labelSpeakers && transcribe
            self.people = people
        }
    }

    public static func isImported(_ folder: URL) -> Bool { MetaFile.read(folder)?["imported"] != nil }

    /// Whether an imported recording asked for speaker labels.
    public static func wantsSpeakerLabels(_ folder: URL) -> Bool {
        (MetaFile.read(folder)?["imported"] as? [String: Any])?["label_speakers"] as? Bool == true
    }

    /// Copies one file in as a recording and returns its folder.
    /// `progress` runs on a background queue, from 0 to 1 as the sound is copied.
    public static func copy(
        _ candidate: Candidate, into library: RecordingLibrary, plan: Plan,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let folder = try library.newFolder(at: candidate.started)
        do {
            let audio = folder.appendingPathComponent("audio.m4a")
            try await encode(candidate.url, to: audio, duration: candidate.duration, progress: progress)
            let meta: [String: Any] = [
                "format": "tapeup-recording/0", "channels": ["left": "imported", "right": "imported"],
                "status": "recorded", "audio": "audio.m4a", "duration_seconds": candidate.duration.rounded(),
                "started": ISO8601DateFormatter().string(from: candidate.started), "sources": [String](),
                "imported": [
                    "file": candidate.name, "fingerprint": candidate.fingerprint,
                    "at": ISO8601DateFormatter().string(from: Date()), "label_speakers": plan.labelSpeakers,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: MetaFile.url(in: folder), options: .atomic)
            if !plan.people.isEmpty { try RecordingLibrary.save(people: plan.people, in: folder) }
            if plan.transcribe { try RecordingLibrary.markTranscript("waiting", in: folder) }
            let name = (candidate.name as NSString).deletingPathExtension
            // The file's own name is the title; the folder's date and time
            // keep two of the same name apart.
            if !name.isEmpty {
                return try RecordingLibrary.save(title: name, in: folder)
            }
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// The file's sound as 48 kHz stereo AAC, every track mixed; a mono file
    /// fills both channels.
    static func encode(
        _ source: URL, to destination: URL, duration: Double = 0,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure.noSound }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        guard reader.canAdd(output) else { throw Failure.unreadable }
        reader.add(output)
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.unreadable }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? Failure.unreadable
        }
        writer.startSession(atSourceTime: .zero)
        let pump = Pump(reader: reader, output: output, input: input, duration: duration, progress: progress)
        await pump.run()
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? Failure.unreadable
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure.unreadable }
    }

    /// Moves samples from the reader to the writer as the writer takes them.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        private let queue = DispatchQueue(label: "TapeUp.import")

        let duration: Double
        let progress: @Sendable (Double) -> Void
        private var reported = 0.0

        init(
            reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput, duration: Double,
            progress: @escaping @Sendable (Double) -> Void
        ) {
            self.reader = reader
            self.output = output
            self.input = input
            self.duration = duration
            self.progress = progress
        }

        /// Reports at most every 1%, so the window redraws calmly.
        private func report(_ buffer: CMSampleBuffer) {
            guard duration > 0 else { return }
            let done = min(1, CMSampleBufferGetPresentationTimeStamp(buffer).seconds / duration)
            guard done - reported >= 0.01 else { return }
            reported = done
            progress(done)
        }

        /// Touched only on `queue`.
        private var finished = false

        func run() async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        if let buffer = output.copyNextSampleBuffer(), reader.status == .reading {
                            input.append(buffer)
                            report(buffer)
                        } else {
                            finished = true
                            input.markAsFinished()
                            progress(1)
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }
}
