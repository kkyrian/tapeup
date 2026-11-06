import AppKit

// Prototype entry point:
//   TapeUp record --out <dir> [--seconds N]
//   TapeUp permissions [--out <file>]
// Recording stops on SIGTERM or SIGINT, or after N seconds, then prints the result as JSON.

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""

if command == "permissions" {
    Launcher.reportPermissions(to: Launcher.value(after: "--out", in: arguments))
}
guard command == "record", let out = Launcher.value(after: "--out", in: arguments) else {
    Launcher.fail("usage: TapeUp record --out <dir> [--seconds N]", code: 2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Launcher.record(out: out, arguments: arguments)
app.run()
