import AppKit
import TapeUpCore

// TapeUp runs as a menu-bar app. `TapeUp help` lists the commands for agents
// (folder, title, transcribe, speakers; see CLI.swift). For testing only:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
//   TapeUp snapshot [--out <dir>]   renders every panel state to PNGs for design review
//   TapeUp uitest [--out <dir>] [--record]   drives the real panel through every flow and checks it
//   TapeUp transcribe <recording folder> --model large|small [--live]   timed run; --live feeds it
//     in quarter seconds, as while recording
//   TapeUp speakers <recording folder> --turns <out.json>   timed run, writing folded turns for scoring
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
case "transcribe" where arguments.contains("--model") || arguments.contains("--live"):
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp transcribe <recording folder> --model large|small [--live]", code: 2)
    }
    Launcher.transcribe(
        folder: URL(fileURLWithPath: arguments[2]),
        model: Launcher.value(after: "--model", in: arguments).flatMap(SpeechModel.init(rawValue:)),
        live: arguments.contains("--live"))
    app.run()
case "speakers" where arguments.contains("--turns"):
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp speakers <recording folder> --turns <out.json> [--voices N]", code: 2)
    }
    Launcher.speakers(
        folder: URL(fileURLWithPath: arguments[2]),
        count: Launcher.value(after: "--voices", in: arguments).flatMap(Int.init),
        turns: Launcher.value(after: "--turns", in: arguments))
    app.run()
case _ where CLI.commands.contains(command):
    MainActor.assumeIsolated { CLI.run(arguments) }
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
