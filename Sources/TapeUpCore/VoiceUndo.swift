import Foundation

extension VoiceFileUndo {
    func reversingLabels(in library: VoiceLibrary) -> VoiceFileUndo {
        var undo = self
        let snapshots = files
        undo.inverse = { busy in try library.undoLabelChanges(snapshots, busy: busy) }
        return undo
    }
}

extension VoiceLibrary {
    /// Patch the labels and root identities an operation changed, then reverse
    /// its teaching by sample key. Unrelated meetings, notes and metadata survive.
    func undoLabelChanges(_ files: [VoiceFileUndo.File], rename: (String, String)? = nil, busy: Set<String> = []) throws
        -> VoiceFileUndo.RestoreResult
    {
        try VoiceFiles.withRootLock(root) {
            var result = VoiceFileUndo.RestoreResult()
            var blocked: Set<VoiceSampleKey> = []
            var rollback = VoiceFileUndo(files: [], root: root)
            do {
                let labeled = Set(files.filter { $0.name == SpeakerLabels.resultFileName }.compactMap(\.stamp))
                // Some meetings have attendance but no diarization yet. A merge
                // must split their attendance back too, without rebuilding meta.
                for file in files where file.name == "meta.json" && file.stamp.map({ !labeled.contains($0) }) == true {
                    guard let stamp = file.stamp else { continue }
                    guard !busy.contains(stamp), let folder = file.resolved()?.deletingLastPathComponent(),
                        let held = FolderLock(folder: folder)
                    else {
                        result.skipped.append(file.url)
                        if let conflict = file.conflict { result.failures[file.url] = conflict }
                        continue
                    }
                    defer { held.release() }
                    do {
                        guard var before = try Self.object(file.data), var written = try Self.object(file.written)
                        else { throw CocoaError(.fileReadCorruptFile) }
                        let fresh = try VoiceFiles.object(MetaFile.url(in: folder))
                        if fresh["you"] as? String != written["you"] as? String {
                            before["you"] = fresh["you"]
                            written["you"] = fresh["you"]
                        }
                        var writes = [VoiceFiles.metadataWrite(before: written, after: before, folder: folder)]
                        if let rename {
                            writes.append(.event(folder, "person renamed", ["from": rename.0, "to": rename.1]))
                        }
                        rollback.include(try VoiceFiles.apply(writes))
                        result.restored.append(folder)
                    } catch {
                        result.skipped.append(folder)
                        result.failures[folder] = error.localizedDescription
                    }
                }
                for file in files where file.name == SpeakerLabels.resultFileName {
                    guard let stamp = file.stamp else { continue }
                    guard !busy.contains(stamp), let folder = file.resolved()?.deletingLastPathComponent(),
                        let held = FolderLock(folder: folder)
                    else {
                        result.skipped.append(file.url)
                        if let conflict = file.conflict { result.failures[file.url] = conflict }
                        if let data = file.written,
                            let labels = try? JSONDecoder().decode(SpeakerResult.self, from: data)
                        {
                            for voice in labels.voices { blocked.insert(.init(stamp: stamp, voice: voice.id)) }
                        }
                        continue
                    }
                    defer { held.release() }
                    do {
                        guard let oldData = file.data, let writtenData = file.written,
                            var current = SpeakerLabels.result(in: folder),
                            let lines = TranscriptDocument.lines(in: folder)
                        else { throw CocoaError(.fileReadCorruptFile) }
                        let before = try JSONDecoder().decode(SpeakerResult.self, from: oldData)
                        let written = try JSONDecoder().decode(SpeakerResult.self, from: writtenData)
                        guard current.assigned == written.assigned, lines.count == current.assigned.count else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        var protectedAttendance: Set<String> = []
                        var restoredAttendance: Set<String> = []
                        for voice in Set(before.names.keys).union(written.names.keys).union(before.provenance.keys)
                            .union(written.provenance.keys)
                        {
                            guard
                                before.names[voice] != written.names[voice]
                                    || before.provenance[voice] != written.provenance[voice]
                            else { continue }
                            if current.names[voice] == before.names[voice],
                                current.provenance[voice] == before.provenance[voice]
                            {
                                continue
                            }
                            guard current.names[voice] == written.names[voice],
                                current.provenance[voice] == written.provenance[voice]
                            else {
                                blocked.insert(.init(stamp: stamp, voice: voice))
                                protectedAttendance.formUnion(
                                    [before.names[voice], written.names[voice]].compactMap { $0?.lowercased() })
                                result.skipped.append(file.url)
                                continue
                            }
                            restoredAttendance.formUnion(
                                [before.names[voice], written.names[voice]].compactMap { $0?.lowercased() })
                            current.names[voice] = before.names[voice]
                            current.provenance[voice] = before.provenance[voice]
                        }
                        for voice in Set(before.suggested.keys).union(written.suggested.keys)
                        where before.suggested[voice] != written.suggested[voice]
                            && current.suggested[voice] == written.suggested[voice]
                        {
                            current.suggested[voice] = before.suggested[voice]
                        }
                        let meta = try VoiceFiles.object(MetaFile.url(in: folder))
                        var writes = try VoiceFiles.speakerWrites(current, lines: lines, meta: meta, folder: folder)
                        if let metaFile = files.first(where: { $0.stamp == stamp && $0.name == "meta.json" }),
                            var original = try Self.object(metaFile.data), var after = try Self.object(metaFile.written)
                        {
                            // Speaker names come from the fresh result, not the old metadata array.
                            original["speaker_labels"] = nil
                            after["speaker_labels"] = nil
                            if meta["you"] as? String != after["you"] as? String {
                                original["you"] = meta["you"]
                                after["you"] = meta["you"]
                            }
                            var who = original["who_was_there"] as? [String: Any] ?? [:]
                            var names = who["names"] as? [String] ?? []
                            var afterWho = after["who_was_there"] as? [String: Any] ?? [:]
                            var afterNames = afterWho["names"] as? [String] ?? []
                            // A later choice on a blocked voice owns its attendance
                            // too. Only successfully reversed voices can undo it.
                            let protected = protectedAttendance.subtracting(restoredAttendance)
                            names.removeAll { protected.contains($0.lowercased()) }
                            afterNames.removeAll { protected.contains($0.lowercased()) }
                            afterWho["names"] = afterNames
                            after["who_was_there"] = afterWho
                            for name in afterNames
                            where current.names.values.contains(where: {
                                $0.caseInsensitiveCompare(name) == .orderedSame
                            })
                                && !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
                            { names.append(name) }
                            who["names"] = names
                            original["who_was_there"] = who
                            writes.append(VoiceFiles.metadataWrite(before: after, after: original, folder: folder))
                        }
                        if let rename {
                            writes.append(.event(folder, "person renamed", ["from": rename.0, "to": rename.1]))
                        }
                        rollback.include(try VoiceFiles.apply(writes))
                        result.restored.append(folder)
                    } catch {
                        result.skipped.append(folder)
                        result.failures[folder] = error.localizedDescription
                        if let data = file.written,
                            let labels = try? JSONDecoder().decode(SpeakerResult.self, from: data)
                        {
                            for voice in labels.voices { blocked.insert(.init(stamp: stamp, voice: voice.id)) }
                        }
                    }
                }
                var writes: [VoiceFiles.Write] = []
                var store = VoiceStore.load(from: root)
                if let file = files.first(where: { $0.stamp == nil && $0.name == VoiceStore.fileName }) {
                    let before =
                        try file.data.map { try JSONDecoder().decode(VoiceStore.self, from: $0) } ?? VoiceStore()
                    let after =
                        try file.written.map { try JSONDecoder().decode(VoiceStore.self, from: $0) } ?? VoiceStore()
                    if !store.undoLearning(before: before, after: after, excluding: blocked) {
                        result.skipped.append(VoiceStore.url(in: root))
                    }
                    let current = try VoiceFiles.read(VoiceStore.url(in: root))
                    let restored: Data? =
                        file.data == nil && current == file.written && store.people.isEmpty
                        ? nil : try JSONEncoder().encode(store)
                    writes.append(.file(VoiceStore.url(in: root), restored))
                }
                if let file = files.first(where: { $0.stamp == nil && $0.name == PeopleList.fileName }) {
                    let currentData = try VoiceFiles.read(PeopleList.url(in: root))
                    var current = try Self.object(currentData) ?? ["format": PeopleList.format, "people": []]
                    let before = try Self.object(file.data) ?? [:]
                    let after = try Self.object(file.written) ?? [:]
                    var used = Set(
                        RecordingLibrary(root: root).entries().flatMap { $0.people.names }.map { $0.lowercased() })
                    used.formUnion(store.people.filter { !$0.value.examples.isEmpty }.keys.map { $0.lowercased() })
                    if !Self.undoPeople(before: before, after: after, current: &current, used: used) {
                        result.skipped.append(PeopleList.url(in: root))
                    }
                    let empty = (current["people"] as? [Any] ?? []).isEmpty && current["you"] == nil
                    writes.append(
                        .file(
                            PeopleList.url(in: root),
                            file.data == nil && currentData == file.written && empty
                                ? nil : try VoiceFiles.json(current)))
                }
                rollback.include(try VoiceFiles.apply(writes))
                result.restored += writes.map(\.url)
                result.skipped = Array(Set(result.skipped))
                return result
            } catch {
                _ = try rollback.rollback()
                throw error
            }
        }
    }

