import AVFoundation
import Foundation
import TapeUpCore

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
