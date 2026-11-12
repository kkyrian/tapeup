import Foundation
import TapeUpCore

/// The same saved-recording operations for a command alone or handed to the app.
/// Only display data crosses CommandLink; voice prints never do.
struct CommandOutcome {
    var text: String
    var value: Any
    var rename: VoiceLibrary.RenameResult?

    func encoded() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["text": text, "value": value], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
enum CLIWork {
    static func quote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`") + "\""
    }

    static func next(_ outcome: CommandOutcome, _ command: String?) -> CommandOutcome {
        guard let command else { return outcome }
        var outcome = outcome
        outcome.text += "\nNext: " + command
        var object = outcome.value as? [String: Any] ?? [:]
        object["next"] = command
        outcome.value = object
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
        let stamp = RecordingLibrary.stamp(of: folder)
        if labelsCurrent(folder, count: nil) { return "TapeUp voices \(stamp)" }
        guard let entry = RecordingLibrary.entry(at: folder), entry.hasAudio else { return "TapeUp folder" }
        return entry.transcript == .done ? "TapeUp speakers \(stamp)" : "TapeUp transcribe \(stamp)"
    }

    static func importCommand(_ file: URL, title: String?) -> String {
        "TapeUp import \(quote(file.path))" + (title.map { " --title \(quote($0))" } ?? "")
    }

    static func importFailure(_ error: Error, stamp: String, file: URL, title: String?) -> Refusal {
        let refusal = error as? Refusal
        return Refusal(
            refusal?.code ?? "import_failed", "\(stamp): \(refusal?.message ?? error.localizedDescription)",
            suggestion: "Run the same import again: \(importCommand(file, title: title))", retryable: true, stamp: stamp
        )
    }

    static func check(_ entry: RecordingEntry, busy: Bool = false, needsIdle: Bool = true) throws {
        if entry.status == "recording" {
            throw Refusal(
                "recording", "That recording is still running.", suggestion: "Try again after it stops.",
                retryable: true)
        }
        guard needsIdle else { return }
        let labels = MetaFile.read(entry.folder)?["speaker_labels"] as? [String: Any]
        if busy || entry.transcript == .pending
            || labels?["status"] as? String == "finding"
        {
            throw Refusal(
                "busy", "That recording is being transcribed or labeled.", suggestion: "Try again when it finishes.",
                retryable: true)
        }
    }

    static func result(_ folder: URL) throws -> SpeakerResult {
        guard let result = SpeakerLabels.result(in: folder) else {
            throw Refusal(
                "no_speakers", "That recording has no speaker labels yet.",
                suggestion: "TapeUp speakers \(RecordingLibrary.stamp(of: folder))")
        }
        return result
    }

    static func voice(_ argument: String, in result: SpeakerResult) throws -> Int {
        if let number = Int(argument), result.voices.contains(where: { $0.id == number }) { return number }
        let matches = result.names.filter { $0.value.caseInsensitiveCompare(argument) == .orderedSame }.map(\.key)
        guard matches.count == 1, let voice = matches.first else {
            throw Refusal(
                "not_found", "No single voice named \(argument).",
                suggestion: "Run TapeUp voices and use its voice number.")
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
                case .person: "named by the user"
                case .filled: "filled in from their voice"
                case .confirmed: "confirmed"
                }
            return
                "Voice \(voice.id): \(result.names[voice.id].map { "\($0) (\(origin))" } ?? "none"), \(voice.seconds) seconds; \(voice.quote)"
        }.joined(separator: "\n")
        let nextCommand = result.voices.first { result.names[$0.id] == nil }.map {
            "TapeUp voices name \(RecordingLibrary.stamp(of: folder)) \($0.id) \"<person>\""
        }
        return next(
            CommandOutcome(text: text.isEmpty ? "No voices heard." : text, value: ["voices": rows]), nextCommand)
    }

    static func named(_ folder: URL, voice: Int, before: SpeakerResult, root: URL, busy: Set<String> = []) throws
        -> CommandOutcome
    {
        let after = try result(folder)
        let name = after.names[voice]
        var hits: [VoiceLibrary.PastFill] = []
        if let old = before.names[voice], old != name, before.provenance(for: voice).origin != .person, name != nil {
            hits = try VoiceLibrary(root: root).pastFills(afterCorrecting: voice, from: old, in: folder, busy: busy)
        }
        let suggestion = "Ask the user first before changing any earlier fill."
        var text = "Voice \(voice): \(name ?? "name cleared")."
        if !hits.isEmpty {
            text +=
                "\n"
                + hits.map {
                    "\($0.stamp), Voice \($0.voice): \($0.quote)\n  TapeUp voices name \($0.stamp) \($0.voice) \(quote(name!))"
                }.joined(separator: "\n")
            text += "\n" + suggestion
        }
        var object: [String: Any] = [
            "folder": folder.path, "voice": voice, "name": name as Any? ?? NSNull(),
            "past_fills": hits.map {
                [
                    "stamp": $0.stamp, "voice": $0.voice, "quote": $0.quote,
                    "command": "TapeUp voices name \($0.stamp) \($0.voice) \(quote(name!))",
                ] as [String: Any]
            },
        ]
        if !hits.isEmpty { object["suggestion"] = suggestion }
        return next(CommandOutcome(text: text, value: object), "TapeUp voices \(RecordingLibrary.stamp(of: folder))")
    }

    static func speakers(_ folder: URL, labeled: Bool) -> CommandOutcome {
        let result = SpeakerLabels.result(in: folder)
        let file = folder.appendingPathComponent(SpeakerLabels.fileName)
        let count = result?.voices.count ?? 0
        return next(
            CommandOutcome(
                text: "\(count) voices\(result?.estimated == true ? " (estimated)" : ""): \(file.path)",
                value: [
                    "file": file.path, "voices": count, "voices_estimated": result?.estimated ?? false,
                    "labeled": labeled,
                ]),
            "TapeUp voices \(RecordingLibrary.stamp(of: folder))")
    }

    static func imported(_ folder: URL, copied: Bool) -> CommandOutcome {
        let stamp = RecordingLibrary.stamp(of: folder)
        return next(
            CommandOutcome(
                text:
                    "\(copied ? "Imported" : "Already imported") \(stamp): \(folder.path); transcript and speaker labels ready.",
                value: ["stamp": stamp, "folder": folder.path, "imported": copied]), "TapeUp voices \(stamp)")
    }

    static func people(_ request: [String: String], root: URL, busy: Set<String> = []) throws -> CommandOutcome {
        let library = RecordingLibrary(root: root)
        return try library.withLock {
            var list = try PeopleList.loadChecked(from: root)
            let action = request["action"] ?? "list"
            let name = (request["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if action != "list", name.isEmpty { throw Refusal("usage", "Give a nonempty person's name.") }
            let canonical = list.allNames.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
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
                return next(
                    CommandOutcome(text: "Person saved: \(canonical)", value: ["name": canonical]), "TapeUp people")
            case "remove":
                try VoiceLibrary(root: root).forgetPerson(canonical)
                return next(
                    CommandOutcome(
                        text:
                            "Person removed: \(canonical); recordings keep the name.\nThis cannot be undone from the command line.",
                        value: [
                            "name": canonical, "undo": NSNull(),
                            "undo_message": "This cannot be undone from the command line.",
                        ]), "TapeUp people")
            case "rename":
                var new = (request["new"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !new.isEmpty else { throw Refusal("usage", "Give a nonempty new name.") }
                if let existing = list.allNames.first(where: {
                    $0 != canonical && $0.caseInsensitiveCompare(new) == .orderedSame
                }) {
                    let continuing = try VoiceLibrary(root: root).isPendingRename(canonical, to: existing)
                    guard request["merge"] == "1" || continuing
                    else {
                        throw Refusal(
                            "name_taken", "\(existing) is already listed.",
                            suggestion: "Ask the user whether they are the same person before adding --merge.")
                    }
                    new = existing
                }
                let result = try VoiceLibrary(root: root).renamePerson(canonical, to: new, busy: busy)
                let skipped = result.skipped.map(RecordingLibrary.stamp(of:))
                var text = "Renamed \(canonical) to \(new): \(result.changedRecordings.count) recordings changed."
                if !skipped.isEmpty { text += " Still to catch up: \(skipped.joined(separator: ", "))." }
                let undo = request["merge"] == "1" ? nil : "TapeUp people rename \(quote(new)) \(quote(canonical))"
                text += undo.map { "\nUndo: " + $0 } ?? "\nThis merge cannot be undone from the command line."
                return next(
                    CommandOutcome(
                        text: text,
                        value: [
                            "name": new, "recordings_changed": result.changedRecordings.count,
                            "skipped": skipped, "still_to_catch_up": skipped, "undo": undo as Any? ?? NSNull(),
                            "undo_message": undo.map { "Undo: " + $0 }
                                ?? "This merge cannot be undone from the command line.",
                        ], rename: result), "TapeUp people")
            default:
                var rows: [[String: Any]] = []
                if let you = list.you { rows.append(["name": you, "you": true, "context": NSNull()]) }
                rows += list.people.map { ["name": $0.name, "you": false, "context": $0.context as Any? ?? NSNull()] }
                let text = rows.map {
                    "\($0["name"]!)\($0["you"] as? Bool == true ? " (you)" : "")\(($0["context"] as? String).map { ": \($0)" } ?? "")"
                }.joined(separator: "\n")
                return CommandOutcome(text: text.isEmpty ? "No people listed." : text, value: ["people": rows])
            }
        }
    }

    static func removeCheck(_ entry: RecordingEntry) throws {
        guard entry.hasAudio else { return }
        if entry.keepAudio {
            throw Refusal(
                "kept", "That recording's audio is locked.",
                suggestion: "The user locked it in Free up space; ask them first.")
        }
        guard entry.transcript == .done else {
            throw Refusal(
                "no_transcript", "That recording has no transcript yet.",
                suggestion: "Run TapeUp transcribe \(RecordingLibrary.stamp(of: entry.folder)) first.")
        }
    }

    static func removed(_ folder: URL, removed: Bool) -> CommandOutcome {
        let undo =
            removed
            ? "The audio is in the Trash; Finder's Put Back restores it."
            : "For previously removed audio, Finder's Put Back in the Trash restores it."
        return next(
            CommandOutcome(
                text:
                    "\(RecordingLibrary.stamp(of: folder)) \(removed ? "audio moved to the Trash" : "already has no audio").\n\(undo)",
                value: ["folder": folder.path, "removed": removed, "undo": undo]), afterRecording(folder))
    }

    static func kept(_ folder: URL, keep: Bool) -> CommandOutcome {
        next(
            CommandOutcome(
                text: "\(RecordingLibrary.stamp(of: folder)) audio \(keep ? "locked" : "unlocked").",
                value: ["folder": folder.path, "keep_audio": keep]), afterRecording(folder))
    }

    static func alone(_ request: [String: String], root: URL) throws -> CommandOutcome {
        if request["command"] == "people" { return try people(request, root: root) }
        let library = RecordingLibrary(root: root)
        return try library.withLock {
            guard let folder = library.recording(request["recording"] ?? ""),
                let entry = RecordingLibrary.entry(at: folder)
            else {
                throw Refusal("not_found", "That recording no longer exists.")
            }
            if request["command"] == "voices", request["action"] != "name" {
                try check(entry, needsIdle: false)
                return try voices(folder)
            }
            let command = request["command"] ?? ""
            let needsIdle = command != "keep" && (command != "remove-audio" || entry.hasAudio)
            try check(entry, needsIdle: needsIdle)
            switch command {
            case "voices":
                let before = try result(folder)
                let voice = try voice(request["voice"] ?? "", in: before)
                let person = (request["value"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let voices = VoiceLibrary(root: root)
                if person.isEmpty {
                    try voices.unname(voice, in: folder)
                } else if let old = before.names[voice], old.caseInsensitiveCompare(person) != .orderedSame,
                    before.provenance(for: voice).origin != .person
                {
                    try voices.correct(voice, to: person, in: folder)
                } else {
                    try voices.name(voice, person, in: folder)
                }
                return try named(folder, voice: voice, before: before, root: root)
            case "keep", "remove-audio":
                guard let held = FolderLock(folder: folder) else {
                    throw Refusal("busy", "That recording is in use.", retryable: true)
                }
                defer { held.release() }
                if request["command"] == "keep" {
                    let keep = request["value"] != "off"
                    if entry.keepAudio != keep {
                        try RecordingLibrary.save(keepAudio: keep, in: folder)
                        EventLog.append(keep ? "audio kept" : "audio no longer kept", in: folder)
                    }
                    return kept(folder, keep: keep)
                }
                try removeCheck(entry)
                guard entry.hasAudio else { return removed(folder, removed: false) }
                try FileManager.default.trashItem(at: entry.audio, resultingItemURL: nil)
                EventLog.append("audio removed", in: folder)
                return removed(folder, removed: true)
            default: throw Refusal("usage", "Unknown command.")
            }
        }
    }
}
