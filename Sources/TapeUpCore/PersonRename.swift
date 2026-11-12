import Foundation

extension VoiceLibrary {
    public struct RenameResult: Sendable {
        public var changedRecordings: [URL]
        /// Busy, unreadable or mismatched folders retained for a later retry.
        public var skipped: [URL]
        public var undo: VoiceFileUndo
        public var failures: [URL: String] = [:]
    }

    static let pendingRenamesFileName = ".pending-voice-renames.json"
    private struct PendingRename: Codable {
        var id: UUID
        var old: String
        var new: String
        var stamps: [String]
        var globalsPending: Bool
        var activeStamp: String? = nil
    }

    /// Persist the intent before touching a recording. Recordings are written
    /// one at a time; root identities are finalized last. Recovery repeats an
    /// interrupted step safely, including when a folder has since been titled.
    public func renamePerson(_ old: String, to new: String, busy: Set<String> = [], only: [URL]? = nil) throws
        -> RenameResult
    {
        try renamePerson(old, to: new, busy: busy, only: only, beforeWrite: { _ in })
    }

    func renamePerson(
        _ old: String, to new: String, busy: Set<String>, only: [URL]?,
        beforeWrite: (URL) throws -> Void
    ) throws -> RenameResult {
        try VoiceFiles.withRootLock(root) {
            let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !old.isEmpty, !new.isEmpty else { throw VoiceStore.StoreError.invalidExample }
            guard old != new else {
                return .init(changedRecordings: [], skipped: [], undo: .init(files: [], root: root))
            }
            var pending = try pendingRenames()
            // Older skipped recordings must catch up directly to the latest
            // identity, even if a newer rename finds no old name in them yet.
            for index in pending.indices where pending[index].new.caseInsensitiveCompare(old) == .orderedSame {
                pending[index].new = new
            }
            var undo = VoiceFileUndo(files: [], root: root)
            let id: UUID
            if let existing = pending.first(where: { $0.old == old && $0.new == new }) {
                id = existing.id
            } else {
                id = UUID()
                let folders = only ?? RecordingLibrary(root: root).recordingFolders()
                pending.append(
                    .init(
                        id: id, old: old, new: new,
                        stamps: Array(Set(folders.map(RecordingLibrary.stamp(of:)))).sorted(), globalsPending: true))
            }
            do {
                undo.include(try savePending(pending))
                return try resumeRename(id, pending: &pending, busy: busy, undo: &undo, beforeWrite: beforeWrite)
            } catch {
                _ = try undo.restore()
                throw error
            }
        }
    }

    /// Call at launch and after recording/transcription/speaker work finishes.
    /// Skips remain durable until a later call can read and lock the folder.
    public func finishPendingRenames(busy: Set<String> = []) throws -> [RenameResult] {
        try VoiceFiles.withRootLock(root) {
            var pending = try pendingRenames()
            var results: [RenameResult] = []
            for id in pending.map(\.id) {
                var undo = VoiceFileUndo(files: [], root: root)
                do {
                    results.append(
                        try resumeRename(id, pending: &pending, busy: busy, undo: &undo, beforeWrite: { _ in }))
                } catch {
                    _ = try undo.restore()
                    throw error
                }
            }
            return results
        }
    }

    /// Pending names still denote the same identity while busy labels retain
    /// an older spelling. Use the equivalence when moving or forgetting samples.
    func pendingAliases() throws -> [String: Set<String>] {
        var aliases: [String: Set<String>] = [:]
        for pending in try pendingRenames() {
            let old = pending.old.lowercased()
            let new = pending.new.lowercased()
            let joined = (aliases[old] ?? [old]).union(aliases[new] ?? [new])
            for name in joined { aliases[name] = joined }
        }
        return aliases
    }

    private func pendingRenames() throws -> [PendingRename] {
        guard let data = try VoiceFiles.read(root.appendingPathComponent(Self.pendingRenamesFileName)) else {
            return []
        }
        return try JSONDecoder().decode([PendingRename].self, from: data)
    }

    private func savePending(_ pending: [PendingRename]) throws -> VoiceFileUndo {
        try VoiceFiles.apply([
            .file(
                root.appendingPathComponent(Self.pendingRenamesFileName),
                pending.isEmpty ? nil : try JSONEncoder().encode(pending))
        ])
    }

