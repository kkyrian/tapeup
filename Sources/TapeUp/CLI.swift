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
    static var help: String {
        let tool = CLIWork.executable
        return """
            TapeUp: work on saved recordings. Start recordings in the app.
            Usage: \(tool) <command>

            Examples:
              \(tool) import "interview.m4a"
              After the user says who Voice 2 is:
              \(tool) voices name 2026-11-06-1430 2 "Mei"
              \(tool) people rename "Mei" "Nora Quinn"

            Commands:
              folder [<path> [--move]]             show or change the recordings folder
              import <file> [--title T]            copy, transcribe and label; retry missing stages
              title <recording> <title>            set a recording's title (its folder is renamed); "" clears it
              transcribe <recording>               make transcript.md again
              speakers <recording> [--voices N]    keep labels; a different N refolds voices
              voices <recording>                  list voices, names, talk time and quotes
              voices name <recording> <voice> <person>
                                                  name only this voice; "" clears it
              people                              list people, you first
              people add <name> [--context C]      add a person or update their context
              people rename <old> <new> [--merge]  rename everywhere; ask before merging
              people remove <name>                forget their voice for good; ask first
              remove-audio <recording>             Trash audio only after complete transcript and labels
              keep <recording>                     lock audio; only the user unlocks in Free up space
              agent [off] [--model M] [--effort E]  show, disable or configure the title agent
              help                                show this guide

            <recording>: folder, folder name, start stamp (2026-11-06-1430), or latest:
            the recording that started most recently, excluding one still recording.
            latest is not the last import. Use the real stamp the import prints.
            <voice>: its number or current name. Ask the user who it is before naming;
            never infer a person from a file name, quote or placeholder.
            Past-fill commands have a stale-fill guard and change only the reviewed voice.
            Long work can take many minutes: allow a long timeout or run in the background.
            Retrying an interrupted import continues missing stages; a transcript restarts.
            Next: is a suggestion; run it only if it serves what the user asked.
            Use --json when branching in code; plain output when telling the user.
            JSON mode suppresses progress: one object on stdout, or one error object
            on stderr (error, message, suggestion, retryable). Usage exits 2; others 1.
            Merge and remove cannot be undone from the CLI. Only the user enables an agent.

            """
    }

    static let commands: Set = [
        "folder", "title", "transcribe", "speakers", "agent", "help", "import", "voices", "people",
        "remove-audio", "keep",
    ]

    private static var json = false
    private static var output = FileHandle.standardOutput
    private static var errorOutput = FileHandle.standardError
    private static var outputPrepared = false

    /// Before AppKit/preferences can emit diagnostics, reserve the result streams.
    static func prepareOutput(_ arguments: [String]) {
        json = arguments.contains("--json")
        if json {
            routeModelOutput()
            outputPrepared = true
        }
    }

    /// Upstream model loaders print to stdout. Keep the original stream for
    /// the result and route their diagnostics to stderr for the whole command.
    private static func routeModelOutput() {
        fflush(nil)
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else {
            fail("write_failed", "Could not prepare command output.", suggestion: "Check the terminal output stream.")
        }
        if json {
            let errors = dup(STDERR_FILENO)
            let sink = open("/dev/null", O_WRONLY)
            guard errors >= 0, sink >= 0 else {
                close(descriptor)
                fail("write_failed", "Could not prepare JSON output.", suggestion: "Check the terminal output streams.")
            }
            errorOutput = FileHandle(fileDescriptor: errors, closeOnDealloc: true)
            dup2(sink, STDERR_FILENO)
            dup2(sink, STDOUT_FILENO)
            close(sink)
        } else if dup2(STDERR_FILENO, STDOUT_FILENO) < 0 {
            close(descriptor)
            fail("write_failed", "Could not prepare command output.", suggestion: "Check the terminal output streams.")
        }
        output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// `arguments` is the whole command line; a first word that is not a
    /// command is a usage error, never the app.
    static func run(_ arguments: [String]) {
        var words = Array(arguments.dropFirst())
        json = words.contains("--json")
        words.removeAll { $0 == "--json" }
        let command = words.first ?? "help"
        var rest = Array(words.dropFirst())
        if ["help", "--help", "-h"].contains(command) {
            output.write(Data(help.utf8))
            exit(0)
        }
        if !outputPrepared, ["import", "transcribe", "speakers"].contains(command) { routeModelOutput() }
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
                report(try? CommandOutcome(text: text, value: object).encoded())
            }
            send(["command": "folder", "value": destination.path, "move": moving ? "1" : "0"]) { folder, _ in
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
            send(["command": "title", "recording": folder.path, "value": title]) { renamed, _ in
                reportTitle(renamed)
            } alone: {
                do {
                    reportTitle(
                        try library.withLock {
                            let current = library.folder(withStamp: RecordingLibrary.stamp(of: folder)) ?? folder
                            return try RecordingLibrary.save(title: title, in: current)
                        })
                } catch {
                    failure(error)
                }
            }
        case "transcribe":
            refuseFlags(rest, usage: "TapeUp transcribe <recording>")
            guard rest.count == 1 else {
                fail("usage", "TapeUp transcribe <recording>", suggestion: "Run TapeUp help.")
            }
            let folder = recording(rest[0])
            send(["command": "transcribe", "recording": folder.path]) { folder, _ in
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
            guard
                RecordingLibrary.entry(at: folder)?.transcript == .done || CLIWork.labelsCurrent(folder, count: voices)
            else {
                fail(
                    "no_transcript", "\(folder.lastPathComponent) has no transcript yet.",
                    suggestion: "Run TapeUp transcribe \(RecordingLibrary.stamp(of: folder)) first.")
            }
            var request = ["command": "speakers", "recording": folder.path]
            request["voices"] = voices.map(String.init)
            send(request) { folder, output in
                if let output { report(output) }
                waitForSpeakers(stamp: RecordingLibrary.stamp(of: folder))
            } alone: {
                speakersAlone(folder, count: voices)
            }
        case "import":
            let title = option("title", in: &rest)
            refuseFlags(rest, usage: "TapeUp import <file> [--title T]")
            guard rest.count == 1 else { fail("usage", "TapeUp import <file> [--title T]") }
            let file = URL(fileURLWithPath: (rest[0] as NSString).expandingTildeInPath).standardizedFileURL
            var request = ["command": "import", "value": file.path]
            request["title"] = title
            send(request) { _, output in
                report(output)
            } alone: {
                Task {
                    var stamp: String?
                    do {
                        note("Inspecting the import…")
                        let candidate = try await CLIWork.inspect(file)
                        let copy = try await RecordingImport.copyOnce(
                            candidate, into: library,
                            plan: .init(transcribe: true, labelSpeakers: true, title: title))
                        stamp = RecordingLibrary.stamp(of: copy.folder)
                        note("Recording \(stamp!): \(copy.folder.path)")
                        var folder = copy.folder
                        if RecordingLibrary.entry(at: folder)?.transcript != .done {
                            folder = try await transcribeWork(folder, onlyIfMissing: true)
                        }
                        if !CLIWork.labelsCurrent(folder, count: nil) {
                            folder = try await speakersWork(folder, count: nil).folder
                        }
                        report(try CLIWork.imported(folder, copied: copy.imported, requestedTitle: title).encoded())
                    } catch {
                        if let stamp { failure(CLIWork.importFailure(error, stamp: stamp, file: file, title: title)) }
                        failure(error, importing: true)
                    }
                }
                NSApplication.shared.run()
            }
        case "voices", "people", "remove-audio", "keep":
            var request = ["command": command]
            if command == "people" {
                request["context"] = option("context", in: &rest)
                let merge = rest.contains("--merge")
                rest.removeAll { $0 == "--merge" }
                refuseFlags(
                    rest,
                    usage: "TapeUp people [add <name> [--context C] | rename <old> <new> [--merge] | remove <name>]")
                let action = rest.first ?? "list"
                let count = ["list": 0, "add": 2, "rename": 3, "remove": 2][action]
                guard let count, rest.count == count, !merge || action == "rename",
                    request["context"] == nil || action == "add"
                else { fail("usage", "Run TapeUp help for people commands.") }
                request["action"] = action
                if rest.count > 1 { request["value"] = rest[1] }
                if rest.count > 2 { request["new"] = rest[2] }
                request["merge"] = merge ? "1" : "0"
            } else {
                let expectedFill = option("if-fill", in: &rest)
                refuseFlags(rest, usage: "TapeUp \(command) <recording>")
                let naming = command == "voices" && rest.first == "name"
                if expectedFill != nil && !naming {
                    fail("usage", "--if-fill is only for an offered voice correction.", suggestion: "Run TapeUp help.")
                }
                request["if-fill"] = expectedFill
                if naming {
                    rest.removeFirst()
                    request["action"] = "name"
                }
                let valid =
                    naming
                    ? rest.count == 3
                    : rest.count == 1
                guard valid else { fail("usage", "Run TapeUp help for \(command).") }
                if naming { do { try CLIWork.validatePerson(rest[2], allowEmpty: true) } catch { failure(error) } }
                request["recording"] = recording(rest[0]).path
                if naming {
                    request["voice"] = rest[1]
                    request["value"] = rest[2]
                }
                if command == "keep" { request["value"] = "on" }
            }
            let work = request
            send(work) { _, output in
                report(output)
            } alone: {
                do { report(try CLIWork.alone(work, root: root).encoded()) } catch { failure(error) }
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
                let outcome = CommandOutcome(text: "Agent: off", value: ["agent": NSNull()])
                report(try? CLIWork.next(outcome, nil).encoded())
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
            report(
                try? CLIWork.next(
                    CommandOutcome(
                        text:
                            "Agent: \(kind.name), model \(model), effort \(effort)",
                        value: [
                            "agent": kind.rawValue,
                            "model": Agents.setting("Model", for: kind) ?? (kind == .claude ? "sonnet" : NSNull()),
                            "effort": effort,
                        ]), nil
                ).encoded())
        default:
            fail("usage", "TapeUp has no command \(command).", suggestion: "Run TapeUp help.")
        }
    }

    private static func option(_ name: String, in words: inout [String]) -> String? {
        guard let index = words.firstIndex(where: { $0 == "--\(name)" || $0.hasPrefix("--\(name)=") }) else {
            return nil
        }
        let word = words.remove(at: index)
        if word.hasPrefix("--\(name)=") { return String(word.dropFirst(name.count + 3)) }
        guard index < words.count, !words[index].hasPrefix("--") else { fail("usage", "--\(name) takes a value.") }
        return words.remove(at: index)
    }

    private static func report(_ output: String?) -> Never {
        do {
            let result = try CLIWork.decode(output)
            succeed(result.text, result.value)
        } catch { failure(error) }
    }

    private static func failure(_ error: Error, importing: Bool = false) -> Never {
        let refusal = CLIWork.refusal(error)
        fail(
            refusal.code, refusal.message, suggestion: refusal.suggestion, retryable: refusal.retryable,
            stamp: refusal.stamp)
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
        do { try RecordingWork.recover(in: folder, appBusy: !Settings.isStaged && appRunning) } catch { failure(error) }
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
        _ request: [String: String], then: @escaping (URL, String?) -> Void, alone: @escaping () -> Void
    ) {
        guard !Settings.isStaged, appRunning else { return alone() }
        let id = UUID().uuidString
        let answer = Answer()
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: CommandLink.reply, object: nil, queue: .main) { note in
            guard let reply = note.userInfo as? [String: String], reply["id"] == id else { return }
            MainActor.assumeIsolated {
                if let progress = reply["progress"] {
                    CLI.note(progress)
                } else if reply["taken"] != nil {
                    answer.taken = true
                } else {
                    answer.reply = reply
                }
            }
        }
        var message = CommandLink.wireRequest(request)
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
                    "app_quit", "TapeUp quit before it finished.",
                    suggestion: "Run the same command again; it can work without the app.",
                    retryable: true)
            }
            fail(
                "no_answer", "TapeUp is running but did not answer for \(root.path).",
                suggestion:
                    "Check the recordings folder with TapeUp folder and ask the user to use the same folder in the app. Do not quit it while recording.",
                retryable: false)
        }
        guard CommandLink.accepts(reply) else {
            failure(
                Refusal(
                    "app_outdated",
                    "The running app does not support the command's safety protocol; no change was requested using its older commands.",
                    suggestion:
                        "Ask the user to relaunch the updated app when not recording, or quit it and rerun alone."))
        }
        if let code = reply["error"] {
            fail(
                code, reply["message"] ?? code, suggestion: reply["suggestion"], retryable: reply["retryable"] == "1",
                stamp: reply["stamp"])
        }
        then(URL(fileURLWithPath: reply["folder"] ?? root.path), reply["output"])
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
                fail(
                    "app_quit", quitMessage, suggestion: "Run the same command again; it can work without the app.",
                    retryable: true)
            }
            guard root.path == watched else {
                fail(
                    "folder_changed", "TapeUp switched to another recordings folder before it finished.",
                    suggestion: "Check TapeUp folder and choose the recording in the current library before retrying.")
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
                    suggestion: "Check the audio and model are readable before retrying.")
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
                fail(
                    "labels_failed", labels?["error"] as? String ?? "Speakers could not be labeled.",
                    suggestion: "Check the audio, voice files and model are readable before retrying.")
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
            fail(
                "move_failed", "Could not move the recordings: \(error.localizedDescription)",
                suggestion: "Check both folders' permissions and free space before retrying.",
                retryable: CLIWork.retryable(error))
        }
    }

    /// Acquire the same folder lock that removal and voice edits use before
    /// any model or audio work starts. Release it under the root lock when
    /// publishing, so speaker-file saves can take their own nested lock.
    private static func lockAudio(_ folder: URL, command: String) throws -> (URL, FolderLock) {
        try library.withLock {
            guard let current = library.folder(withStamp: RecordingLibrary.stamp(of: folder)),
                let entry = RecordingLibrary.entry(at: current)
            else { throw Refusal("not_found", "That recording no longer exists.") }
            let fresh = try CLIWork.check(entry, needsIdle: false)
            try CLIWork.requireAudio(fresh)
            if let pid = RecordingWork.foreignOwner(in: current) {
                throw Refusal(
                    "busy", "Process \(pid) owns work on this recording.",
                    suggestion: "Wait for that process to finish, then retry.", retryable: true)
            }
            let held = try CLIWork.lock(current)
            do {
                if command == "transcribe" {
                    try RecordingLibrary.markTranscript("waiting", in: current)
                } else {
                    try SpeakerLabels.mark("finding", in: current)
                }
                return (current, held)
            } catch {
                held.release()
                throw error
            }
        }
    }

    private static func transcribeAlone(_ folder: URL) {
        Task {
            do { reportTranscript(try await transcribeWork(folder)) } catch { failure(error) }
        }
        NSApplication.shared.run()
    }

    private static func transcribeWork(_ folder: URL, onlyIfMissing: Bool = false) async throws -> URL {
        let (folder, held): (URL, FolderLock?) = try library.withLock {
            let current = library.folder(withStamp: RecordingLibrary.stamp(of: folder)) ?? folder
            if onlyIfMissing, RecordingLibrary.entry(at: current)?.transcript == .done { return (current, nil) }
            return try lockAudio(current, command: "transcribe")
        }
        guard let held else { return folder }
        defer { held.release() }
        let stamp = RecordingLibrary.stamp(of: folder)
        let model = SpeechModel.forNow()
        let recent = library.recordingFolders().prefix(100).compactMap(RecordingLibrary.entry(at:))
        let names = NameHints.make(
            names: PeopleList.load(from: root).allNames + recent.flatMap(\.people.names),
            titles: recent.compactMap(\.title))
        let library = library
        do {
            if !ModelStore.isDownloaded(model) {
                note("Downloading \(model.name) (\(Format.gigabytes(model.downloadBytes))) the first time…")
                try await ModelStore.download(model) { _ in }
            }
            note("Transcribing…")
            let engine = try await SpeechEngine.load(model)
            guard let folder = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
            let outcome = try await FolderTranscriber.transcribe(folder: folder, engine: engine, names: names)
            return try library.withLock {
                held.release()
                guard let current = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                try TranscriptDocument.save(
                    lines: outcome.lines, failures: outcome.failures, pieces: outcome.pieces, model: engine.model,
                    in: current)
                guard RecordingLibrary.entry(at: current)?.transcript == .done else {
                    throw Refusal(
                        "transcription_failed", "The model failed on every passage.",
                        suggestion: "Keep the audio; check the recording and model before trying again.")
                }
                return current
            }
        } catch {
            if let folder = library.folder(withStamp: stamp) {
                try? library.withLock {
                    try RecordingLibrary.markTranscript("failed", model: model.name, error: "\(error)", in: folder)
                }
            }
            throw Refusal(
                "transcription_failed",
                "The transcript could not be made: \((error as? Refusal)?.message ?? error.localizedDescription)",
                suggestion: (error as? Refusal)?.suggestion
                    ?? "Check the audio and model are readable before retrying.", retryable: CLIWork.retryable(error))
        }
    }

    private static func speakersAlone(_ folder: URL, count: Int?) {
        Task {
            do {
                let result = try await speakersWork(folder, count: count)
                reportSpeakers(result.folder, labeled: result.labeled)
            } catch { failure(error) }
        }
        NSApplication.shared.run()
    }

    private static func speakersWork(_ folder: URL, count: Int?) async throws -> (folder: URL, labeled: Bool) {
        let (folder, held): (URL, FolderLock?) = try library.withLock {
            let current = library.folder(withStamp: RecordingLibrary.stamp(of: folder)) ?? folder
            if CLIWork.labelsCurrent(current, count: count) { return (current, nil) }
            return try lockAudio(current, command: "speakers")
        }
        guard let held else { return (folder, false) }
        defer { held.release() }
        let library = library
        let stamp = RecordingLibrary.stamp(of: folder)
        do {
            let heard: VoicePrints
            var listened = false
            let current = library.folder(withStamp: stamp) ?? folder
            if let saved = VoicePrints.read(in: current) {
                heard = saved
            } else {
                if !SpeakerFinder.isDownloaded() {
                    note("Downloading the speaker model (130 MB) the first time…")
                    try await SpeakerFinder.download { _ in }
                }
                note("Labeling speakers…")
                heard = try await SpeakerFinder.listen(folder: library.folder(withStamp: stamp) ?? folder)
                listened = true
            }
            return try library.withLock {
                guard let current = library.folder(withStamp: stamp) else { throw CocoaError(.fileNoSuchFile) }
                if listened { try heard.save(in: current) }
                held.release()
                let result = try SpeakerLabels.relabel(heard, count: count, in: current)
                if !result.voices.isEmpty { try VoiceLibrary(root: library.root).fill(in: current) }
                return (current, true)
            }
        } catch {
            if let current = library.folder(withStamp: stamp) {
                try? library.withLock { try SpeakerLabels.mark("failed", error: "\(error)", in: current) }
            }
            throw Refusal(
                "labels_failed", "Speakers could not be labeled: \(error.localizedDescription)",
                suggestion: "Check the audio, voice files and model are readable before retrying.",
                retryable: CLIWork.retryable(error))
        }
    }

    // MARK: Output

    private static func reportTitle(_ folder: URL) -> Never {
        let title = RecordingLibrary.entry(at: folder)?.title
        report(
            try? CLIWork.next(
                CommandOutcome(
                    text: title.map { "Title set to \"\($0)\": \(folder.path)" } ?? "Title cleared: \(folder.path)",
                    value: ["folder": folder.path, "title": title as Any? ?? NSNull()]), nil
            ).encoded())
    }

    private static func reportTranscript(_ folder: URL) -> Never {
        let file = folder.appendingPathComponent(TranscriptDocument.fileName)
        let missing = (MetaFile.read(folder)?["transcript"] as? [String: Any])?["missing_passages"] as? Int ?? 0
        report(
            try? CLIWork.next(
                CommandOutcome(
                    text: "Transcript: \(file.path)"
                        + (missing > 0 ? " (\(missing) passages could not be transcribed)" : ""),
                    value: ["transcript": file.path, "missing_passages": missing]), CLIWork.afterRecording(folder)
            ).encoded())
    }

    private static func reportSpeakers(_ folder: URL, labeled: Bool = true) -> Never {
        report(try? CLIWork.speakers(folder, labeled: labeled).encoded())
    }

    private static func note(_ text: String) {
        guard !json else { return }
        errorOutput.write(Data((text + "\n").utf8))
    }

    private static func succeed(_ text: String, _ object: Any) -> Never {
        fflush(nil)
        if json, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            output.write(data + Data("\n".utf8))
        } else {
            output.write(Data((text + "\n").utf8))
        }
        exit(0)
    }

    private static func fail(
        _ type: String, _ message: String, suggestion: String? = nil, retryable: Bool = false, stamp: String? = nil
    ) -> Never {
        fflush(nil)
        if json {
            var object: [String: Any] = ["error": type, "message": message, "retryable": retryable]
            object["stamp"] = stamp
            object["suggestion"] = CLIWork.runnable(suggestion ?? "Run TapeUp help and check the requested operation.")
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                errorOutput.write(data + Data("\n".utf8))
            }
        } else {
            errorOutput.write(
                Data(
                    ([message, suggestion.map(CLIWork.runnable)].compactMap { $0 }.joined(separator: " ") + "\n").utf8))
        }
        exit(type == "usage" ? 2 : 1)
    }
}
