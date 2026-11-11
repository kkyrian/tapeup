import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp recordings-gallery --out <dir>`: pictures of the All recordings
/// page, light and dark, over a made-up library of a few months: at rest,
/// hovered, chips on, the No transcript action and its queue at work,
/// searches with and without a match, and Recent with its Show all link.
@MainActor
enum RecordingsGallery {
    static func run(out: String) -> Never {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let savedRoot = Settings.store.object(forKey: "recordingsRoot")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapeup-recordings-\(UUID().uuidString)")
        seed(root)

        let model = AppModel()
        model.root = root
        model.agents.stage(states: [:], chosen: nil)
        model.transcription.stage(download: .ready)
        model.stage(phase: .idle, microphone: "AirPods Pro", output: "MacBook Pro Speakers")

        func shoot(_ name: String) {
            for dark in [false, true] {
                Snapshot.render(
                    model: model, dark: dark,
                    to: outURL.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
            print("  \(name)")
        }

        shoot("00-recent-show-all")
        model.openAllRecordings()
        shoot("01-many")
        RecordingRow.staged = model.allEntries[1].id
        shoot("02-hover")
        RecordingRow.staged = nil
        model.recordingsFilter.people = ["Priya Shah"]
        shoot("03-chip")
        model.recordingsFilter.people = ["Priya Shah", "Mei"]
        shoot("04-two-chips")
        model.recordingsFilter = RecordingFilter(noTranscript: true)
        shoot("05-no-transcript")
        model.recordingsFilter = RecordingFilter(query: "thursday")
        model.transcriptIndex.load(model.allEntries)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        shoot("06-search-transcript")
        model.recordingsFilter = RecordingFilter(query: "budget")
        shoot("07-search-title-and-transcript")
        model.recordingsFilter = RecordingFilter(query: "zebra")
        shoot("08-search-nothing")
        model.recordingsFilter = RecordingFilter(noNames: true)
        shoot("09-no-names")
        model.recordingsFilter = RecordingFilter(noTranscript: true)
        // The action, clicked: the first one being made, the rest waiting their turn.
        let waiting = model.allEntries.filter(RecordingSearch.needsTranscript)
        model.makeTranscripts(waiting)
        if let first = waiting.first {
            model.transcription.stage(
                current: RecordingLibrary.stamp(of: first.folder),
                progress: .init(fraction: 0.4, line: nil, first: (0.1, Date().addingTimeInterval(-60))))
        }
        shoot("10-queue-running")
        model.closeAllRecordings()

        if let savedRoot {
            Settings.store.set(savedRoot, forKey: "recordingsRoot")
        } else {
            Settings.store.removeObject(forKey: "recordingsRoot")
        }
        try? FileManager.default.removeItem(at: root)
        print(outURL.path)
        exit(0)
    }

    /// About four months of made-up recordings: titled, named or not,
    /// transcribed or not, a few minutes to an hour and a half long.
    static func seed(_ root: URL) {
        let library = RecordingLibrary(root: root)
        try? library.prepareRoot()
        let titles = [
            "Lab sync", "Design review", "Weekly with Ana", "Interview with Mei", "Budget planning", "Advisor meeting",
            "Reading group", "Pilot debrief", "1:1 with Priya", "Survey kickoff", nil, "Grant draft walkthrough",
            "Field team check-in", nil, "Paper feedback", "Recruiting call",
        ]
        let people: [RecordingEntry.People] = [
            .init(count: 3, names: ["Priya Shah", "Mei"]), .init(count: 4, names: ["José Ortiz", "Priya Shah", "Ana"]),
            .init(count: 2, names: ["Ana"]), .init(count: 2, names: ["Mei"]), .init(count: 5),
            .init(count: 2, names: ["Nora Quinn"]), .init(count: 6, names: ["Mei", "Dana Kim", "Ravi"]),
            .init(count: 3, names: ["José Ortiz", "Lena"]), .init(count: 2, names: ["Priya Shah"]), .init(),
            .init(count: 1), .init(count: 3, names: ["Priya Shah", "Nora Quinn"]),
        ]
        let said = [
            "We need the budget numbers before Thursday.", "The survey closed with two hundred responses.",
            "Let's keep the pilot to five participants.", "Can we split the results by site?",
            "I'll send the draft to both of you by Friday.",
        ]
        let now = Date()
        // Newest first: hours, then days, then weeks apart.
        var offsets: [TimeInterval] = [-2 * 3600, -5 * 3600, -26 * 3600, -30 * 3600, -3 * 86_400]
        var day = 4.0
        while offsets.count < 46 {
            day += [1, 2, 3, 1, 4, 2][offsets.count % 6]
            offsets.append(-day * 86_400 - Double(offsets.count % 5) * 3600)
        }
        for (index, offset) in offsets.enumerated() {
            let started = now.addingTimeInterval(offset)
            guard let folder = try? library.newFolder(at: started) else { continue }
            let meta: [String: Any] = [
                "status": "recorded", "audio": "audio.m4a",
                "duration_seconds": Double([1447, 2530, 312, 3301, 4360, 1810, 905][index % 7]),
                "started": ISO8601DateFormatter().string(from: started),
            ]
            try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
            // An empty audio file: the rows mark only recordings without one.
            FileManager.default.createFile(atPath: folder.appendingPathComponent("audio.m4a").path, contents: Data())
            try? RecordingLibrary.save(people: people[index % people.count], in: folder)
            // Older ones were made before transcripts; a couple failed.
            if index % 9 == 4 {
                try? RecordingLibrary.markTranscript("failed", error: "no audio", in: folder)
            } else if index < 30 && index % 7 != 3 {
                let lines = (0..<4).map { line in
                    TranscriptLine(
                        start: Double(line) * 20, end: Double(line) * 20 + 15, text: said[(index + line) % said.count])
                }
                try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
            }
            if let title = titles[index % titles.count] { _ = try? RecordingLibrary.save(title: title, in: folder) }
        }
        try? PeopleList(
            you: "Sam", people: ["Priya Shah", "Mei", "José Ortiz", "Ana", "Nora Quinn"].map { .init(name: $0) }
        ).save(to: root)
    }
}
