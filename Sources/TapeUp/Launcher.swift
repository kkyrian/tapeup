import AVFoundation
import Foundation
import TapeUpCore
import TapeUpSpeech

@MainActor
enum Launcher {
    static var recorder: Recorder?
    static var signalSources: [DispatchSourceSignal] = []

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    static func reportPermissions(to path: String?) -> Never {
        let microphone =
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "authorized" : "not authorized"
        let line = "microphone: \(microphone)\nsystem audio: \(AudioCapturePermission.status().rawValue)\n"
        if let path { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        print(line, terminator: "")
        exit(0)
    }

    /// Downloads the model if needed, transcribes one recording, prints how long it took.
    static func transcribe(folder: URL, model: SpeechModel?, live: Bool = false) {
        let model = model ?? SpeechModel.forThisMac()
        let names = NameHints.make(
            names: PeopleList.load(from: folder.deletingLastPathComponent().deletingLastPathComponent()).allNames,
            titles: [])
        Task.detached {
            let began = Date()
            do {
                if !ModelStore.isDownloaded(model) {
                    try await ModelStore.download(model) { bytes in
                        FileHandle.standardError.write(Data("\rdownloading \(bytes / 1_000_000) MB".utf8))
                    }
                }
                let engine = try await SpeechEngine.load(model)
                let loaded = Date()
                if live {
                    try await feedLive(folder: folder, engine: engine, names: names)
                } else {
                    try await FolderTranscriber.run(folder: folder, engine: engine, names: names)
                }
                let seconds = { (date: Date) in (date.timeIntervalSince(began) * 10).rounded() / 10 }
                print(
                    #"{"transcript":"\#(folder.appendingPathComponent(TranscriptDocument.fileName).path)","model":"\#(model.name)","load_seconds":\#(seconds(loaded)),"total_seconds":\#(seconds(Date()))}"#
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// Labels the speakers of one transcribed recording, downloading the
    /// speaker models if needed; `turns` gets the folded turns for scoring.
    static func speakers(folder: URL, count: Int?, turns: String?) {
        Task.detached {
            let began = Date()
            do {
                guard let lines = TranscriptDocument.lines(in: folder) else { throw CocoaError(.fileNoSuchFile) }
                if !SpeakerFinder.isDownloaded() { try await SpeakerFinder.download { _ in } }
                let heard = try await SpeakerFinder.listen(folder: folder)
                let listened = Date()
                try heard.save(in: folder)
                let result = SpeakerLabels.label(lines: lines, heard: heard, count: count)
                try SpeakerLabels.save(result, lines: lines, in: folder)
                if let turns {
                    let person = VoiceFolding.fold(heard, count: count)
                    let segments = heard.turns.map {
                        ["start": $0.start, "end": $0.end, "speaker": Double(person[$0.voice] ?? $0.voice)]
                    }
                    try JSONSerialization.data(withJSONObject: ["segments": segments]).write(
                        to: URL(fileURLWithPath: turns))
                }
                let seconds = { (date: Date) in (date.timeIntervalSince(began) * 10).rounded() / 10 }
                print(
                    #"{"voices":\#(result.voices.count),"estimated":\#(result.estimated),"model_voices":\#(Set(heard.turns.map(\.voice)).count),"listen_seconds":\#(seconds(listened)),"total_seconds":\#(seconds(Date()))}"#
                )
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("speakers failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    /// Feeds a saved recording through the live path, a quarter second at a
    /// time from another thread as the recorder does, to test it on real speech.
    private nonisolated static func feedLive(folder: URL, engine: SpeechEngine, names: String?) async throws {
        let meta = MetaFile.read(folder) ?? [:]
        let headphones = meta["output_headphones"] as? Bool == true
        let session = try await engine.session(
            names: engine.model.takesHints ? names : nil, microphone: true, computer: true)
        let file = try AVAudioFile(forReading: folder.appendingPathComponent("audio.m4a"))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 12_000) else { return }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            session.feed(
                left: Array(UnsafeBufferPointer(start: data[0], count: count)),
                right: Array(UnsafeBufferPointer(start: data[1], count: count)), headphones: headphones)
            // A file reads faster than anyone speaks; stay within what a
            // recording would let pile up.
            while session.behind > 30 { try await Task.sleep(for: .milliseconds(50)) }
        }
        guard !session.overloaded else { throw CocoaError(.featureUnsupported) }
        let outcome = await session.finish()
        try TranscriptDocument.save(
            lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: engine.model, in: folder)
    }

    static func record(out: String, arguments: [String]) {
        requestPermissions {
            DispatchQueue.main.async { MainActor.assumeIsolated { startRecording(out: out, arguments: arguments) } }
        }
    }

    private static func startRecording(out: String, arguments: [String]) {
        let folder: URL
        do {
            folder = try RecordingLibrary(root: URL(fileURLWithPath: out)).newFolder()
        } catch {
            fail("could not create the recording folder: \(error)")
        }
        do {
            let started = try Recorder(options: Recorder.Options(folder: folder))
            try started.start()
            recorder = started
        } catch {
            fail("start failed: \(error)")
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { finish() } }
            source.resume()
            signalSources.append(source)
        }
        if let seconds = value(after: "--seconds", in: arguments).flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { finish() } }
        }
    }

    private static func finish() -> Never {
        guard let recorder else { exit(0) }
        do {
            let result = try recorder.stop()
            print(#"{"folder":"\#(result.folder.path)","audio":"\#(result.audio.path)"}"#)
            exit(0)
        } catch {
            fail("stop failed: \(error)")
        }
    }

    private nonisolated static func requestPermissions(_ then: @escaping @Sendable () -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { FileHandle.standardError.write(Data("microphone access denied\n".utf8)) }
            guard AudioCapturePermission.status() != .authorized else { return then() }
            AudioCapturePermission.request { granted in
                if !granted { FileHandle.standardError.write(Data("system audio access denied\n".utf8)) }
                then()
            }
        }
    }
}
