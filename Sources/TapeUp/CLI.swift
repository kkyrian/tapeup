import AppKit
import Foundation
import TapeUpCore
import TapeUpSpeech

/// `TapeUp <command>`: settings and work on saved recordings, for agents and
/// scripts. Recordings are started only in the app. While the app runs, a
/// command is handed to it, so the work shows in the panel and only one
/// model loads; otherwise the command does the work itself.
@MainActor
enum CLI {
    static let help = """
        TapeUp: work on saved recordings. Recordings are started in the app.

          TapeUp folder                          show the recordings folder
          TapeUp folder <path> [--move]          use another folder; --move takes the recordings along
          TapeUp title <recording> <title>       name a recording (its folder is renamed); "" clears it
          TapeUp transcribe <recording>          make transcript.md again, on this Mac
          TapeUp speakers <recording> [--voices N]
                                                 label speakers: N voices, or estimated without --voices

        <recording> is a recording's folder, its folder name, or the time it
        starts with (2026-11-06-1430). Add --json for one JSON object on stdout.
        People are listed in people.json in the recordings folder; edit it directly.

        """

    static let commands: Set = ["folder", "title", "transcribe", "speakers", "help", "--help", "-h"]

    private static var json = false

    static func run(_ arguments: [String]) {
        json = arguments.contains("--json")
        let words = arguments.dropFirst().filter { !$0.hasPrefix("--") || $0 == "--help" }
        let command = words.first ?? "help"
        let rest = Array(words.dropFirst())
        switch command {
        case "folder":
            if let path = rest.first {
                let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                send(["command": "folder", "value": destination.path, "move": arguments.contains("--move") ? "1" : "0"])
                { folder in
                    succeed("Recordings folder: \(folder.path)", ["folder": folder.path])
                } alone: {
                    moveRootAlone(to: destination, moving: arguments.contains("--move"))
                }
            } else {
                succeed("Recordings folder: \(root.path)", ["folder": root.path])
            }
        case "title":
            guard rest.count >= 2 || (rest.count == 1 && arguments.last == "") else {
                fail("usage", "TapeUp title <recording> <title>", suggestion: "Run TapeUp help.")
            }
            let target = rest[0]
            let title = rest.count >= 2 ? rest[1] : ""
            let folder = recording(target)
            send(["command": "title", "recording": folder.path, "value": title]) { renamed in
                reportTitle(renamed)
            } alone: {
                do {
                    reportTitle(try RecordingLibrary.save(title: title, in: folder))
                } catch {
                    fail("write_failed", "Could not save the title: \(error.localizedDescription)", retryable: true)
                }
            }
        case "transcribe":
            guard let target = rest.first else {
                fail("usage", "TapeUp transcribe <recording>", suggestion: "Run TapeUp help.")
            }
            let folder = recording(target)
            send(["command": "transcribe", "recording": folder.path]) { folder in
                waitForTranscript(stamp: RecordingLibrary.stamp(of: folder))
            } alone: {
                transcribeAlone(folder)
            }
        case "speakers":
            guard let target = rest.first else {
                fail("usage", "TapeUp speakers <recording> [--voices N]", suggestion: "Run TapeUp help.")
            }
            let voices = Launcher.value(after: "--voices", in: arguments)
            if let voices, Int(voices).map({ $0 < 1 }) ?? true {
                fail("usage", "--voices takes a number from 1 up.", suggestion: "Leave it out to estimate.")
            }
            let folder = recording(target)
            guard RecordingLibrary.entry(at: folder)?.transcript == .done else {
                fail(
                    "no_transcript", "\(folder.lastPathComponent) has no transcript yet.",
                    suggestion: "Run TapeUp transcribe \(RecordingLibrary.stamp(of: folder)) first.")
            }
            var request = ["command": "speakers", "recording": folder.path]
            request["voices"] = voices
            send(request) { folder in
                waitForSpeakers(stamp: RecordingLibrary.stamp(of: folder))
            } alone: {
                speakersAlone(folder, count: voices.flatMap(Int.init))
            }
        default:
            print(help, terminator: "")
            exit(0)
        }
    }

