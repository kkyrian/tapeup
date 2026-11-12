import AppKit
import SwiftUI
import TapeUpCore

/// Where things are in the panel, in its own points, measured from the
/// probe's movie (`TapeUp film --only probe`). Measure again after a
/// layout change.
enum Spot {
    static let record = CGPoint(x: 111, y: 150)
    /// The Microphone and Transcript switches.
    static let microphone = CGPoint(x: 284, y: 71)
    static let transcript = CGPoint(x: 284, y: 107)
    static let more = CGPoint(x: 292, y: 197)
    /// The first recording under Today.
    static let firstRow = CGPoint(x: 122, y: 231)
    static let copyPath = CGPoint(x: 72, y: 80)
    static let close = CGPoint(x: 18, y: 32)
    static let labelSpeakers = CGPoint(x: 55, y: 268)
    static func voice(_ number: Int) -> CGPoint { CGPoint(x: 45, y: 290 + CGFloat(number - 1) * 43) }
}

/// The README's journeys, each from the menu bar to the result, as the
/// user would take it: a quiet start, the steps, and a hold on the result.
@MainActor
struct Journey {
    let name: String
    let size: CGSize
    var setUp: @MainActor (Take) -> Void = { _ in }
    let script: @MainActor (Take) async -> Void

    static let all: [Journey] = [
        record, handoff, speakers, space, importing, importProgress, allRecordings, probe,
    ]

    static var said: [String] { Shots.said.map(\.1) }

