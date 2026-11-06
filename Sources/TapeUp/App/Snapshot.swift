import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp snapshot --out <dir>`: renders every panel state, light and dark,
/// with sample recordings, so the design can be judged from images.
@MainActor
enum Snapshot {
    static func run(out: String) -> Never {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty")
        let full = root.appendingPathComponent("full")
        seed(full)

        let model = AppModel()
        let devices = (microphone: "AirPods Pro", output: "MacBook Pro Speakers")
        let wave: ([Float], [Float]) = (
            (0..<AppModel.laneLength).map { i in i > 30 ? Float.random(in: 0.3...0.85) : (i % 7 < 3 ? 0.5 : 0.05) },
            (0..<AppModel.laneLength).map { _ in Float.random(in: 0.35...0.9) }
        )

        func shoot(_ name: String, prepare: () -> Void) {
            prepare()
            for dark in [false, true] {
                render(
                    model: model, dark: dark,
                    to: outURL.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        model.root = empty
        shoot("01-first-run") {
            model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
        }
        model.root = full
        shoot("02-idle") { model.stage(phase: .idle, microphone: devices.microphone, output: devices.output) }
        shoot("03-recording") {
            model.stage(
                phase: .recording(started: Date()), elapsed: 2526, microphone: devices.microphone,
                output: devices.output, levels: wave)
        }
        let latest = model.recent[0]
        shoot("04-saving") {
            model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
            model.card = .init(entry: latest, finishing: true, justRecorded: true)
        }
        shoot("05-saved") { model.card = .init(entry: latest, finishing: false, justRecorded: true) }
        shoot("06-saved-copied") {
            model.card = .init(entry: latest, finishing: false, copied: true, justRecorded: true)
        }
        shoot("07-saved-people") {
            var entry = latest
            entry.people = .init(count: 4, names: ["Priya Shah", "Mei"])
            model.card = .init(entry: entry, finishing: false, copied: false, justRecorded: true)
        }
        shoot("08-people-page") {
            model.card = nil
            model.openPeople()
            model.stage(phase: .idle, microphone: devices.microphone, output: devices.output, notice: .added(12))
        }
        model.root = empty
        shoot("09-people-empty") {
            model.stage(phase: .idle, microphone: devices.microphone, output: devices.output, notice: .copied)
        }
        model.closePeople()
        shoot("10-problem") {
            model.stage(
                phase: .idle, microphone: devices.microphone, output: devices.output,
                problem: "Could not start recording: the microphone is in use by another app.")
        }
        print(outURL.path)
        exit(0)
    }

    private static func render(model: AppModel, dark: Bool, to url: URL) {
        let view = PanelView(model: model, close: {}, resized: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: 0, width: PanelView.width, height: 600), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    private static func seed(_ root: URL) {
        let library = RecordingLibrary(root: root)
        try? library.prepareRoot()
        let now = Date()
        let samples: [(TimeInterval, Double, RecordingEntry.People)] = [
            (-60, 2530, .init()),
            (-26 * 3600, 1447, .init(count: 3, names: ["Priya Shah", "Mei"])),
            (-2 * 86_400, 4360, .init(count: 12)),
            (-3 * 86_400 - 5000, 1810, .init(count: 2, names: ["Priya Shah"])),
            (-9 * 86_400, 3301, .init()),
        ]
        for (offset, duration, people) in samples {
            let started = now.addingTimeInterval(offset)
            guard let folder = try? library.newFolder(at: started) else { continue }
            let meta: [String: Any] = [
                "status": "recorded", "audio": "audio.m4a", "duration_seconds": duration,
                "started": ISO8601DateFormatter().string(from: started),
            ]
            try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
            try? RecordingLibrary.save(people: people, in: folder)
        }
        try? PeopleList(
            you: "Sam",
            people: [
                "Priya Shah", "Mei", "José Ortiz", "Ana", "Bo", "Dana Kim", "Ravi", "Lena", "Tom", "Yuki", "Omar",
                "Iris",
            ]
            .map { .init(name: $0) }
        ).save(to: root)
    }
}