    private static func object(_ data: Data?) throws -> [String: Any]? {
        guard let data else { return nil }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    private static func undoPeople(
        before: [String: Any], after: [String: Any], current: inout [String: Any], used: Set<String>
    ) -> Bool {
        func name(_ entry: Any) -> String? { (entry as? String) ?? (entry as? [String: Any])?["name"] as? String }
        func entries(_ value: [String: Any]) -> [String: Any] {
            var result: [String: Any] = [:]
            for entry in value["people"] as? [Any] ?? [] {
                if let name = name(entry) { result[name.lowercased()] = entry }
            }
            return result
        }
        func equal(_ a: Any?, _ b: Any?) -> Bool {
            NSDictionary(dictionary: ["v": a ?? NSNull()]).isEqual(to: ["v": b ?? NSNull()])
        }
        let old = entries(before)
        let written = entries(after)
        var now = entries(current)
        var complete = true
        for key in Set(old.keys).union(written.keys) where !equal(old[key], written[key]) {
            if old[key] == nil && used.contains(key) { continue }
            if equal(now[key], old[key]) { continue }
            guard equal(now[key], written[key]) else {
                complete = false
                continue
            }
            now[key] = old[key]
        }
        current["people"] = now.keys.sorted().compactMap { now[$0] }
        if !equal(before["you"], after["you"]), !equal(current["you"], before["you"]) {
            if equal(current["you"], after["you"]) { current["you"] = before["you"] } else { complete = false }
        }
        return complete
    }
}

/// A live merge receipt also collects deferred recording changes while its UI
/// Undo exists. The journal remains the authority after a relaunch; UI undo
/// itself is intentionally session-local.
final class VoiceRenameUndo: @unchecked Sendable {
    let library: VoiceLibrary
    let old: String
    let new: String
    let id: UUID
    let merge: Bool
    let dependencies: [UUID: Set<String>]
    private let lock = NSLock()
    private var snapshots: VoiceFileUndo

