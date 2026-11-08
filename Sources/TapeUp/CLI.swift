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
                                                 label speakers: N voices (people who talked,
                                                 the user included), or estimated without --voices
          TapeUp agent [off] [--model M] [--effort E]
                                                 show the agent that suggests titles and names, turn
                                                 it off, or set its model and effort ("default" resets)

        <recording> is a recording's folder, its folder name, or the time it
        starts with (2026-11-06-1430). transcribe and speakers wait until the
        work is done: minutes for a long recording, longer the first time while
        a model downloads; progress notes go to stderr. Name voices in the app.
        Add --json anywhere for one JSON object: on stdout when the command
        works, on stderr with error, message, suggestion and retryable when it
        does not. Usage errors exit 2, other failures 1.
        People are listed in people.json in the recordings folder; edit it directly.
        The agent is turned on only by the user, in TapeUp's Settings, under Your AI.

        """

    static let commands: Set = ["folder", "title", "transcribe", "speakers", "agent", "help"]

    private static var json = false

    /// `arguments` is the whole command line; a first word that is not a
    /// command is a usage error, never the app.
    static func run(_ arguments: [String]) {
        var words = Array(arguments.dropFirst())
        json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        let command = words.first ?? "help"
        var rest = Array(words.dropFirst())
        if ["help", "--help", "-h"].contains(command) {
            print(help, terminator: "")
            exit(0)
        }
        switch command {
        case "folder":
            let moving = rest.contains("--move")
            rest.removeAll { $0 == "--move" }
            refuseFlags(rest, usage: "TapeUp folder [<path> [--move]]")
            guard rest.count <= 1 else {
                fail("usage", "TapeUp folder takes one path.", suggestion: "Quote a path that has spaces.")
            }
            guard let path = rest.first else { succeed("Recordings folder: \(root.path)", ["folder": root.path]) }
            let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder), !isFolder.boolValue {
                fail("usage", "\(destination.path) is a file, not a folder.")
            }
            let left = moving || destination == root.standardizedFileURL ? 0 : library.recordingFolders().count
            let previous = root.path
            func done(_ folder: URL) -> Never {
                var text = "Recordings folder: \(folder.path)"
                var object: [String: Any] = ["folder": folder.path]
                if left > 0 {
                    text += "\n\(left) recording\(left == 1 ? "" : "s") made earlier stay in \(previous)."
                    object["recordings_left_behind"] = left
                }
                succeed(text, object)
            }
            send(["command": "folder", "value": destination.path, "move": moving ? "1" : "0"]) { folder in
                done(folder)
            } alone: {
                moveRootAlone(to: destination, moving: moving)
                done(destination)
            }
        case "title":
            guard rest.count >= 2 else {
                fail(
                    "usage", "TapeUp title <recording> <title>",
                    suggestion: "Give the title after the recording; \"\" clears it.")
            }
            let folder = recording(rest[0])
            let title = rest.dropFirst().joined(separator: " ")
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
            refuseFlags(rest, usage: "TapeUp transcribe <recording>")
            guard rest.count == 1 else {
                fail("usage", "TapeUp transcribe <recording>", suggestion: "Run TapeUp help.")
            }
            let folder = recording(rest[0])
            send(["command": "transcribe", "recording": folder.path]) { folder in
                waitForTranscript(stamp: RecordingLibrary.stamp(of: folder))
            } alone: {
                transcribeAlone(folder)
            }
        case "speakers":
            var voices: Int?
            if let index = rest.firstIndex(where: { $0 == "--voices" || $0.hasPrefix("--voices=") }) {
                let given: String?
                if rest[index] == "--voices" {
                    given = index + 1 < rest.count ? rest[index + 1] : nil
                    rest.removeSubrange(index..<min(index + 2, rest.count))
                } else {
                    given = String(rest[index].dropFirst("--voices=".count))
                    rest.remove(at: index)
                }
                guard let number = given.flatMap(Int.init), number >= 1 else {
                    fail("usage", "--voices takes a number from 1 up.", suggestion: "Leave it out to estimate.")
                }
                voices = number
            }
            refuseFlags(rest, usage: "TapeUp speakers <recording> [--voices N]")
            guard rest.count == 1 else {
                fail("usage", "TapeUp speakers <recording> [--voices N]", suggestion: "Run TapeUp help.")
            }
            let folder = recording(rest[0])
            guard RecordingLibrary.entry(at: folder)?.transcript == .done else {
                fail(
                    "no_transcript", "\(folder.lastPathComponent) has no transcript yet.",
                    suggestion: "Run TapeUp transcribe \(RecordingLibrary.stamp(of: folder)) first.")
            }
            var request = ["command": "speakers", "recording": folder.path]
            request["voices"] = voices.map(String.init)
            send(request) { folder in
                waitForSpeakers(stamp: RecordingLibrary.stamp(of: folder))
            } alone: {
                speakersAlone(folder, count: voices)
            }
        case "agent":
            var changes: [String: String] = [:]
            for name in ["model", "effort"] {
                guard let index = rest.firstIndex(of: "--\(name)") else { continue }
                guard index + 1 < rest.count, !rest[index + 1].hasPrefix("--") else {
                    fail("usage", "--\(name) takes a value.", suggestion: "Give \"default\" to reset it.")
                }
                changes[name.capitalized] = rest[index + 1]
                rest.removeSubrange(index...(index + 1))
            }
            refuseFlags(rest, usage: "TapeUp agent [off] [--model M] [--effort E]")
            let efforts = ["minimal", "low", "medium", "high", "xhigh", "max", "default"]
            if let effort = changes["Effort"], !efforts.contains(effort) {
                fail("usage", "--effort is one of \(efforts.joined(separator: ", ")).")
            }
            if rest == ["off"], !changes.isEmpty {
                fail("usage", "TapeUp agent off takes no --model or --effort.", suggestion: "Run them separately.")
            }
            if rest == ["off"] {
                Settings.store.removeObject(forKey: "agent")
            } else if let word = rest.first, rest.count == 1, AgentKind(rawValue: word) != nil || word == "on" {
                fail(
                    "needs_user", "Only the user turns the agent on.",
                    suggestion: "Ask them to pick it in TapeUp's Settings, under Your AI.")
            } else if !rest.isEmpty {
                fail("usage", "TapeUp agent [off] [--model M] [--effort E]", suggestion: "Run TapeUp help.")
            }
            guard let kind = Agents.chosen else {
                if !changes.isEmpty {
                    fail(
                        "no_agent", "No agent is on.",
                        suggestion: "The user picks one in TapeUp's Settings, under Your AI.")
                }
                succeed("Agent: off", ["agent": NSNull()])
            }
            for (name, value) in changes {
                let key = "agent\(name)-\(kind.rawValue)"
                if value == "default" {
                    Settings.store.removeObject(forKey: key)
                } else {
                    Settings.store.set(value, forKey: key)
                }
            }
            let model = Agents.setting("Model", for: kind) ?? (kind == .claude ? "sonnet" : "its own default")
            let effort = Agents.setting("Effort", for: kind) ?? "low"
            succeed(
                "Agent: \(kind.name), model \(model), effort \(effort)",
                [
                    "agent": kind.rawValue,
                    "model": Agents.setting("Model", for: kind) ?? (kind == .claude ? "sonnet" : NSNull()),
                    "effort": effort,
                ])
        default:
            fail("usage", "TapeUp has no command \(command).", suggestion: "Run TapeUp help.")
        }
    }

    private static func refuseFlags(_ words: [String], usage: String) {
        if let flag = words.first(where: { $0.hasPrefix("--") }) {
            fail("usage", "\(usage) has no \(flag).", suggestion: "Run TapeUp help.")
        }
    }

    // MARK: Where things are

    private static var root: URL {
        Settings.store.string(forKey: "recordingsRoot").map { URL(fileURLWithPath: $0) }
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
    /// is not running. The app says at once that it took the request, then
    /// answers when the work is done, which can take minutes for a move.
    private static func send(
        _ request: [String: String], then: @escaping (URL) -> Void, alone: @escaping () -> Void
    ) {
        guard appRunning else { return alone() }
        let id = UUID().uuidString
        let answer = Answer()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: CommandLink.reply, object: nil, queue: .main) { note in
            guard let reply = note.userInfo as? [String: String], reply["id"] == id else { return }
            MainActor.assumeIsolated {
                if reply["taken"] != nil { answer.taken = true } else { answer.reply = reply }
            }
        }
        var message = request
        message["id"] = id
        message["root"] = root.standardizedFileURL.path
        center.postNotificationName(CommandLink.request, object: nil, userInfo: message, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(10)
        while answer.reply == nil && (answer.taken || Date() < deadline) && appRunning {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        center.removeObserver(observer)
        guard let reply = answer.reply else {
            if answer.taken {
                fail(
                    "app_quit", "TapeUp quit before it finished.", suggestion: "Open TapeUp and run the command again.",
                    retryable: true)
            }
            fail(
                "no_answer", "TapeUp is running but did not answer for \(root.path).",
                suggestion:
                    "It may still be starting: run the command again in a few seconds. Do not quit TapeUp; it may be recording.",
                retryable: true)
        }
        if let code = reply["error"] {
            fail(code, reply["message"] ?? code, suggestion: reply["suggestion"], retryable: reply["retryable"] == "1")
        }
        then(URL(fileURLWithPath: reply["folder"] ?? root.path))
    }

    @MainActor private final class Answer {
        var taken = false
        var reply: [String: String]?
    }

    /// Follows the app's work on one recording in `meta.json`, saying on
    /// stderr what it is doing, until `finished` gives an outcome.
    private static func follow(
        stamp: String, quitMessage: String, status: (URL) -> String?, finished: (URL, String?) -> Void
    ) -> Never {
        let watched = root.path
        var said = ""
        while true {
            guard appRunning else {
                fail("app_quit", quitMessage, suggestion: "Open TapeUp and run the command again.", retryable: true)
            }
            guard root.path == watched else {
                fail(
                    "folder_changed", "TapeUp switched to another recordings folder before it finished.",
                    suggestion: "Run TapeUp folder, then the command again.", retryable: true)
            }
            guard let folder = library.folder(withStamp: stamp) else {
                fail("not_found", "The recording \(stamp) is no longer in \(watched).")
            }
            let now = status(folder)
            finished(folder, now)
            if let now, now != said {
                note(now)
                said = now
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
    }

    /// Waits while the app makes the transcript, reading `meta.json`.
    private static func waitForTranscript(stamp: String) -> Never {
        let model = SpeechModel.forNow()
        follow(stamp: stamp, quitMessage: "TapeUp quit before the transcript was made.") { folder in
            switch (MetaFile.read(folder)?["transcript"] as? [String: Any])?["status"] as? String {
            case "transcribing": "Transcribing…"
            case "waiting":
                ModelStore.isDownloaded(model)
                    ? "Waiting for TapeUp…" : "Waiting for \(model.name) to download in TapeUp (it keeps trying)…"
            default: nil
            }
        } finished: { folder, _ in
            switch RecordingLibrary.entry(at: folder)?.transcript {
            case .done: reportTranscript(folder)
            case .failed:
                let meta = MetaFile.read(folder)?["transcript"] as? [String: Any]
                fail(
                    "transcription_failed", meta?["error"] as? String ?? "The transcript could not be made.",
                    retryable: true)
            default: break
            }
        }
    }

    /// Waits while the app labels speakers, reading `meta.json`.
    private static func waitForSpeakers(stamp: String) -> Never {
        follow(stamp: stamp, quitMessage: "TapeUp quit before the speakers were labeled.") { _ in
            SpeakerFinder.isDownloaded()
                ? "Labeling speakers…" : "Waiting for the speaker model to download in TapeUp (it keeps trying)…"
        } finished: { folder, _ in
            let labels = MetaFile.read(folder)?["speaker_labels"] as? [String: Any]
            switch labels?["status"] as? String {
            case "done": reportSpeakers(folder)
            case "failed":
                fail("labels_failed", labels?["error"] as? String ?? "Speakers could not be labeled.", retryable: true)
            default: break
            }
        }
    }

    // MARK: Without the app

    private static func moveRootAlone(to destination: URL, moving: Bool) {
        let from = library
        do {
            var skipped: [String] = []
            if moving, destination != from.root.standardizedFileURL {
                skipped = try from.move(to: destination).skipped
            } else {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            Settings.store.set(destination.path, forKey: "recordingsRoot")
            if !skipped.isEmpty {
                fail(
                    "partly_moved",
                    "\(skipped.count) recordings stayed in \(from.root.path): the new folder already has ones with the same name.",
                    suggestion: "Move or rename them by hand.")
            }
        } catch {
            fail("move_failed", "Could not move the recordings: \(error.localizedDescription)", retryable: true)
        }
    }

    private static func transcribeAlone(_ folder: URL) {
        let stamp = RecordingLibrary.stamp(of: folder)
        let model = SpeechModel.forNow()
        // The same hints the app gives: the people list, who was at recent recordings, their titles.
        let recent = library.recordingFolders().prefix(100).compactMap(RecordingLibrary.entry(at:))
        let names = NameHints.make(
            names: PeopleList.load(from: root).allNames + recent.flatMap(\.people.names),
            titles: recent.compactMap(\.title))
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
                fail(
                    "transcription_failed", "The transcript could not be made: \(error.localizedDescription)",
                    retryable: true)
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
                fail(
                    "labels_failed", "Speakers could not be labeled: \(error.localizedDescription)", retryable: true)
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
