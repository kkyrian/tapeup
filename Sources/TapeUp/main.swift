import AVFoundation
import AppKit
import Foundation
import TapeUpCore

// Prototype entry point: `TapeUp record --out <dir> [--seconds N] [--system-audio withOutput|tapOnly]`.
// Stops on SIGTERM or SIGINT, or after N seconds, then prints the result as JSON.

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
guard arguments.count > 1, arguments[1] == "record", let out = value(after: "--out", in: arguments) else {
    FileHandle.standardError.write(
        Data("usage: TapeUp record --out <dir> [--seconds N] [--system-audio withOutput|tapOnly]\n".utf8))
    exit(2)
}

let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd-HHmmss"
var options = Recorder.Options(
    folder: URL(fileURLWithPath: out).appendingPathComponent(stamp.string(from: Date())))
if let mode = value(after: "--system-audio", in: arguments) { options.systemAudioMode = mode }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func finish(_ recorder: Recorder) -> Never {
    do {
        let result = try recorder.stop()
        let json = #"{"folder":"\#(result.folder.path)","audio":"\#(result.audio.path)"}"#
        print(json)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("stop failed: \(error)\n".utf8))
        exit(1)
    }
}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        if !granted { FileHandle.standardError.write(Data("microphone access denied\n".utf8)) }
        let recorder: Recorder
        do {
            recorder = try Recorder(options: options)
            try recorder.start()
        } catch {
            FileHandle.standardError.write(Data("start failed: \(error)\n".utf8))
            exit(1)
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { finish(recorder) }
            source.resume()
            signalSources.append(source)
        }
        if let seconds = value(after: "--seconds", in: arguments).flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(recorder) }
        }
    }
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
app.run()
