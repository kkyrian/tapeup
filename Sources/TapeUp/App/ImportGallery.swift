import AVFoundation
import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp import-gallery --out <dir>`: pictures of the import window,
/// light and dark, with made-up recordings dropped into a made-up library
/// and imported for real: empty, files listed, importing, done.
@MainActor
enum ImportGallery {
    private static let keys = ["recordingsRoot", "transcribe"]

    static func run(out: String) {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-gallery-\(UUID().uuidString)")
        let root = base.appendingPathComponent("recordings")
        Snapshot.seed(root)
        defaults.set(root.path, forKey: "recordingsRoot")

        let model = AppModel()
        // Never the user's own agent: titles come from Apple's model here.
        model.agents.stage(states: [:], chosen: nil)
        let files = makeFiles(in: base.appendingPathComponent("Old recordings"), long: true)
        let window = ImportWindow(model: model)
        let imports = window.imports

        func settle(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func shot(_ name: String) {
            settle(0.5)
            for dark in [false, true] {
                window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                settle(0.35)
                let file = outURL.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-o", "-l\(window.window.windowNumber)", file.path]
                try? process.run()
                process.waitUntilExit()
            }
            print("  \(name)")
        }
        func waitWhile(_ seconds: Double = 30, _ busy: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while busy() && Date() < deadline { settle(0.1) }
        }

        window.show()
        shot("empty")
        imports.targeted = true
        shot("empty-drop")
        imports.targeted = false
        window.show(adding: files)
        waitWhile { imports.items.count < files.count || imports.reading }
        if let second = imports.items.first(where: { $0.name.hasPrefix("Design review") }) {
            imports.setVoices(3, for: second)
        }
        shot("files")
        imports.targeted = true
        shot("files-drop")
        imports.targeted = false
        imports.start()
        waitWhile { !imports.items.contains { $0.state == .copied } }
        shot("importing")
        waitWhile(120) { imports.importing }
        // Partway through the long one, with a pace to estimate from.
        waitWhile(240) {
            !imports.items.contains {
                imports.progress(of: $0).map { $0.fraction < 0.9 && $0.remaining() != nil } ?? false
            }
        }
        shot("transcribing")
        waitWhile(600) {
            imports.items.contains { item in
                switch imports.stage(of: item) {
                case .waitingToTranscribe, .transcribing, .findingSpeakers: true
                default: false
                }
            }
        }
        shot("done")
        window.window.close()

        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: base)
        exit(0)
    }

    /// The made-up recordings: file name, when, and each line with its voice.
    static var spoken: [(name: String, offset: TimeInterval, lines: [(voice: String, text: String)])] {
        let (one, two, three) = ("Samantha", "Daniel", "Flo (English (US))")
        return [
            (
                "Interview with Mei.wav", -3 * 3600,
                [
                    (one, "Thanks for making time. How do you keep track of meetings today?"),
                    (three, "Mostly notes on my phone, and I lose half of them."),
                    (one, "What happens when you need something from a call a week later?"),
                    (three, "I ask someone who was there, which is a little embarrassing."),
                ]
            ),
            (
                "Design review, José.wav", -26 * 3600 - 2400,
                [
                    (two, "Let's start with the import window. The list works, but it feels plain."),
                    (one, "Agreed. I'd like each file to show its waveform."),
                    (three, "Can we also show where each one lands in the library?"),
                    (two, "Good. Let's try both and decide on Friday."),
                ]
            ),
            (
                "Voice memo 14.wav", -2 * 86_400 + 1800,
                [(one, "Reminder for myself. Send the budget numbers to Priya before the review on Thursday.")]
            ),
            (
                "Weekly with Ana.wav", -3 * 86_400 - 9000,
                [
                    (three, "Quick update. The survey closed with two hundred responses."),
                    (two, "Great. When can we see the first results?"),
                    (three, "Early next week, after I clean the data."),
                ]
            ),
        ]
    }

    /// Made-up recordings: conversations read by the Mac's own voices,
    /// dated so they land among the sample library's recordings, plus one
    /// copy of the same file.
    static func makeFiles(in folder: URL, long: Bool = false) -> [URL] {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let specs = spoken
        var urls: [URL] = []
        for (index, (name, offset, spoken)) in specs.enumerated() {
            // A longer first interview, so its transcript is seen part done.
            let lines = long && index == 0 ? Array(repeating: spoken, count: 12).flatMap { $0 } : spoken
            let url = folder.appendingPathComponent(name)
            write(lines, to: url, scratch: folder)
            let date = now.addingTimeInterval(offset)
            try? FileManager.default.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
            urls.append(url)
        }
        let copy = folder.appendingPathComponent("Weekly with Ana (1).wav")
        try? FileManager.default.copyItem(at: urls[3], to: copy)
        return urls + [copy]
    }

    /// Each line spoken by its voice, with a short pause between turns.
    private static func write(_ lines: [(voice: String, text: String)], to url: URL, scratch: URL) {
        var samples: [Float] = []
        var rate = 22_050.0
        for (index, line) in lines.enumerated() {
            let part = scratch.appendingPathComponent(".part-\(index).aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", line.voice, "-o", part.path, line.text]
            try? say.run()
            say.waitUntilExit()
            guard let file = try? AVAudioFile(forReading: part),
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
            else { continue }
            try? file.read(into: buffer)
            rate = file.processingFormat.sampleRate
            if let channel = buffer.floatChannelData?[0] {
                samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            }
            samples += [Float](repeating: 0, count: Int(rate * 0.5))
            try? FileManager.default.removeItem(at: part)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] =
            url.pathExtension == "m4a"
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
            : format.settings
        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return }
        try? file.write(from: buffer)
    }
}
