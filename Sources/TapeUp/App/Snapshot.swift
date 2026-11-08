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
        // Setting the model's folder saves it as the user's; put theirs back
        // on the way out, which `exit` reaches and a `defer` would not.
        let savedRoot = UserDefaults.standard.object(forKey: "recordingsRoot")
        func restore() {
            if let savedRoot {
                UserDefaults.standard.set(savedRoot, forKey: "recordingsRoot")
            } else {
                UserDefaults.standard.removeObject(forKey: "recordingsRoot")
            }
            try? FileManager.default.removeItem(at: root)
        }
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
        model.transcription.stage(download: .ready)
        shoot("02-idle") { model.stage(phase: .idle, microphone: devices.microphone, output: devices.output) }
        shoot("02-idle-downloading") { model.transcription.stage(download: .downloading(812_000_000)) }
        shoot("02-idle-transcript-off") { model.transcription.stage(download: .ready, enabled: false) }
        model.transcription.stage(download: .ready)
        shoot("02-idle-checking") {
            model.stage(
                phase: .idle, microphone: devices.microphone, output: devices.output, levels: wave, testing: true)
        }
        shoot("03-recording") {
            model.transcription.stage(
                download: .ready, live: true,
                latest: [
                    "So the second study block runs after the survey.",
                    "Right, and we keep the pilot to five participants before the IRB amendment goes in.",
                ])
            model.stage(
                phase: .recording(started: Date()), elapsed: 2526, microphone: devices.microphone,
                output: devices.output, levels: wave)
        }
        shoot("03-recording-first-words") { model.transcription.stage(download: .ready, live: true) }
        shoot("03-recording-waiting-for-model") {
            model.transcription.stage(download: .downloading(812_000_000), live: false)
        }
        model.transcription.stage(download: .ready)
        let latest = model.recent[0]
        shoot("04-saving") {
            model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
            model.card = .init(entry: latest, finishing: true, justRecorded: true)
        }
        shoot("05-saved") {
            var entry = latest
            entry.transcript = .pending
            model.card = .init(entry: entry, finishing: false, justRecorded: true)
        }
        shoot("05-saved-transcript-done") {
            var entry = latest
            entry.transcript = .done
            model.card = .init(entry: entry, finishing: false, justRecorded: true)
        }
        shoot("05-saved-transcript-failed") {
            var entry = latest
            entry.transcript = .failed
            model.card = .init(entry: entry, finishing: false, justRecorded: false)
        }
        shoot("05-saved-no-transcript") {
            var entry = latest
            entry.transcript = .none
            model.card = .init(entry: entry, finishing: false, justRecorded: false)
        }
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
        restore()
        exit(0)
    }

    static func render(model: AppModel, dark: Bool, to url: URL) {
        let view = PanelView(model: model, close: {}, resized: { _ in })
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

    /// A transcript and what the speaker model heard in it: four model
    /// voices, two of them one person, so labels need no model.
    private static func seedSpeakers(_ folder: URL) {
        let said = [
            "Thanks for making time, I wanted to walk through the pilot results first.",
            "Sure, go ahead.", "We ran forty sessions and the drop-off was lower than we expected.",
            "Lower by how much?", "About a third, mostly in the second week.",
            "That matches what the field team said.", "Can we split it by site?",
            "Yes, I have that in the appendix.", "Then let's plan the next round around the two strongest sites.",
            "I'll draft the plan by Friday.", "Great, send it to both of us.", "Will do.",
        ]
        let voices = [0, 1, 0, 2, 0, 2, 1, 3, 0, 3, 1, 0]
        var lines: [TranscriptLine] = []
        var turns: [VoiceTurn] = []
        for (index, text) in said.enumerated() {
            let start = Double(index) * 150
            lines.append(TranscriptLine(start: start, end: start + 120, text: text))
            turns.append(VoiceTurn(start: start, end: start + 120, voice: voices[index]))
        }
        let prints: [Int: [Float]] = [
            0: [1, 0, 0, 0], 1: [0, 1, 0, 0], 2: [0, 0, 1, 0], 3: [0.8, 0, 0, 0.6],
        ]
        try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
        try? VoicePrints(turns: turns, prints: prints).save(in: folder)
    }

    /// A short call where people name each other, for agent name suggestions.
    static let namesSaidAloud = [
        "Thanks for joining, everyone. José, can you hear us?", "Yes, loud and clear, Priya.",
        "Hi Priya, hi José. Mei here, I have the budget numbers.",
    ]

    static func seedNamesSaidAloud(_ folder: URL) {
        let said: [(Int, String)] = [
            (0, namesSaidAloud[0]), (1, namesSaidAloud[1]), (2, namesSaidAloud[2]),
            (0, "Great, Mei, walk us through the travel line."), (2, "We can cut travel by ten percent this quarter."),
            (1, "I agree, as long as the field visits stay."),
            (0, "Then we decide: cut travel ten percent and keep the field visits."),
        ]
        var lines: [TranscriptLine] = []
        var turns: [VoiceTurn] = []
        for (index, (voice, text)) in said.enumerated() {
            let start = Double(index) * 20
            lines.append(TranscriptLine(start: start, end: start + 15, text: text))
            turns.append(VoiceTurn(start: start, end: start + 15, voice: voice))
        }
        let meta: [String: Any] = [
            "status": "recorded", "audio": "audio.m4a", "duration_seconds": 140.0,
            "started": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)),
        ]
        try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("events.jsonl").path, contents: nil)
        try? RecordingLibrary.save(people: .init(count: 3, names: ["Priya Shah", "José Ortiz"]), in: folder)
        try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
        try? VoicePrints(turns: turns, prints: [0: [1, 0, 0], 1: [0, 1, 0], 2: [0, 0, 1]]).save(in: folder)
    }

    static func seed(_ root: URL) {
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
            if offset == -60 { try? RecordingLibrary.markTranscript("transcribing", in: folder) }
            if offset == -26 * 3600 { _ = try? RecordingLibrary.save(title: "Lab sync", in: folder) }
            if offset == -3 * 86_400 - 5000 { seedSpeakers(folder) }
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