    // MARK: Where things are

    private static var root: URL {
        UserDefaults.standard.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
            ?? RecordingLibrary.defaultRoot
    }

    private static var library: RecordingLibrary { RecordingLibrary(root: root) }

    private static func recording(_ argument: String) -> URL {
        guard let folder = library.recording(argument) else {
            fail(
                "not_found", "No recording \(argument) in \(root.path).",
                suggestion: "Give its folder, folder name or start time, such as 2026-11-06-1430.")
        }
        return folder
    }

    // MARK: Talking to the app

    private static var appRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.kkyrian.TapeUp").contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    /// Hands the request to the running app, or does it here when the app
    /// is not running.
    private static func send(
        _ request: [String: String], then: @escaping (URL) -> Void, alone: @escaping () -> Void
    ) {
        guard appRunning else { return alone() }
        let id = UUID().uuidString
        let answer = Answer()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: CommandLink.reply, object: nil, queue: .main) { note in
            guard let reply = note.userInfo as? [String: String], reply["id"] == id else { return }
            MainActor.assumeIsolated { answer.reply = reply }
        }
        var message = request
        message["id"] = id
        message["root"] = root.standardizedFileURL.path
        center.postNotificationName(CommandLink.request, object: nil, userInfo: message, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(10)
        while answer.reply == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        center.removeObserver(observer)
        guard let reply = answer.reply else {
            fail(
                "no_answer", "TapeUp is running but did not answer for \(root.path).",
                suggestion: "Quit TapeUp and run the command again.", retryable: true)
        }
        if let problem = reply["error"] { fail("refused", problem) }
        then(URL(fileURLWithPath: reply["folder"] ?? root.path))
    }

    @MainActor private final class Answer {
        var reply: [String: String]?
    }

