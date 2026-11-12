import Foundation

extension VoiceLibrary {
    public struct RenameResult: Sendable {
        public var changedRecordings: [URL]
        /// Recording stamps to catch up after their current work finishes.
        public var skipped: [URL]
        public var undo: VoiceFileUndo
    }

    /// Renames or merges everywhere. The caller handles merge confirmation.
    /// Repeat with `only` set to previously skipped folders to catch them up.
    /// Busy stamps include active recording, transcription, and speaker work.
    public func renamePerson(
        _ old: String, to new: String, busy: Set<String> = [], only: [URL]? = nil
    ) throws -> RenameResult {
        try renamePerson(old, to: new, busy: busy, only: only, beforeWrite: { _ in })
    }

    func renamePerson(
        _ old: String, to new: String, busy: Set<String>, only: [URL]?, beforeWrite: (URL) throws -> Void
    ) throws -> RenameResult {
        try VoiceFiles.locked {
            let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !old.isEmpty, !new.isEmpty else { throw VoiceStore.StoreError.invalidExample }
            guard old != new else { return RenameResult(changedRecordings: [], skipped: [], undo: .init(files: [])) }
            func isOld(_ name: String) -> Bool { name.caseInsensitiveCompare(old) == .orderedSame }
            func isRenamed(_ name: String) -> Bool {
                isOld(name) || name.caseInsensitiveCompare(new) == .orderedSame
            }
            var writes: [(URL, Data?)] = []
            // Work from raw JSON so notes and future fields survive a rename.
            if let data = try VoiceFiles.read(PeopleList.url(in: root)) {
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                _ = try PeopleList.loadChecked(from: root)
                let original = object
                let entries = object["people"] as? [Any] ?? []
                func entryName(_ entry: Any) -> String? {
                    (entry as? String) ?? (entry as? [String: Any])?["name"] as? String
                }
                let source = entries.first { entryName($0).map(isOld) == true } as? [String: Any]
                let target = entries.first {
                    guard let name = entryName($0) else { return false }
                    return !isOld(name) && name.caseInsensitiveCompare(new) == .orderedSame
                }
                let you = object["you"] as? String
                if you.map(isOld) == true || you?.caseInsensitiveCompare(new) == .orderedSame {
                    object["you"] = new
                }
                let newYou = object["you"] as? String
                let people: [Any] = entries.compactMap { entry in
                    guard let name = entryName(entry) else { return entry }
                    if name.caseInsensitiveCompare(newYou ?? "") == .orderedSame { return nil }
                    if isOld(name) {
                        if target != nil || newYou?.caseInsensitiveCompare(new) == .orderedSame { return nil }
                        if var renamed = entry as? [String: Any] {
                            renamed["name"] = new
                            return renamed
                        }
                        return new
                    }
                    if name.caseInsensitiveCompare(new) == .orderedSame {
                        if var merged = entry as? [String: Any] {
                            merged["name"] = new
                            if merged["context"] == nil { merged["context"] = source?["context"] }
                            return merged
                        }
                        return new
                    }
                    return entry
                }
                object["people"] = people
                if !NSDictionary(dictionary: original).isEqual(to: object) {
                    writes.append((PeopleList.url(in: root), try VoiceFiles.json(object)))
                }
            }
            if try VoiceFiles.read(VoiceStore.url(in: root)) != nil {
                var store = try VoiceStore.loadChecked(from: root)
                let before = store
                for name in store.people.keys.sorted()
                where isOld(name) || name.caseInsensitiveCompare(new) == .orderedSame {
                    store.renamePerson(name, to: new)
                }
                if store != before { writes.append((VoiceStore.url(in: root), try JSONEncoder().encode(store))) }
            }
            var changed: [URL] = []
            var skipped: [URL] = []
            for folder in only ?? RecordingLibrary(root: root).recordingFolders() {
                if busy.contains(RecordingLibrary.stamp(of: folder)) {
                    skipped.append(folder)
                    continue
                }
                // Ignore empty non-recording folders, but never silently skip an
                // existing unreadable file that could hold the old name.
                guard try VoiceFiles.read(MetaFile.url(in: folder)) != nil else { continue }
                var meta = try VoiceFiles.object(MetaFile.url(in: folder))
                let before = meta
                func names(_ names: [String]) -> [String] {
                    var seen: Set<String> = []
                    return names.map { isRenamed($0) ? new : $0 }.filter { seen.insert($0.lowercased()).inserted }
                }
                if var who = meta["who_was_there"] as? [String: Any], let list = who["names"] as? [String] {
                    who["names"] = names(list)
                    meta["who_was_there"] = who
                }
                if let you = meta["you"] as? String, isRenamed(you) { meta["you"] = new }
                if var labels = meta["speaker_labels"] as? [String: Any], let list = labels["names"] as? [String] {
                    labels["names"] = names(list)
                    meta["speaker_labels"] = labels
                }
                var speakerChanged = false
                if let data = try VoiceFiles.read(folder.appendingPathComponent(SpeakerLabels.resultFileName)) {
                    var result = try JSONDecoder().decode(SpeakerResult.self, from: data)
                    let attendance = (before["who_was_there"] as? [String: Any])?["names"] as? [String] ?? []
                    let manualAttendance = attendance.contains { attendee in
                        isRenamed(attendee)
                            && !result.names.contains { voice, name in
                                name.caseInsensitiveCompare(attendee) == .orderedSame
                                    && result.provenance(for: voice).addedToWhoWasThere
                            }
                    }
                    for (voice, name) in result.names where isRenamed(name) {
                        if name != new {
                            result.names[voice] = new
                            speakerChanged = true
                        }
                        if manualAttendance, result.provenance(for: voice).addedToWhoWasThere {
                            var provenance = result.provenance(for: voice)
                            provenance.addedToWhoWasThere = false
                            result.provenance[voice] = provenance
                            speakerChanged = true
                        }
                    }
                    for (voice, name) in result.suggested where isRenamed(name) && name != new {
                        result.suggested[voice] = new
                        speakerChanged = true
                    }
                    if speakerChanged {
                        guard let lines = TranscriptDocument.lines(in: folder), lines.count == result.assigned.count
                        else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        writes += try VoiceFiles.speakerWrites(result, lines: lines, meta: meta, folder: folder)
                    }
                }
                let metaChanged = !NSDictionary(dictionary: before).isEqual(to: meta)
                guard speakerChanged || metaChanged else { continue }
                if !speakerChanged { writes.append((MetaFile.url(in: folder), try VoiceFiles.json(meta))) }
                let eventsURL = folder.appendingPathComponent("events.jsonl")
                var events = try VoiceFiles.read(eventsURL) ?? Data()
                if !events.isEmpty, events.last != 0x0A { events.append(0x0A) }
                events.append(
                    try JSONSerialization.data(
                        withJSONObject: [
                            "event": "person renamed", "from": old, "to": new,
                            "at": ISO8601DateFormatter().string(from: Date()),
                        ], options: [.sortedKeys]))
                events.append(0x0A)
                writes.append((eventsURL, events))
                changed.append(folder)
            }
            return RenameResult(
                changedRecordings: changed, skipped: skipped,
                undo: try VoiceFiles.apply(writes, beforeWrite: beforeWrite))
        }
    }
}
