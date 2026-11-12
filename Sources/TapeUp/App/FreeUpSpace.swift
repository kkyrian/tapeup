import Foundation
import TapeUpCore

/// What Free up space shows: recordings past an age, or the kept ones.
struct SpaceFilter: Equatable {
    enum Age: CaseIterable, Equatable {
        case all, month, threeMonths, year

        var title: String {
            switch self {
            case .all: "All"
            case .month: "1 month+"
            case .threeMonths: "3 months+"
            case .year: "1 year+"
            }
        }

        /// Recordings started before this are past the age.
        func cutoff(from now: Date) -> Date? {
            let calendar = Calendar.current
            switch self {
            case .all: return nil
            case .month: return calendar.date(byAdding: .month, value: -1, to: now)
            case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)
            case .year: return calendar.date(byAdding: .year, value: -1, to: now)
            }
        }

        func matches(_ entry: RecordingEntry, now: Date = Date()) -> Bool {
            guard let cutoff = cutoff(from: now) else { return true }
            return entry.started < cutoff
        }
    }

    var age = Age.all
    /// On, the page lists the kept recordings instead, which it never clears.
    var kept = false
}

extension AppModel {
    /// Where a recording stands before its audio can go.
    enum SpaceGroup: CaseIterable {
        /// Transcript and speakers done: the audio can go.
        case ready
        /// A transcript, but speakers never labeled: labeling needs the audio.
        case unlabeled
        /// No transcript: the audio is all there is.
        case untranscribed
    }

    /// Recordings that still hold their audio, the one being recorded aside.
    var spaceCandidates: [RecordingEntry] {
        allEntries.filter { $0.hasAudio && $0.folder != activeFolder && $0.status != "recording" }
    }

    func spaceGroup(_ entry: RecordingEntry) -> SpaceGroup {
        if entry.transcript != .done { return .untranscribed }
        return speakers.result(for: entry) == nil ? .unlabeled : .ready
    }

    /// Voices found but never named: they can be named from their lines
    /// once the audio is gone, not by listening.
    func hasUnnamedVoices(_ entry: RecordingEntry) -> Bool {
        guard let result = speakers.result(for: entry) else { return false }
        return result.voices.contains { result.names[$0.id] == nil }
    }

    /// The space the audio takes on disk.
    func audioBytes(_ entry: RecordingEntry) -> Int64 {
        let values = try? entry.audio.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func openFreeUpSpace() {
        if card?.finishing != true { card = nil }
        showingPeople = false
        showingSettings = false
        showingAllRecordings = false
        spaceFilter = SpaceFilter()
        freedAudio = nil
        freedRecordings = nil
        showingFreeUpSpace = true
    }

    func closeFreeUpSpace() {
        showingFreeUpSpace = false
    }

    /// Kept recordings are left out of Free up space; the card's own
    /// Remove audio and the trash still work on them.
    func setKeep(_ entry: RecordingEntry, _ keep: Bool) {
        // A made title may have renamed the folder since the entry was read.
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        let folder = library.folder(withStamp: stamp) ?? entry.folder
        do {
            try RecordingLibrary.save(keepAudio: keep, in: folder)
            EventLog.append(keep ? "audio kept" : "audio no longer kept", in: folder)
            refreshQuietly(stamp)
        } catch {
            show(problem: "Could not save that: \(error.localizedDescription)")
        }
    }

    /// Labels the speakers of each, one after another, without the user's agent.
    func labelSpeakers(_ entries: [RecordingEntry]) {
        for entry in entries where speakers.work(on: entry) == nil || speakers.work(on: entry) == .failed {
            speakers.label(entry, count: entry.people.count, askAgent: false)
        }
    }

    /// Moves the audio of every ready, unkept recording to the Trash; the
    /// transcripts, names and voices stay.
    func freeAudio(_ entries: [RecordingEntry]) {
        let ready = entries.filter { canRemoveAudio($0) && !$0.keepAudio && spaceGroup($0) == .ready }
        guard !ready.isEmpty else { return }
        speakers.player.stop()
        var moved: [String: URL] = [:]
        var failed = 0
        for entry in ready {
            var location: NSURL?
            do {
                try FileManager.default.trashItem(at: entry.audio, resultingItemURL: &location)
                EventLog.append("audio removed", in: entry.folder)
                if let location { moved[RecordingLibrary.stamp(of: entry.folder)] = location as URL }
            } catch {
                failed += 1
            }
        }
        freedRecordings = nil
        freedAudio = moved.isEmpty ? nil : moved
        if failed > 0 { show(problem: "Could not move the audio of \(failed) to the Trash.") }
        reload()
    }

    /// Puts every file the last Free up space removed back.
    func undoFreeAudio() {
        guard let freedAudio else { return }
        self.freedAudio = nil
        var failed = 0
        for (stamp, location) in freedAudio {
            guard let folder = library.folder(withStamp: stamp), let entry = RecordingLibrary.entry(at: folder) else {
                failed += 1
                continue
            }
            do {
                try FileManager.default.moveItem(at: location, to: entry.audio)
                EventLog.append("audio restored", in: folder)
            } catch {
                failed += 1
            }
        }
        if failed > 0 { show(problem: "Could not put back the audio of \(failed).") }
        reload()
    }

    /// Recordings with no transcript have nothing left without their audio,
    /// so they go to the Trash whole.
    func trashUntranscribed(_ entries: [RecordingEntry]) {
        let gone = entries.filter {
            spaceGroup($0) == .untranscribed && !$0.keepAudio && !transcription.isWorking(on: $0)
                && $0.folder != activeFolder
        }
        guard !gone.isEmpty else { return }
        speakers.player.stop()
        var moved: [(entry: RecordingEntry, location: URL)] = []
        for entry in gone {
            var location: NSURL?
            if (try? FileManager.default.trashItem(at: entry.folder, resultingItemURL: &location)) != nil,
                let location
            {
                moved.append((entry, location as URL))
            }
        }
        freedAudio = nil
        freedRecordings = moved.isEmpty ? nil : moved
        if moved.count < gone.count { show(problem: "Could not move \(gone.count - moved.count) to the Trash.") }
        reload()
    }

    func undoTrashUntranscribed() {
        guard let freedRecordings else { return }
        self.freedRecordings = nil
        var failed = 0
        for item in freedRecordings {
            if (try? FileManager.default.moveItem(at: item.location, to: item.entry.folder)) == nil { failed += 1 }
        }
        if failed > 0 { show(problem: "Could not put back \(failed) of them.") }
        reload()
    }
}