    /// Waits while the app makes the transcript, reading `meta.json`.
    private static func waitForTranscript(stamp: String) -> Never {
        while true {
            guard appRunning else {
                fail(
                    "app_quit", "TapeUp quit before the transcript was made.", suggestion: "Run the command again.",
                    retryable: true)
            }
            if let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder) {
                switch entry.transcript {
                case .done: reportTranscript(folder)
                case .failed:
                    let meta = MetaFile.read(folder)?["transcript"] as? [String: Any]
                    fail(
                        "transcription_failed", meta?["error"] as? String ?? "The transcript could not be made.",
                        retryable: true)
                default: break
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }

    /// Waits while the app labels speakers, reading `meta.json`.
    private static func waitForSpeakers(stamp: String) -> Never {
        while true {
            guard appRunning else {
                fail(
                    "app_quit", "TapeUp quit before the speakers were labeled.", suggestion: "Run the command again.",
                    retryable: true)
            }
            if let folder = library.folder(withStamp: stamp),
                let labels = MetaFile.read(folder)?["speaker_labels"] as? [String: Any]
            {
                switch labels["status"] as? String {
                case "done": reportSpeakers(folder)
                case "failed":
                    fail(
                        "labels_failed", labels["error"] as? String ?? "Speakers could not be labeled.", retryable: true
                    )
                default: break
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }

    // MARK: Without the app

    private static func moveRootAlone(to destination: URL, moving: Bool) {
        let from = library
        do {
            var skipped: [String] = []
            if moving, destination != from.root.standardizedFileURL { skipped = try from.move(to: destination).skipped }
            UserDefaults.standard.set(destination.path, forKey: "recordingsRoot")
            if !skipped.isEmpty {
                fail(
                    "partly_moved",
                    "\(skipped.count) recordings stayed in \(from.root.path): the new folder already has ones with the same name.",
                    suggestion: "Move or rename them by hand.")
            }
            succeed("Recordings folder: \(destination.path)", ["folder": destination.path])
        } catch {
            fail("move_failed", "Could not move the recordings: \(error.localizedDescription)", retryable: true)
        }
    }

    private static func transcribeAlone(_ folder: URL) {
        let stamp = RecordingLibrary.stamp(of: folder)
        let model = SpeechModel.forNow()
        let names = NameHints.make(names: PeopleList.load(from: root).allNames, titles: [])
        let library = library
        Task {
            do {
                if !ModelStore.isDownloaded(model) {
                    note("Downloading \(model.name) (\(Format.gigabytes(model.downloadBytes))) the first time…")
                    try await ModelStore.download(model) { _ in }
                }
                let engine = try await SpeechEngine.load(model)
                guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try await FolderTranscriber.run(folder: folder, engine: engine, names: names)
                reportTranscript(library.folder(withStamp: stamp) ?? folder)
            } catch {
                if let folder = library.folder(withStamp: stamp) {
                    try? RecordingLibrary.markTranscript("failed", model: model.name, error: "\(error)", in: folder)
                }
                fail("transcription_failed", "The transcript could not be made: \(error)", retryable: true)
            }
        }
        NSApplication.shared.run()
    }

    private static func speakersAlone(_ folder: URL, count: Int?) {
        Task {
            do {
                let heard: VoicePrints
                if let saved = VoicePrints.read(in: folder) {
                    heard = saved
                } else {
                    if !SpeakerFinder.isDownloaded() {
                        note("Downloading the speaker model (130 MB) the first time…")
                        try await SpeakerFinder.download { _ in }
                    }
                    try? SpeakerLabels.mark("finding", in: folder)
                    heard = try await SpeakerFinder.listen(folder: folder)
                    try heard.save(in: folder)
                }
                try SpeakerLabels.relabel(heard, count: count, in: folder)
                reportSpeakers(folder)
            } catch {
                try? SpeakerLabels.mark("failed", error: "\(error)", in: folder)
                fail("labels_failed", "Speakers could not be labeled: \(error)", retryable: true)
            }
        }
        NSApplication.shared.run()
    }

    // MARK: Output

    private static func reportTitle(_ folder: URL) -> Never {
        let title = RecordingLibrary.entry(at: folder)?.title
        succeed(
            title.map { "Named \"\($0)\": \(folder.path)" } ?? "Title cleared: \(folder.path)",
            ["folder": folder.path, "title": title as Any])
    }

    private static func reportTranscript(_ folder: URL) -> Never {
        let file = folder.appendingPathComponent(TranscriptDocument.fileName)
        let missing = (MetaFile.read(folder)?["transcript"] as? [String: Any])?["missing_passages"] as? Int ?? 0
        succeed(
            "Transcript: \(file.path)" + (missing > 0 ? " (\(missing) passages could not be transcribed)" : ""),
            ["transcript": file.path, "missing_passages": missing])
    }

    private static func reportSpeakers(_ folder: URL) -> Never {
        let result = SpeakerLabels.result(in: folder)
        let file = folder.appendingPathComponent(SpeakerLabels.fileName)
        let voices = result?.voices.count ?? 0
        let estimated = result?.estimated ?? false
        succeed(
            "\(voices) voice\(voices == 1 ? "" : "s")\(estimated ? " (estimated)" : ""): \(file.path)",
            ["file": file.path, "voices": voices, "voices_estimated": estimated])
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private static func succeed(_ text: String, _ object: [String: Any]) -> Never {
        if json, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(text)
        }
        exit(0)
    }

    private static func fail(
        _ type: String, _ message: String, suggestion: String? = nil, retryable: Bool = false
    ) -> Never {
        if json {
            var object: [String: Any] = ["error": type, "message": message, "retryable": retryable]
            object["suggestion"] = suggestion
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                FileHandle.standardError.write(data + Data("\n".utf8))
            }
        } else {
            FileHandle.standardError.write(
                Data(([message, suggestion].compactMap { $0 }.joined(separator: " ") + "\n").utf8))
        }
        exit(type == "usage" ? 2 : 1)
    }
}
