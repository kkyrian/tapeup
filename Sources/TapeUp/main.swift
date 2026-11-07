import AppKit
import TapeUpCore

// TapeUp runs as a menu-bar app. Two commands remain for scripted testing:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
//   TapeUp snapshot [--out <dir>]   renders every panel state to PNGs for design review
//   TapeUp uitest [--out <dir>] [--record]   drives the real panel through every flow and checks it
//   TapeUp transcribe <recording folder> [--model large|small] [--live]   writes its transcript.md;
//     --live feeds it in quarter seconds, as while recording
// `record` stops on SIGTERM or SIGINT, or after N seconds, then prints the result as JSON.

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

switch command {
case "snapshot":
    MainActor.assumeIsolated { Snapshot.run(out: Launcher.value(after: "--out", in: arguments) ?? "tmp/snapshots") }
case "uitest":
    MainActor.assumeIsolated {
        UITest.run(
            out: Launcher.value(after: "--out", in: arguments) ?? "tmp/uitest",
            record: arguments.contains("--record"))
    }
case "permissions":
    Launcher.reportPermissions(to: Launcher.value(after: "--out", in: arguments))
case "transcribe":
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp transcribe <recording folder> [--model large|small]", code: 2)
    }
    Launcher.transcribe(
        folder: URL(fileURLWithPath: arguments[2]),
        model: Launcher.value(after: "--model", in: arguments).flatMap(SpeechModel.init(rawValue:)),
        live: arguments.contains("--live"))
    app.run()
case "speakers":
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp speakers <recording folder> [--voices N] [--turns out.json]", code: 2)
    }
    Launcher.speakers(
        folder: URL(fileURLWithPath: arguments[2]),
        count: Launcher.value(after: "--voices", in: arguments).flatMap(Int.init),
        turns: Launcher.value(after: "--turns", in: arguments))
    app.run()
case "record":
    guard let out = Launcher.value(after: "--out", in: arguments) else {
        Launcher.fail("usage: TapeUp record --out <dir> [--seconds N]", code: 2)
    }
    Launcher.record(out: out, arguments: arguments)
    app.run()
default:
    // The application holds its delegate weakly.
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
