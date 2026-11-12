import Foundation
import TapeUpCore

/// Only display data crosses CommandLink; voice prints and Undo snapshots do not.
struct CommandOutcome {
    var text: String
    var value: Any
    var rename: VoiceLibrary.RenameResult?

    func encoded() throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: ["text": text, "value": value], options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor
enum CLIWork {
    static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    static var executable: String {
        let running = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL
            .resolvingSymlinksInPath()
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(
            separator: ":", omittingEmptySubsequences: false)
        {
            let candidate = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory)).appendingPathComponent(
                "TapeUp")
            if FileManager.default.isExecutableFile(atPath: candidate.path),
                candidate.resolvingSymlinksInPath() == running
            {
                return "TapeUp"
            }
        }
        return quote(running.path)
    }

    static func runnable(_ command: String) -> String {
        let characters = Array(command)
        var result = ""
        var index = 0
        var quoted: Character?
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if escaped {
                result.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\" {
                result.append(character)
                escaped = true
                index += 1
                continue
            }
            if let quote = quoted {
                result.append(character)
                if character == quote { quoted = nil }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                quoted = character
                result.append(character)
                index += 1
                continue
            }
            if String(characters[index...]).hasPrefix("TapeUp ") {
                let remaining = String(characters.dropFirst(index + 7))
                let noun = String(remaining.prefix { $0.isLetter || $0 == "-" })
                if CLI.commands.contains(noun) {
                    result += executable + " "
                    index += 7
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    static func next(_ outcome: CommandOutcome, _ command: String?) -> CommandOutcome {
        guard let command else { return outcome }
        let rendered = runnable(command)
        var outcome = outcome
        outcome.text += "\nNext: " + rendered
        var value = outcome.value as? [String: Any] ?? [:]
        value["next"] = rendered
        outcome.value = value
        return outcome
    }

    static func labelsCurrent(_ folder: URL, count: Int?) -> Bool {
        guard (MetaFile.read(folder)?["speaker_labels"] as? [String: Any])?["status"] as? String == "done",
            let result = SpeakerLabels.result(in: folder),
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(SpeakerLabels.fileName).path)
        else { return false }
        return count == nil || count == result.count || count == result.folded
    }

    static func afterRecording(_ folder: URL) -> String? {
        labelsCurrent(folder, count: nil) ? "TapeUp voices \(RecordingLibrary.stamp(of: folder))" : nil
    }

    static func validatePerson(_ person: String, allowEmpty: Bool = false) throws {
        let person = person.trimmingCharacters(in: .whitespacesAndNewlines)
        if person.hasPrefix("<") || (!allowEmpty && person.isEmpty) {
            throw Refusal(
                "usage", "Give an actual person's name, not a placeholder.", suggestion: "Use the name the user said.")
        }
    }

    static func retryable(_ error: Error) -> Bool {
        if let refusal = error as? Refusal { return refusal.retryable }
        if let error = error as? VoiceLibrary.Failure { return error == .busyRecording || error == .concurrentChange }
        if let error = error as? URLError { return [.timedOut, .networkConnectionLost].contains(error.code) }
        if let error = error as? POSIXError { return [.EAGAIN, .EBUSY, .EINTR].contains(error.code) }
        return false
    }

    static func lock(_ folder: URL) throws -> FolderLock {
        errno = 0
        if let held = FolderLock(folder: folder) { return held }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            throw Refusal(
                "busy", "Another process holds this recording's audio lock.",
                suggestion: "Wait for that process to finish, then retry the same command.", retryable: true)
        }
        throw Refusal(
            "write_failed", "Could not open this recording's lock: \(String(cString: strerror(errno))).",
            suggestion: "Check the recording folder still exists and the user can write to it.")
    }

    @discardableResult
    static func check(_ entry: RecordingEntry, busy: Bool = false, needsIdle: Bool = true) throws -> RecordingEntry {
        if entry.status == "recording" {
            throw Refusal(
                "recording", "That recording is still running.", suggestion: "Ask the user to stop it in TapeUp first.")
        }
        try RecordingWork.recover(in: entry.folder, appBusy: busy)
        let fresh = RecordingLibrary.entry(at: entry.folder) ?? entry
        guard needsIdle else { return fresh }
        let meta = MetaFile.read(entry.folder) ?? [:]
        for key in ["transcript", "speaker_labels"] {
            guard let state = meta[key] as? [String: Any],
                ["waiting", "transcribing", "finding"].contains(state["status"] as? String ?? "")
            else { continue }
            let owner = (state["pid"] as? Int).map { "Process \($0)" } ?? "TapeUp"
            throw Refusal(
                "busy",
                "\(owner) owns \(key == "transcript" ? "transcription" : "speaker labeling") for this recording.",
                suggestion: "Wait for that work to finish, then retry the same command.", retryable: true)
        }
        return fresh
    }

    static func requireAudio(_ entry: RecordingEntry) throws {
        guard entry.hasAudio else {
            throw Refusal(
                "no_audio", "This recording has no audio; it was removed or moved.",
                suggestion: "Restore its audio with Finder's Put Back in the Trash before retrying.")
        }
    }

    static func result(_ folder: URL) throws -> SpeakerResult {
        guard let result = SpeakerLabels.result(in: folder) else {
            throw Refusal(
                "no_speakers", "That recording has no completed speaker labels.",
                suggestion: "If the user wants labels, run TapeUp speakers \(RecordingLibrary.stamp(of: folder)).")
        }
        return result
    }

    static func voice(_ argument: String, in result: SpeakerResult) throws -> Int {
        if let number = Int(argument), result.voices.contains(where: { $0.id == number }) { return number }
        let matches = result.names.filter { $0.value.caseInsensitiveCompare(argument) == .orderedSame }.map(\.key)
        guard matches.count == 1, let voice = matches.first else {
            throw Refusal(
                "not_found", "No single voice named \(quote(argument)).",
                suggestion: "Run TapeUp voices with the recording's stamp and use its voice number.")
        }
        return voice
    }

    static func voices(_ folder: URL) throws -> CommandOutcome {
        let result = try result(folder)
        let rows: [[String: Any]] = result.voices.map { voice in
            [
                "voice": voice.id, "name": result.names[voice.id] as Any? ?? NSNull(),
                "provenance": result.names[voice.id].map { _ in result.provenance(for: voice.id).origin.rawValue }
                    as Any? ?? NSNull(),
                "seconds": voice.seconds, "quote": voice.quote,
            ]
        }
        let text = result.voices.map { voice in
            let origin =
                switch result.provenance(for: voice.id).origin {
                case .person: "named"
                case .filled: "filled in from their voice"
                case .confirmed: "confirmed"
                }
            return
                "Voice \(voice.id): \(result.names[voice.id].map { "\($0) (\(origin))" } ?? "none"), \(voice.seconds) seconds; \(voice.quote)"
        }.joined(separator: "\n")
        let nextCommand = result.voices.first { result.names[$0.id] == nil }.map {
            "Ask the user who the unnamed voices are; after they identify Voice \($0.id), use TapeUp voices name \(RecordingLibrary.stamp(of: folder)) \($0.id) \"<name>\"."
        }
        return next(
            CommandOutcome(text: text.isEmpty ? "No voices heard." : text, value: ["voices": rows]), nextCommand)
    }

    static func named(_ folder: URL, voice: Int, before: SpeakerResult, root: URL, busy: Set<String> = []) throws
        -> CommandOutcome
    {
        let after = try result(folder)
        let name = after.names[voice]
        let library = VoiceLibrary(root: root)
        var hits: [VoiceLibrary.PastFill] = []
        if let old = before.names[voice], old != name, before.provenance(for: voice).origin != .person, name != nil {
            hits = try library.pastFills(afterCorrecting: voice, from: old, in: folder, busy: busy)
        }
        let rows: [[String: Any]] = try hits.compactMap { hit in
            guard let token = try library.fillToken(hit.voice, in: hit.recording) else { return nil }
            return [
                "stamp": hit.stamp, "voice": hit.voice, "quote": hit.quote,
                "command": runnable("TapeUp voices name \(hit.stamp) \(hit.voice) \(quote(name!)) --if-fill \(token)"),
            ]
        }
        let suggestion =
            "Ask the user first before changing any earlier fill. These commands refuse a changed or confirmed fill."
        var text = "Voice \(voice): \(name ?? "name cleared"). No other voice was confirmed or taught."
        if !rows.isEmpty {
            text += "\n" + suggestion
            text +=
                "\n"
                + rows.map { "\($0["stamp"]!), Voice \($0["voice"]!): \($0["quote"]!)\n  \($0["command"]!)" }.joined(
                    separator: "\n")
        }
        var value: [String: Any] = [
            "folder": folder.path, "voice": voice, "name": name as Any? ?? NSNull(), "past_fills": rows,
        ]
        if !rows.isEmpty { value["suggestion"] = suggestion }
        return next(CommandOutcome(text: text, value: value), afterRecording(folder))
    }

    static func speakers(_ folder: URL, labeled: Bool) -> CommandOutcome {
        let result = SpeakerLabels.result(in: folder)
        let file = folder.appendingPathComponent(SpeakerLabels.fileName)
        return next(
            CommandOutcome(
                text: "\(result?.voices.count ?? 0) voices: \(file.path)",
                value: [
                    "file": file.path,
                    "voices": result?.voices.count ?? 0, "voices_estimated": result?.estimated ?? false,
                    "labeled": labeled,
                ]), afterRecording(folder))
    }

    static func inspect(_ file: URL) async throws -> RecordingImport.Candidate {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Refusal(
                "not_found", "No file at \(file.path).",
                suggestion: "Check the source path and choose the audio or video file the user meant.")
        }
        do { return try await RecordingImport.inspect(file) } catch {
            throw Refusal(
                "unreadable", "Could not read \(file.path): \(error).",
                suggestion: "Choose a readable audio or video file with sound.")
        }
    }

    static func refusal(_ error: Error) -> Refusal {
        if let refusal = error as? Refusal { return refusal }
        if let failure = error as? RecordingImport.Failure, case .inProgress(let stamp) = failure {
            return Refusal(
                "busy", "Another live process is importing \(stamp).",
                suggestion: "Wait for that import to finish, then retry the same import.", retryable: true, stamp: stamp
            )
        }
        if let failure = error as? VoiceLibrary.Failure {
            switch failure {
            case .busyRecording, .concurrentChange:
                return Refusal(
                    "busy", "Another process holds the recording lock or changed the library.",
                    suggestion: "Wait for that process to finish, then retry the same command.", retryable: true)
            case .staleFill:
                return Refusal(
                    "stale_fill", "That offered fill has changed or been confirmed.",
                    suggestion: "List the voices again and ask the user before changing the current voice.")
            case .ambiguousRecording(let stamp):
                return Refusal(
                    "ambiguous_recording", "More than one folder has stamp \(stamp).",
                    suggestion: "Ask the user to separate the duplicate recording folders before retrying.")
            }
        }
        return Refusal(
            "write_failed", "Could not complete the change: \(error.localizedDescription)",
            suggestion: "Check the source files and folder permissions; fix the reported problem before retrying.",
            retryable: retryable(error))
    }

    static func decode(_ output: String?) throws -> (text: String, value: Any) {
        guard let output, let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String, let value = object["value"]
        else {
            throw Refusal(
                "app_outdated", "The running app returned no command result; it may be an older version.",
                suggestion:
                    "Ask the user to relaunch the updated app when it is not recording, or quit it and rerun the command alone."
            )
        }
        return (text, value)
    }

    static func importCommand(_ file: URL, title: String?) -> String {
        runnable("TapeUp import \(quote(file.path))" + (title.map { " --title \(quote($0))" } ?? ""))
    }

    static func importFailure(_ error: Error, stamp: String, file: URL, title: String?) -> Refusal {
        let refusal = error as? Refusal
        let canRetry = retryable(error)
        return Refusal(
            refusal?.code ?? "import_failed", "\(stamp): \(refusal?.message ?? error.localizedDescription)",
            suggestion: canRetry
                ? "Run the same import again: \(importCommand(file, title: title))"
                : refusal?.suggestion ?? "Check the source and recording files are readable before trying again.",
            retryable: canRetry, stamp: stamp)
    }

    static func imported(_ folder: URL, copied: Bool, requestedTitle: String?) -> CommandOutcome {
        let stamp = RecordingLibrary.stamp(of: folder)
        let title = RecordingLibrary.entry(at: folder)?.title
        var text =
            "\(copied ? "Imported" : "Already imported") \(stamp): \(folder.path); transcript and speaker labels ready."
        if !copied, requestedTitle != nil {
            text += " Requested --title was not applied; existing title: \(title ?? "none")."
        }
        return next(
            CommandOutcome(
                text: text,
                value: [
                    "stamp": stamp, "folder": folder.path, "imported": copied,
                    "title": title as Any? ?? NSNull(), "title_applied": copied && requestedTitle != nil,
                    "transcript": folder.appendingPathComponent(TranscriptDocument.fileName).path,
                    "labeled_transcript": folder.appendingPathComponent(SpeakerLabels.fileName).path,
                ]), "TapeUp voices \(stamp)")
    }

    static func people(_ request: [String: String], root: URL, busy: Set<String> = []) throws -> CommandOutcome {
        let recordings = RecordingLibrary(root: root)
        return try recordings.withLock {
            var list = try PeopleList.loadChecked(from: root)
            let action = request["action"] ?? "list"
            let name = (request["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = list.allNames.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            if action != "list" { try validatePerson(name) }
            let voices = VoiceLibrary(root: root)
            switch action {
            case "add":
                if let person = list.people.first(where: { $0.name == canonical }) {
                    if let context = request["context"] {
                        list.update(canonical, to: .init(name: person.name, context: context))
                    }
                } else {
                    list.add(.init(name: canonical, context: request["context"]))
                }
                try list.save(to: root)
                return CommandOutcome(text: "Person saved: \(canonical)", value: ["name": canonical])
            case "remove", "rename":
                let new = (request["new"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let continuing = try voices.isPendingRename(canonical, to: new)
                guard list.contains(canonical) || continuing else {
                    let matches = closeMatches(name, in: list.allNames)
                    throw Refusal(
                        "not_found",
                        "No listed person \(quote(name))."
                            + (matches.isEmpty
                                ? " No close matches."
                                : " Close matches: \(matches.map(quote).joined(separator: ", "))."),
                        suggestion: "Run TapeUp people to check the spelling.")
                }
                if action == "remove" {
                    try voices.forgetPerson(canonical)
                    return CommandOutcome(
                        text:
                            "Person removed: \(canonical); their remembered voice was forgotten. Recordings keep the name.\nThis cannot be undone from the command line.",
                        value: [
                            "name": canonical, "undo": NSNull(),
                            "undo_message": "Cannot be undone from the command line.",
                        ])
                }
                try validatePerson(new)
                let target = list.allNames.first { $0.caseInsensitiveCompare(new) == .orderedSame } ?? new
                let reversingPending = try voices.isPendingRename(target, to: canonical)
                let historic =
                    canonical.caseInsensitiveCompare(target) != .orderedSame
                    && recordings.recordingFolders().contains { folder in
                        let meta = MetaFile.read(folder) ?? [:]
                        let names =
                            (RecordingLibrary.entry(at: folder)?.people.names ?? [])
                            + Array(SpeakerLabels.result(in: folder)?.names.values ?? [Int: String]().values)
                            + [meta["you"] as? String].compactMap { $0 }
                        return names.contains { $0.caseInsensitiveCompare(target) == .orderedSame }
                    }
                if !continuing, canonical.caseInsensitiveCompare(target) != .orderedSame,
                    list.contains(target) || (historic && !reversingPending), request["merge"] != "1"
                {
                    throw Refusal(
                        "name_taken", "\(target) is already listed or named in past recordings.",
                        suggestion: "Ask the user whether they are the same person before adding --merge.")
                }
                let result = try voices.renamePerson(canonical, to: target, busy: busy)
                let skipped = result.skipped.map(RecordingLibrary.stamp(of:))
                let undo =
                    request["merge"] == "1"
                    ? nil : runnable("TapeUp people rename \(quote(target)) \(quote(canonical))")
                var text = "Renamed \(canonical) to \(target): \(result.changedRecordings.count) recordings changed."
                if !skipped.isEmpty { text += " Still to catch up: \(skipped.joined(separator: ", "))." }
                if let problem = result.problem { text += " " + problem }
                text += undo.map { "\nUndo: " + $0 } ?? "\nThis merge cannot be undone from the command line."
                return CommandOutcome(
                    text: text,
                    value: [
                        "name": target, "recordings_changed": result.changedRecordings.count,
                        "skipped": skipped, "still_to_catch_up": skipped, "undo": undo as Any? ?? NSNull(),
                        "undo_message": undo.map { "Undo: " + $0 } ?? "Cannot be undone from the command line.",
                    ], rename: result)
            default:
                var rows: [[String: Any]] = []
                if let you = list.you { rows.append(["name": you, "you": true, "context": NSNull()]) }
                rows += list.people.map { ["name": $0.name, "you": false, "context": $0.context as Any? ?? NSNull()] }
                return CommandOutcome(
                    text: rows.isEmpty
                        ? "No people listed."
                        : rows.map {
                            "\($0["name"]!)\($0["you"] as? Bool == true ? " (you)" : "")\(($0["context"] as? String).map { ": \($0)" } ?? "")"
                        }.joined(separator: "\n"), value: ["people": rows])
            }
        }
    }

    private static func closeMatches(_ name: String, in names: [String]) -> [String] {
        func distance(_ lhs: String, _ rhs: String) -> Int {
            let left = Array(lhs.lowercased())
            let right = Array(rhs.lowercased())
            var row = Array(0...right.count)
            for (i, a) in left.enumerated() {
                var next = [i + 1]
                for (j, b) in right.enumerated() {
                    next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (a == b ? 0 : 1)))
                }
                row = next
            }
            return row.last!
        }
        let scored: [(name: String, score: Int)] = names.map { ($0, distance(name, $0)) }
        let close = scored.filter { $0.score <= max(2, name.count / 3) }
        let sorted = close.sorted { left, right in
            left.score == right.score ? left.name < right.name : left.score < right.score
        }
        return sorted.prefix(3).map { $0.name }
    }

    static func removeCheck(_ entry: RecordingEntry) throws {
        if entry.keepAudio {
            throw Refusal(
                "kept", "The user locked this recording's audio.",
                suggestion: "If they want it gone, the user must unlock it in Free up space.")
        }
        guard entry.hasAudio else { return }
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        guard entry.transcript == .done else {
            throw Refusal(
                "no_transcript", "That recording has no completed transcript.",
                suggestion: "If the user wants one, run TapeUp transcribe \(stamp) first.")
        }
        if ((MetaFile.read(entry.folder)?["transcript"] as? [String: Any])?["missing_passages"] as? Int ?? 0) > 0 {
            throw Refusal(
                "incomplete_transcript", "Some passages were not transcribed; removing audio would lose them.",
                suggestion: "Keep the audio. If the user wants to try again, run TapeUp transcribe \(stamp).")
        }
        guard labelsCurrent(entry.folder, count: nil) else {
            throw Refusal(
                "no_speakers", "Speakers have not been labeled; keep the audio for that work.",
                suggestion: "If the user wants labels, run TapeUp speakers \(stamp) first.")
        }
    }

    static func removed(_ folder: URL, removed: Bool, trash: URL? = nil) -> CommandOutcome {
        let undo =
            trash.map { "Audio is in the Trash at \($0.path); Finder's Put Back restores it." }
            ?? "For previously removed audio, Finder's Put Back in the Trash restores it."
        return next(
            CommandOutcome(
                text:
                    "\(RecordingLibrary.stamp(of: folder)) \(removed ? "audio moved to the Trash" : "already has no audio").\n\(undo)",
                value: [
                    "folder": folder.path, "stamp": RecordingLibrary.stamp(of: folder), "removed": removed,
                    "trash": trash?.path as Any? ?? NSNull(), "undo": undo,
                ]), afterRecording(folder))
    }

    static func kept(_ folder: URL) -> CommandOutcome {
        CommandOutcome(
            text: "\(RecordingLibrary.stamp(of: folder)) audio locked. Only the user unlocks it in Free up space.",
            value: ["folder": folder.path, "keep_audio": true])
    }

    static func alone(_ request: [String: String], root: URL) throws -> CommandOutcome {
        if request["command"] == "people" { return try people(request, root: root) }
        let library = RecordingLibrary(root: root)
        return try library.withLock {
            guard let folder = library.recording(request["recording"] ?? ""),
                var entry = RecordingLibrary.entry(at: folder)
            else {
                throw Refusal(
                    "not_found", "The recording was removed, moved outside this library, or its stamp is ambiguous.",
                    suggestion: "Run TapeUp folder and choose a recording in that library by its full stamp.")
            }
            if request["command"] == "voices", request["action"] != "name" {
                try check(entry, needsIdle: false)
                return try voices(folder)
            }
            let command = request["command"] ?? ""
            if command == "remove-audio", entry.keepAudio { try removeCheck(entry) }
            entry = try check(entry, needsIdle: command != "keep" && (command != "remove-audio" || entry.hasAudio))
            switch command {
            case "voices":
                let person = (request["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try validatePerson(person, allowEmpty: true)
                let before = try result(folder)
                let voice = try voice(request["voice"] ?? "", in: before)
                do {
                    try VoiceLibrary(root: root).nameOnly(
                        voice, person.isEmpty ? nil : person, in: folder, expectedFill: request["if-fill"])
                } catch VoiceLibrary.Failure.staleFill {
                    throw Refusal(
                        "stale_fill", "That offered fill has changed or been confirmed; nothing was named.",
                        suggestion:
                            "Run TapeUp voices \(RecordingLibrary.stamp(of: folder)) and ask the user about the current voices."
                    )
                }
                return try named(folder, voice: voice, before: before, root: root)
            case "keep":
                guard request["value"] != "off" else {
                    throw Refusal(
                        "usage", "TapeUp keep takes only a recording.",
                        suggestion: "The user unlocks audio in Free up space.")
                }
                let held = try lock(folder)
                defer { held.release() }
                if !entry.keepAudio {
                    try RecordingLibrary.save(keepAudio: true, in: folder)
                    EventLog.append("audio kept", in: folder)
                }
                return kept(folder)
            case "remove-audio":
                let held = try lock(folder)
                defer { held.release() }
                try removeCheck(entry)
                guard entry.hasAudio else { return removed(folder, removed: false) }
                let location = try Trash.move(entry.audio)
                EventLog.append("audio removed", in: folder)
                return removed(folder, removed: true, trash: location)
            default: throw Refusal("usage", "Unknown command.", suggestion: "Run TapeUp help.")
            }
        }
    }
}
