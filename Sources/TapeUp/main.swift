import AppKit

// TapeUp runs as a menu-bar app. Two commands remain for scripted testing:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
//   TapeUp snapshot [--out <dir>]   renders every panel state to PNGs for design review
//   TapeUp uitest [--out <dir>] [--record]   drives the real panel through every flow and checks it
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
case "record":
    guard let out = Launcher.value(after: "--out", in: arguments) else {
        Launcher.fail("usage: TapeUp record --out <dir> [--seconds N]", code: 2)
    }
    Launcher.record(out: out, arguments: arguments)
    app.run()
default:
    // Help text shows a fifth of a second after the pointer arrives instead of
    // macOS's slower default, so icon buttons explain themselves at once.
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 200])
    // The application holds its delegate weakly.
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