    init(
        library: VoiceLibrary, old: String, new: String, id: UUID, merge: Bool, snapshots: VoiceFileUndo,
        dependencies: [UUID: Set<String>]
    ) {
        self.library = library
        self.old = old
        self.new = new
        self.id = id
        self.merge = merge
        self.dependencies = dependencies
        self.snapshots = snapshots
    }

    func include(_ undo: VoiceFileUndo, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if merge, let aliases = dependencies[id] {
            // An older rename now catching up was redirected into this merge.
            // Its logical pre-merge identity is our source, even when its on-disk
            // labels still used an earlier spelling at the moment of the write.
            var rebased = VoiceFileUndo(files: [], root: library.root)
            for var file in undo.files where file.stamp != nil {
                if let data = file.data {
                    if file.name == SpeakerLabels.resultFileName {
                        guard var result = try? JSONDecoder().decode(SpeakerResult.self, from: data) else { continue }
                        result.names = result.names.mapValues { canonicalSource($0, aliases: aliases) }
                        result.suggested = result.suggested.mapValues { canonicalSource($0, aliases: aliases) }
                        file.data = try? JSONEncoder().encode(result)
                    } else if file.name == "meta.json" {
                        guard var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                            continue
                        }
                        if let you = meta["you"] as? String { meta["you"] = canonicalSource(you, aliases: aliases) }
                        for key in ["who_was_there", "speaker_labels"] {
                            if var field = meta[key] as? [String: Any], let names = field["names"] as? [String] {
                                var seen: Set<String> = []
                                field["names"] = names.map { canonicalSource($0, aliases: aliases) }
                                    .filter { seen.insert($0.lowercased()).inserted }
                                meta[key] = field
                            }
                        }
                        file.data = try? VoiceFiles.json(meta)
                    }
                }
                rebased.files.append(file)
            }
            snapshots.include(rebased)
        } else {
            snapshots.include(undo)
        }
    }

    private func canonicalSource(_ name: String, aliases: Set<String>) -> String {
        aliases.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) ? old : name
    }

    func restore(busy: Set<String>) throws -> VoiceFileUndo.RestoreResult {
        lock.lock()
        let files = snapshots.files
        lock.unlock()
        return try library.undoRename(old: old, new: new, id: id, merge: merge, files: files, busy: busy)
    }

    static let registry = Registry()
    final class Registry: @unchecked Sendable {
        private struct Weak { weak var value: VoiceRenameUndo? }
        private let lock = NSLock()
        private var receipts: [UUID: [Weak]] = [:]

        func register(_ receipt: VoiceRenameUndo) {
            lock.lock()
            defer { lock.unlock() }
            receipts = receipts.mapValues { $0.filter { $0.value != nil } }.filter { !$0.value.isEmpty }
            for id in Set(receipt.dependencies.keys).union([receipt.id]) {
                receipts[id, default: []].append(Weak(value: receipt))
            }
        }

        func include(_ undo: VoiceFileUndo, id: UUID) {
            lock.lock()
            let listeners = receipts[id]?.compactMap(\.value) ?? []
            lock.unlock()
            for receipt in listeners { receipt.include(undo, id: id) }
        }
    }
}
