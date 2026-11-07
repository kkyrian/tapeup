import AppKit
import TapeUpCore

// TapeUp runs as a menu-bar app. `TapeUp help` lists the commands for agents
// (folder, title, transcribe, speakers; see CLI.swift). For testing only:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
//   TapeUp snapshot [--out <dir>]   renders every panel state to PNGs for design review
//   TapeUp uitest [--out <dir>] [--record] [--agent claude|codex]   drives the real panel through
//     every flow and checks it; --agent also calls that agent for real
//   TapeUp time-transcribe <recording folder> [--model large|small] [--live]   timed run; --live
//     feeds it in quarter seconds, as while recording
//   TapeUp time-speakers <recording folder> --turns <out.json> [--voices N]   timed run, writing
//     folded turns for scoring
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
            record: arguments.contains("--record"),
            agent: Launcher.value(after: "--agent", in: arguments).flatMap(AgentKind.init))
    }
case "permissions":
    Launcher.reportPermissions(to: Launcher.value(after: "--out", in: arguments))
case "time-transcribe":
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp time-transcribe <recording folder> [--model large|small] [--live]", code: 2)
    }
    Launcher.transcribe(
        folder: URL(fileURLWithPath: arguments[2]),
        model: Launcher.value(after: "--model", in: arguments).flatMap(SpeechModel.init(rawValue:)),
        live: arguments.contains("--live"))
    app.run()
case "time-speakers":
    guard arguments.count > 2 else {
        Launcher.fail("usage: TapeUp time-speakers <recording folder> --turns <out.json> [--voices N]", code: 2)
    }
    Launcher.speakers(
        folder: URL(fileURLWithPath: arguments[2]),
        count: Launcher.value(after: "--voices", in: arguments).flatMap(Int.init),
        turns: Launcher.value(after: "--turns", in: arguments))
    app.run()
// Any other word, or a `--` flag first, is a command line, never a second
// app. macOS itself may pass `-NS…` or `-psn_…` to the app.
case _ where CLI.commands.contains(command) || command.hasPrefix("--") || !(command.isEmpty || command.hasPrefix("-")):
    MainActor.assumeIsolated { CLI.run(arguments) }
case "record":
    guard let out = Launcher.value(after: "--out", in: arguments) else {
        Launcher.fail("usage: TapeUp record --out <dir> [--seconds N]", code: 2)
    }
    Launcher.record(out: out, arguments: arguments)
    app.run()
default:
    // One app per Mac: a second would answer commands and transcribe the same folders.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { exit(0) }
    // The application holds its delegate weakly.
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
