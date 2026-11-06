import AppKit

// TapeUp runs as a menu-bar app. Two commands remain for scripted testing:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
//   TapeUp snapshot [--out <dir>]   renders every panel state to PNGs for design review
// `record` stops on SIGTERM or SIGINT, or after N seconds, then prints the result as JSON.

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

switch command {
case "snapshot":
    MainActor.assumeIsolated { Snapshot.run(out: Launcher.value(after: "--out", in: arguments) ?? "tmp/snapshots") }
case "permissions":
    Launcher.reportPermissions(to: Launcher.value(after: "--out", in: arguments))
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
