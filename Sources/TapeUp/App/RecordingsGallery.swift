import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp recordings-gallery --out <dir>`: pictures of the All recordings
/// page, light and dark, in each of its three layouts on trial, over a
/// made-up library of a few months: at rest, a chip on, the No transcript
/// action and its progress, a search and a search with nothing found, and
/// Recent with its Show all link.
@MainActor
enum RecordingsGallery {
    static func run(out: String) -> Never {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let savedRoot = UserDefaults.standard.object(forKey: "recordingsRoot")
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
        for design in 1...3 {
            let prefix = "d\(design)"
            model.openAllRecordings()
            model.recordingsDesign = design
            shoot("\(prefix)-1-many")
            RecordingRow.staged = model.allEntries[1].id
            shoot("\(prefix)-2-hover")
            RecordingRow.staged = nil
            model.recordingsFilter.people = ["Priya Shah"]
            shoot("\(prefix)-3-chip")
            model.recordingsFilter.people = ["Priya Shah", "Mei"]
            shoot("\(prefix)-4-two-chips")
            model.recordingsFilter = RecordingFilter(noTranscript: true)
            shoot("\(prefix)-5-no-transcript")
            model.recordingsFilter = RecordingFilter(query: "budget")
            model.transcriptIndex.load(model.allEntries)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            shoot("\(prefix)-6-search")
            model.recordingsFilter = RecordingFilter(query: "zebra")
            shoot("\(prefix)-7-search-nothing")
            model.recordingsFilter = RecordingFilter(noNames: true)
            shoot("\(prefix)-8-no-names")
        }
        // The action, clicked: every one waits its turn.
        model.recordingsDesign = 1
        model.recordingsFilter = RecordingFilter(noTranscript: true)
        let waiting = model.allEntries.filter(RecordingSearch.needsTranscript)
        model.makeTranscripts(waiting)
        shoot("d1-9-transcribing")
        model.closeAllRecordings()

        if let savedRoot {
            UserDefaults.standard.set(savedRoot, forKey: "recordingsRoot")
        } else {
            UserDefaults.standard.removeObject(forKey: "recordingsRoot")
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