    /// Open, turn on the microphone and the transcript, record, watch the
    /// words come, stop: saved, then titled. Computer audio stays on, since
    /// one source always is.
    static let record = Journey(
        name: "record", size: CGSize(width: 420, height: 520),
        setUp: { take in
            take.hideNewest()
            if take.model.microphoneOn { take.model.toggleMicrophone() }
            take.model.transcription.stage(download: .ready, enabled: false)
        },
        script: { take in
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.6)
            await take.move(toPanel: Spot.microphone, 0.6)
            await take.click(take.model.toggleMicrophone)
            await take.pause(0.45)
            await take.move(toPanel: Spot.transcript, 0.4)
            await take.click { take.model.transcription.stage(download: .ready) }
            await take.pause(0.7)
            await take.move(toPanel: Spot.record, 0.6)
            await take.click {
                take.startRecording(from: 0) { elapsed in
                    // A phrase at a time, as the live transcript arrives.
                    let words = said.prefix(4).joined(separator: " ").split(separator: " ")
                    let phrases = max(0, Int((elapsed - 0.4) / 1.4))
                    let shown = min(words.count, phrases * 4)
                    return Shots.lastTwoSentences(words.prefix(shown).joined(separator: " "))
                }
            }
            await take.move(to: CGPoint(x: 250, y: 330), 0.8)
            await take.pause(4.6)
            await take.move(toPanel: Spot.record, 0.6)
            await take.click()
            await take.stopRecording(title: "Beta launch plan")
            await take.move(to: CGPoint(x: 250, y: 330), 0.8)
            await take.pause(2.2)
        })

    /// Copy a recording's path and ask your agent about it.
    static let handoff = Journey(
        name: "handoff", size: CGSize(width: 1110, height: 720),
        setUp: { take in
            if let entry = take.model.recent.first(where: { $0.title == nil }) {
                _ = try? RecordingLibrary.save(title: "Beta launch plan", in: entry.folder)
            }
            take.model.reload()
            take.director.cursor = CGPoint(x: 600, y: 420)
            take.director.terminal = []
            take.director.typing = ""
        },
        script: { take in
            let answer = (Shots.handoff ?? "").components(separatedBy: "\n")
            // The pasted lines, as Copy path writes them with this Mac's home.
            let pasted = answer.prefix(3).map { $0.dropFirst(2).description }.joined(separator: "\n")
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.5)
            await take.move(toPanel: Spot.firstRow, 0.6)
            await take.click {
                guard let entry = take.model.recent.first else { return }
                take.model.card = .init(entry: entry, finishing: false, justRecorded: false)
            }
            await take.pause(0.5)
            await take.move(toPanel: Spot.copyPath, 0.6)
            await take.click {
                // The button's own feedback, without taking the user's clipboard.
                let board = NSPasteboard.general
                let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
                    let copy = NSPasteboardItem()
                    for type in item.types {
                        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                    }
                    return copy
                }
                if let entry = take.model.card?.entry { take.model.copy(entry) }
                board.clearContents()
                if let saved { board.writeObjects(saved) }
            }
            await take.pause(0.3)
            await take.move(to: CGPoint(x: 300, y: 120), 0.9)
            await take.click()
            await take.pause(0.25)
            take.director.typing = pasted
            await take.pause(0.5)
            take.director.typing = pasted + "\n"
            for character in "\nWhat did we decide, and what do I owe by when?" {
                take.director.typing = (take.director.typing ?? "") + String(character)
                await take.pause(0.035 * Double.random(in: 0.6...1.4))
            }
            await take.pause(0.5)
            take.director.typing = nil
            take.director.terminal = Array(answer.prefix(6))
            await take.pause(0.9)
            take.director.terminal = Array(answer.prefix(8))
            await take.pause(0.9)
            for count in 9...answer.count {
                take.director.terminal = Array(answer.prefix(count))
                await take.pause(0.08)
            }
            await take.pause(3.5)
        })

    /// Name a voice once and later meetings fill it in. Label speakers on
    /// the launch call: Voice 1 comes up as Priya Shah, named in yesterday's
    /// design review. A listen checks her and the name stays; then José's
    /// voice plays and is named from the menu.
    static let speakers = Journey(
        name: "speakers", size: CGSize(width: 420, height: 580),
        setUp: { take in
            if let review = take.model.recent.first(where: { $0.title == "Design review" }) {
                namePriya(in: review.folder)
            }
            if let entry = take.model.recent.first(where: { $0.title == nil }) {
                writeVoices(in: entry.folder)
                _ = try? RecordingLibrary.save(title: "Beta launch plan", in: entry.folder)
            }
            take.model.reload()
        },
        script: { take in
            let speakers = take.model.speakers
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.5)
            await take.move(toPanel: Spot.firstRow, 0.6)
            await take.click {
                guard let entry = take.model.recent.first else { return }
                take.model.card = .init(entry: entry, finishing: false, justRecorded: false)
            }
            await take.pause(0.6)
            // The real labeling: the voice store fills Priya in.
            await take.move(toPanel: Spot.labelSpeakers, 0.6)
            await take.click { take.model.labelSpeakers() }
            await take.pause(0.9)
            guard let entry = take.model.card?.entry, let result = speakers.result(for: entry),
                let lines = TranscriptDocument.lines(in: entry.folder)
            else { return }
            func heard(_ voice: Int) -> [String] { zip(lines, result.assigned).filter { $0.1 == voice }.map(\.0.text) }
            // Its name says where it came from, as SpeakersView's help does.
            await take.move(toPanel: Spot.voice(1), 0.6)
            await take.pause(0.25)
            withAnimation(.easeOut(duration: 0.1)) {
                take.director.help = "Filled in from their voice. Pick someone else if it's wrong"
            }
            await take.pause(2.0)
            withAnimation(.easeOut(duration: 0.1)) { take.director.help = nil }
            // A listen, as the play button runs it, checks the fill; the name stays.
            await take.move(toTarget: "Play voice 1", 0.6)
            await take.click {
                speakers.confirm(1, in: entry)
                speakers.player.stage(1, in: entry, line: heard(1).first)
            }
            for line in heard(1).dropFirst().prefix(1) {
                await take.pause(1.4)
                speakers.player.stage(1, in: entry, line: line)
            }
            await take.pause(1.2)
            await take.click { speakers.player.stop() }
            await take.pause(0.5)
            // José answers the third line: play his voice, name it, stop it.
            guard let jose = result.assigned[3] else { return }
            await take.move(toTarget: "Play voice \(jose)", 0.7)
            await take.click { speakers.player.stage(jose, in: entry, line: heard(jose).first) }
            await take.pause(1.3)
            let current = take.model.card?.entry ?? entry
            let others = take.model.suggestions(matching: "", excluding: current.people.names, limit: 12)
            let items = current.people.names + (others.isEmpty ? [] : ["-"] + others)
            await take.pick("José Ortiz", from: take.at(Spot.voice(jose)), items: items) {
                speakers.name(jose, "José Ortiz", in: current)
            }
            await take.pause(0.6)
            await take.move(toTarget: "Play voice \(jose)", 0.6)
            await take.click { speakers.player.stop() }
            await take.move(to: take.at(CGPoint(x: 230, y: Spot.voice(jose).y + 60)), 0.7)
            await take.pause(2.2)
        })

    /// ··· → Free Up Space…, the recordings over three months old, one kept
    /// by its lock, and the rest's audio gone in one confirmed click, with
    /// Undo. Their transcripts and names stay.
    static let space = Journey(
        name: "space", size: CGSize(width: 420, height: 620),
        setUp: { take in
            seedOldMeetings(take.root)
            // Removed audio goes to a trash in the film's own home, gone with it.
            Settings.store.set(
                take.root.deletingLastPathComponent().appendingPathComponent("Trash").path, forKey: "fixtureTrash")
            take.model.reload()
        },
        script: { take in
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.5)
            await take.pickFromMore("Free Up Space…") { take.model.openFreeUpSpace() }
            await take.pause(1.1)
            await take.move(toTarget: "Over 3 months", 0.7)
            await take.click(target: "Over 3 months")
            await take.pause(1.3)
            // An interview to listen to again: its lock keeps the audio.
            if let kept = take.model.spaceCandidates.first(where: { $0.title == "User interview" }) {
                let lock = "keep " + RecordingLibrary.stamp(of: kept.folder)
                await take.move(toTarget: lock, 0.8)
                await take.pause(0.2)
                await take.click(target: lock)
                await take.pause(1.5)
            }
            await take.move(toTarget: "Remove audio from ready", 0.8)
            await take.click(target: "Remove audio from ready")
            await take.pause(2.0)
            await take.move(toTarget: "Confirm remove audio", 0.6)
            await take.click(target: "Confirm remove audio")
            await take.pause(0.3)
            await take.move(to: take.at(CGPoint(x: 200, y: 420)), 0.8)
            await take.pause(2.6)
        })

    /// Opens on the Import window beside the Finder, so the first frame says
    /// what it is: drag old recordings in, import them, and find them among
    /// the others in Recent.
    static let importing = Journey(
        name: "import", size: CGSize(width: 720, height: 520),
        setUp: { take in
            let folder = take.root.deletingLastPathComponent().appendingPathComponent("Old recordings")
            // Four spoken files, the copy of one left out.
            take.files = Array(ImportGallery.makeFiles(in: folder).prefix(4))
            take.director.finder = take.files.map(\.lastPathComponent)
            take.director.cursor = CGPoint(x: 360, y: 420)
            take.director.importing = Imports(model: take.model)
        },
        script: { take in
            guard let imports = take.director.importing else { return }
            imports.close = { withAnimation(.easeOut(duration: 0.15)) { take.director.importing = nil } }
            await take.pause(1.0)
            await take.move(to: take.finderRow(0), 0.8)
            await take.click { take.director.selected = true }
            await take.pause(0.3)
            withAnimation(.easeOut(duration: 0.08)) { take.director.pressing = true }
            take.director.dragging = take.director.finder
            await take.move(to: take.inImport(ImportView.width / 2, 150), 1.0)
            take.director.dragging = nil
            imports.add(take.files)
            withAnimation(.easeOut(duration: 0.12)) {
                take.director.pressing = false
                take.director.selected = false
            }
            while imports.items.count < take.files.count || imports.reading { await take.pause(0.1) }
            await take.pause(1.4)
            await take.move(to: take.importButton, 0.8)
            await take.click(imports.start)
            while imports.importing { await take.pause(0.1) }
            await take.move(to: CGPoint(x: 610, y: 470), 0.6)
            await transcribe(imports, in: take)
            await take.pause(1.6)
            await take.move(to: take.importButton, 0.6)
            await take.click(imports.close)
            await take.pause(0.4)
            await take.openPanel()
            await take.move(to: CGPoint(x: 360, y: 470), 0.8)
            await take.pause(2.4)
        })

    /// The Import window alone as its recordings are transcribed, for the
    /// README's section on importing: the film at the top shows the rest.
    static let importProgress = Journey(
        name: "import-progress", size: CGSize(width: 528, height: 540),
        setUp: { take in
            let folder = take.root.deletingLastPathComponent().appendingPathComponent("Old recordings")
            take.files = Array(ImportGallery.makeFiles(in: folder).prefix(4))
            take.director.cursor = CGPoint(x: 470, y: 500)
            take.director.importing = Imports(model: take.model)
        },
        script: { take in
            guard let imports = take.director.importing else { return }
            imports.add(take.files)
            while imports.items.count < take.files.count || imports.reading { await take.pause(0.1) }
            imports.start()
            while imports.importing { await take.pause(0.1) }
            await take.pause(0.6)
            await transcribe(imports, in: take)
            await take.pause(2.0)
        })

    /// The film's transcripts, one file at a time as the app makes them: the
    /// ring fills, the quote follows the lines spoken, the estimate counts
    /// down, speakers are found, and the check comes. The first is shown at
    /// length; the rest go quicker.
    @MainActor
    private static func transcribe(_ imports: Imports, in take: Take) async {
        let model = take.model
        for (index, item) in imports.items.filter({ $0.state == .copied }).enumerated() {
            guard let stamp = item.stamp else { continue }
            let spoken = ImportGallery.spoken.first { $0.name == item.url.lastPathComponent }?.lines.map(\.text) ?? []
            let (seconds, pace): (Double, Double) = index == 0 ? (3.4, 100) : (1.0, 20)
            let steps = Int(seconds / 0.2)
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                let heard = spoken.isEmpty ? nil : spoken[min(Int(fraction * Double(spoken.count)), spoken.count - 1)]
                // As if this much had taken `pace` seconds a file.
                let first = (0.0, Date.now.addingTimeInterval(-fraction * pace))
                withAnimation(.easeOut(duration: 0.2)) {
                    model.transcription.stage(
                        current: stamp, progress: .init(fraction: fraction * 0.98, line: heard, first: first))
                }
                await take.pause(0.2)
            }
            guard let folder = model.importedEntry(stamp)?.folder else { continue }
            let lines = spoken.enumerated().map {
                TranscriptLine(start: Double($0.offset) * 4, end: Double($0.offset) * 4 + 3.5, text: $0.element)
            }
            try? TranscriptDocument.save(
                lines: lines, failures: 0, pieces: lines.count, model: model.transcription.model, in: folder)
            withAnimation(.easeOut(duration: 0.2)) {
                model.transcription.stage(current: nil, progress: nil)
                model.speakers.stage(stamp, work: .listening)
                model.reload()
            }
            await take.pause(index == 0 ? 0.8 : 0.4)
            let voices = Set(
                ImportGallery.spoken.first { $0.name == item.url.lastPathComponent }?.lines.map(\.voice) ?? [])
            let result = SpeakerResult(
                count: voices.count, estimated: true,
                voices: (1...max(voices.count, 1)).map { Voice(id: $0, seconds: 4, quote: spoken.first ?? "") },
                assigned: lines.map { _ in 1 })
            try? SpeakerLabels.save(result, lines: lines, in: folder)
            withAnimation(.easeOut(duration: 0.2)) { model.speakers.stage(stamp, work: nil) }
            await take.pause(0.25)
        }
    }

    /// Show all under Recent, the No transcript chip and its action, then a
    /// search that finds a word said in the meetings.
    static let allRecordings = Journey(
        name: "all-recordings", size: CGSize(width: 420, height: 640),
        setUp: { take in
            // A few months of meetings beside the usual recent ones.
            RecordingsGallery.seed(take.root)
            take.model.reload()
            // Starts near the menu-bar item, so the film opens on the panel.
            take.director.cursor = CGPoint(x: take.item.x - 40, y: take.item.y + 70)
        },
        script: { take in
            let model = take.model
            await take.openPanel()
            await take.pause(0.5)
            await take.move(toTarget: "Show all", 0.7)
            await take.click { model.openAllRecordings() }
            model.transcriptIndex.load(model.allEntries)
            await take.pause(1.6)
            // Chips are clicked past their count, clear of the label.
            await take.move(toTarget: "No transcript", at: 0.985, 0.7)
            await take.click { model.recordingsFilter.noTranscript = true }
            await take.pause(1.0)
            await take.move(toTarget: "Transcribe all", at: 0.12, 0.6)
            let waiting = model.allEntries.filter(RecordingSearch.needsTranscript)
            await take.click { model.makeTranscripts(waiting) }
            // The first one's ring fills; the rest wait their turn.
            if let first = waiting.first {
                let stamp = RecordingLibrary.stamp(of: first.folder)
                for step in 1...12 {
                    let fraction = Double(step) / 14
                    withAnimation(.easeOut(duration: 0.2)) {
                        model.transcription.stage(
                            current: stamp,
                            progress: .init(
                                fraction: fraction, line: nil, first: (0, Date().addingTimeInterval(-fraction * 90))))
                    }
                    await take.pause(0.2)
                }
            }
            await take.move(toTarget: "No transcript", at: 0.985, 0.6)
            await take.click { model.recordingsFilter.noTranscript = false }
            await take.pause(2.0)
            await take.move(toTarget: "Search", 0.6)
            await take.click()
            await take.type("thursday", into: "Titles, names, transcripts")
            await take.pause(2.2)
            take.resignKeyboard()
            await take.move(to: CGPoint(x: 200, y: 610), 0.8)
            await take.pause(1.6)
        })

    /// Not for the README: holds each page for a second and prints when,
    /// so `Spot` can be measured from the movie.
    static let probe = Journey(name: "probe", size: CGSize(width: 420, height: 640)) { take in
        let began = Date()
        func mark(_ what: String) async {
            await take.pause(0.6)
            print(String(format: "%.2f %@", Date().timeIntervalSince(began) + 0.4, what))
            await take.pause(0.6)
        }
        take.hideNewest()
        await take.openPanel()
        await mark("idle")
        take.startRecording(from: 0) { _ in [said[0], said[1]] }
        await mark("recording")
        await take.stopRecording(title: nil)
        await mark("card")
        take.model.closeCard()
        take.model.openFreeUpSpace()
        await mark("space")
        take.model.closeFreeUpSpace()
        if let entry = take.model.recent.first(where: { $0.title == nil }) {
            writeVoices(in: entry.folder)
            take.model.card = .init(entry: entry, finishing: false, justRecorded: false)
            take.model.labelSpeakers()
        }
        await mark("voices")
    }

    /// Who said each sample line: Priya, Sam (the microphone), José, Ana.
    static let voiceOfLine = [0, 1, 0, 2, 0, 3, 1, 0, 1, 0, 3, 1, 0, 2]

    /// A voice print as the speaker model writes one, unit length, its own
    /// direction for each voice; `near` tips it a little toward another.
    static func voicePrint(_ voice: Int, near other: Int? = nil) -> [Float] {
        var print = [Float](repeating: 0, count: VoiceStore.dimensions)
        print[voice] = 1
        if let other { print[other] = 0.45 }
        let length = sqrt(print.reduce(0) { $0 + $1 * $1 })
        return print.map { $0 / length }
    }

    /// Voices for the sample call as the speaker model would leave them,
    /// so Label speakers finds them at once. Each turn runs half a second
    /// past its line, as the model hears a speaker's breath; that gives
    /// Priya the half minute a remembered voice needs to be filled in, and
    /// Sam, on the microphone, less, so only she is. Her print is close to
    /// the one remembered from the design review, not the same.
    static func writeVoices(in folder: URL) {
        guard let lines = TranscriptDocument.lines(in: folder) else { return }
        let turns = lines.enumerated().map { index, line in
            VoiceTurn(start: line.start - 0.5, end: line.end + 0.5, voice: voiceOfLine[index % voiceOfLine.count])
        }
        var prints: [Int: [Float]] = [:]
        for voice in 0..<4 { prints[voice] = voicePrint(voice, near: voice == 0 ? 8 : nil) }
        try? VoicePrints(turns: turns, prints: prints).save(in: folder)
    }

    /// Yesterday's design review, labeled, with Priya's voice named by hand:
    /// the voice store learns her the way it does in use.
    static func namePriya(in folder: URL) {
        let said = [
            (0, 11.0, "Let's start with the onboarding screens, the second one first."),
            (1, 6.0, "It still feels crowded to me."),
            (0, 10.0, "Agreed. We could move the import step to the very end."),
            (1, 7.0, "Then the first run is only the record button."),
            (0, 9.0, "Good. Mei, can you mock that up for Thursday?"),
            (0, 8.0, "And keep the settings out of the first run entirely."),
        ]
        var start = 3.0
        var lines: [TranscriptLine] = []
        var turns: [VoiceTurn] = []
        for (voice, length, text) in said {
            lines.append(TranscriptLine(start: start, end: start + length, text: text))
            turns.append(VoiceTurn(start: start, end: start + length, voice: voice))
            start += length + 1.5
        }
        let heard = VoicePrints(turns: turns, prints: [0: voicePrint(0), 1: voicePrint(5)])
        try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
        try? heard.save(in: folder)
        guard let result = try? SpeakerLabels.relabel(heard, count: nil, in: folder), let priya = result.assigned[0]
        else { return }
        let root = folder.deletingLastPathComponent().deletingLastPathComponent()
        _ = try? VoiceLibrary(root: root).name(priya, "Priya Shah", in: folder)
    }

    /// Meetings from the last six months beside the recent ones, as Free up
    /// space finds them: most transcribed with every voice named, two never
    /// transcribed. Each audio file is as long on disk as its meeting would
    /// be at 128 kbps, and holds nothing.
    static func seedOldMeetings(_ root: URL) {
        let library = RecordingLibrary(root: root)
        let meetings: [(days: Double, minutes: Double, title: String, people: [String], transcribed: Bool)] = [
            (38, 46, "Weekly with Ana", ["Ana"], true),
            (61, 52, "Design critique", ["Mei", "Priya Shah"], true),
            (75, 31, "Budget planning", ["Priya Shah", "Nora Quinn"], true),
            (97, 42, "Pilot debrief", ["José Ortiz", "Ana"], true),
            (109, 58, "User interview", ["Mei"], true),
            (138, 74, "Quarterly review", ["Priya Shah", "José Ortiz", "Ana"], true),
            (152, 27, "Survey kickoff", ["Nora Quinn"], false),
            (166, 49, "1:1 with Priya", ["Priya Shah"], true),
            (181, 63, "Site check-in", ["José Ortiz", "Mei"], false),
        ]
        let said = [
            "Let's go through what we learned first.", "The second site had the most trouble with setup.",
            "I'll write that up by Friday.", "Can we keep the same questions next round?",
            "That leaves the budget for one more visit.", "Send me the notes and I'll take a pass.",
        ]
        for (index, meeting) in meetings.enumerated() {
            let started = Date().addingTimeInterval(-meeting.days * 86_400 - Double(index % 4) * 3600)
            guard let folder = try? library.newFolder(at: started) else { continue }
            let meta: [String: Any] = [
                "status": "recorded", "audio": "audio.m4a", "duration_seconds": meeting.minutes * 60,
                "started": ISO8601DateFormatter().string(from: started),
            ]
            try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
            FileManager.default.createFile(atPath: folder.appendingPathComponent("audio.m4a").path, contents: nil)
            try? RecordingLibrary.save(
                people: .init(count: meeting.people.count + 1, names: meeting.people), in: folder)
            if meeting.transcribed {
                let lines = (0..<6).map { line in
                    TranscriptLine(
                        start: Double(line) * 30, end: Double(line) * 30 + 12, text: said[(index + line) % said.count])
                }
                try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
                // Sam and everyone there, each voice named.
                let names = ["Sam"] + meeting.people
                let assigned: [Int?] = lines.indices.map { $0 % names.count + 1 }
                var result = SpeakerResult(
                    count: names.count, estimated: false,
                    voices: SpeakerLabels.voices(lines: lines, assigned: assigned), assigned: assigned)
                result.names = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.offset + 1, $0.element) })
                try? SpeakerLabels.save(result, lines: lines, in: folder)
            }
            _ = try? RecordingLibrary.save(title: meeting.title, in: folder)
        }
        for entry in library.entries() {
            guard let handle = try? FileHandle(forWritingTo: entry.audio) else { continue }
            try? handle.truncate(atOffset: UInt64(entry.duration * 16_000))
            try? handle.close()
        }
    }
}