    private func resumeRename(
        _ id: UUID, pending: inout [PendingRename], busy: Set<String>, undo: inout VoiceFileUndo,
        beforeWrite: (URL) throws -> Void
    ) throws -> RenameResult {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            return .init(changedRecordings: [], skipped: [], undo: undo)
        }
        let intent = pending[index]
        var changed: [URL] = []
        var skipped: [URL] = []
        var failures: [URL: String] = [:]
        for stamp in intent.stamps {
            guard let folder = RecordingLibrary(root: root).folder(withStamp: stamp) else {
                pending[index].stamps.removeAll { $0 == stamp }
                undo.include(try savePending(pending))
                continue
            }
            guard !busy.contains(stamp), let held = FolderLock(folder: folder) else {
                skipped.append(folder)
                continue
            }
            defer { held.release() }
            let writes: [VoiceFiles.Write]
            do {
                writes = try recordingRename(
                    intent.old, to: intent.new, in: folder, id: intent.id,
                    recovering: intent.activeStamp == stamp)
            } catch {
                skipped.append(folder)
                failures[folder] = error.localizedDescription
                continue
            }
            if !writes.isEmpty {
                pending[index].activeStamp = stamp
                undo.include(try savePending(pending))
                undo.include(try VoiceFiles.apply(writes, beforeWrite: beforeWrite))
                changed.append(folder)
            }
            pending[index].activeStamp = nil
            pending[index].stamps.removeAll { $0 == stamp }
            undo.include(try savePending(pending))
        }
        if intent.globalsPending {
            undo.include(try VoiceFiles.apply(globalRename(intent.old, to: intent.new), beforeWrite: beforeWrite))
            pending[index].globalsPending = false
        }
        if pending[index].stamps.isEmpty { pending.remove(at: index) }
        undo.include(try savePending(pending))
        return .init(changedRecordings: changed, skipped: skipped, undo: undo, failures: failures)
    }

    private func globalRename(_ old: String, to new: String) throws -> [VoiceFiles.Write] {
        func isOld(_ name: String) -> Bool { name.caseInsensitiveCompare(old) == .orderedSame }
        var writes: [VoiceFiles.Write] = []
        var peopleWrite: VoiceFiles.Write?
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
                peopleWrite = .file(PeopleList.url(in: root), try VoiceFiles.json(object))
            }
        }
        if try VoiceFiles.read(VoiceStore.url(in: root)) != nil {
            var store = try VoiceStore.loadChecked(from: root)
            let before = store
            for name in store.people.keys.sorted()
            where isOld(name) || name.caseInsensitiveCompare(new) == .orderedSame {
                store.renamePerson(name, to: new)
            }
            if store != before { writes.append(.file(VoiceStore.url(in: root), try JSONEncoder().encode(store))) }
        }

        if let peopleWrite { writes.append(peopleWrite) }
        return writes
    }

    private func recordingRename(_ old: String, to new: String, in folder: URL, id: UUID, recovering: Bool) throws
        -> [VoiceFiles.Write]
    {
        func isRenamed(_ name: String) -> Bool {
            name.caseInsensitiveCompare(old) == .orderedSame || name.caseInsensitiveCompare(new) == .orderedSame
        }
        var writes: [VoiceFiles.Write] = []
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
        var transcriptChanged = false
        if let data = try VoiceFiles.read(folder.appendingPathComponent(SpeakerLabels.resultFileName)) {
            var result = try JSONDecoder().decode(SpeakerResult.self, from: data)
            guard let lines = TranscriptDocument.lines(in: folder), lines.count == result.assigned.count,
                Set(result.voices.map(\.id)).count == result.voices.count
            else { throw CocoaError(.fileReadCorruptFile) }
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
            if speakerChanged || result.names.values.contains(where: isRenamed) {
                var planned = try VoiceFiles.speakerWrites(
                    result, lines: lines, meta: meta, folder: folder, before: before)
                if case .file(let url, let rendered) = planned[1] {
                    transcriptChanged = try VoiceFiles.read(url) != rendered
                }
                if !speakerChanged { planned.removeFirst() }
                if speakerChanged || transcriptChanged { writes += planned }
            }
        }
        let metaChanged = !NSDictionary(dictionary: before).isEqual(to: meta)
        if !speakerChanged, !transcriptChanged, metaChanged {
            writes.append(VoiceFiles.metadataWrite(before: before, after: meta, folder: folder))
        }
        guard speakerChanged || transcriptChanged || metaChanged || recovering else { return [] }
        let events = try VoiceFiles.read(folder.appendingPathComponent("events.jsonl")) ?? Data()
        let logged = String(decoding: events, as: UTF8.self).split(separator: "\n").contains { line in
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return false
            }
            return entry["rename_id"] as? String == id.uuidString
        }
        if !logged {
            writes.append(.event(folder, "person renamed", ["from": old, "to": new, "rename_id": id.uuidString]))
        }
        return writes
    }
}
