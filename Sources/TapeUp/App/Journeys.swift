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
    static func count(_ number: Int) -> CGPoint { CGPoint(x: 26 + CGFloat(number - 1) * 32, y: 161) }
    static let names = CGPoint(x: 156, y: 197)
    static let copyPath = CGPoint(x: 72, y: 80)
    static let close = CGPoint(x: 18, y: 32)
    static let labelSpeakers = CGPoint(x: 55, y: 268)
    static func voice(_ number: Int) -> CGPoint { CGPoint(x: 45, y: 290 + CGFloat(number - 1) * 43) }
    static let claudeCode = CGPoint(x: 79, y: 210)
    static let addPerson = CGPoint(x: 80, y: 62)
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
        record, floating, whoWasThere, handoff, people, settings, speakers, importing, probe,
    ]

    static var said: [String] { Shots.said.map(\.1) }

    /// Open, turn on the microphone and the transcript, record, watch the
    /// words come, stop: saved, then titled. Computer audio stays on, since
    /// one source always is.
    static let record = Journey(
        name: "record", size: CGSize(width: 420, height: 470),
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

    /// In a call in another app: ⌥⌘R, then pause, resume and stop from the
    /// floating controls; the saved recording drops from the menu bar.
    static let floating = Journey(
        name: "floating", size: CGSize(width: 640, height: 470),
        setUp: { take in
            take.hideNewest()
            take.director.call = true
            take.director.cursor = CGPoint(x: 300, y: 330)
        },
        script: { take in
            await take.pause(0.5)
            withAnimation(.easeOut(duration: 0.12)) { take.director.keys = "⌥ ⌘ R" }
            await take.pause(0.25)
            take.startRecording(from: 0) { _ in [said[0]] }
            withAnimation(.easeOut(duration: 0.25)) { take.director.pill = true }
            await take.pause(0.6)
            withAnimation(.easeOut(duration: 0.3)) { take.director.keys = nil }
            await take.pause(2.0)
            await take.move(to: take.pauseButton, 0.8)
            await take.click { take.paused = true }
            await take.pause(1.4)
            await take.click { take.paused = false }
            await take.pause(1.6)
            await take.move(to: take.stopButton, 0.4)
            await take.click()
            withAnimation(.easeOut(duration: 0.15)) { take.director.pill = false }
            await take.stopRecording(title: "Beta launch plan", showPanel: true)
            await take.move(to: CGPoint(x: 200, y: 400), 0.8)
            await take.pause(2.2)
        })

    /// Stop a long call, then say how many were there and who.
    static let whoWasThere = Journey(
        name: "who-was-there", size: CGSize(width: 420, height: 470),
        setUp: { take in
            take.hideNewest()
            take.startRecording(from: 1912) { _ in [said[12], said[13]] }
        },
        script: { take in
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.6)
            await take.move(toPanel: Spot.record, 0.6)
            await take.click()
            await take.stopRecording(title: "Beta launch plan")
            await take.pause(0.3)
            await take.move(toPanel: Spot.count(4), 0.6)
            await take.click {
                guard var people = take.model.card?.entry.people else { return }
                people.count = 4
                take.model.setPeople(people)
            }
            await take.move(toPanel: Spot.names, 0.5)
            await take.click()
            for (index, prefix) in ["pr", "jo", "an"].enumerated() {
                await take.type(prefix, into: index == 0 ? "Participant names" : nil, perCharacter: 0.12)
                await take.pause(0.45)
                take.pressReturn()
                await take.pause(0.4)
            }
            take.resignKeyboard()
            await take.move(to: CGPoint(x: 250, y: 380), 0.8)
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

    /// ··· → People…, then add someone.
    static let people = Journey(name: "people", size: CGSize(width: 420, height: 480)) { take in
        await take.pause(0.15)
        await take.openPanel()
        await take.pause(0.5)
        await take.pickFromMore("People…") { take.model.openPeople() }
        await take.pause(0.6)
        await take.move(toPanel: Spot.addPerson, 0.6)
        await take.click()
        await take.type("Nora Quinn", into: "Add a person")
        await take.pause(0.3)
        await take.type("sales", into: "Note")
        await take.pause(0.4)
        take.pressReturn()
        take.resignKeyboard()
        await take.move(to: CGPoint(x: 250, y: 380), 0.8)
        await take.pause(2.2)
    }

    /// ··· → Settings…, then turn on Claude Code.
    static let settings = Journey(name: "settings", size: CGSize(width: 420, height: 480)) { take in
        await take.pause(0.15)
        await take.openPanel()
        await take.pause(0.5)
        await take.pickFromMore("Settings…") { take.model.openSettings() }
        await take.pause(0.7)
        await take.move(toPanel: Spot.claudeCode, 0.7)
        await take.click { take.model.agents.choose(.claude) }
        await take.move(to: CGPoint(x: 250, y: 340), 0.8)
        await take.pause(2.2)
    }

    /// Open a recording, label its speakers, and name two voices.
    static let speakers = Journey(
        name: "speakers", size: CGSize(width: 420, height: 580),
        setUp: { take in
            if let entry = take.model.recent.first(where: { $0.title == nil }) {
                writeVoices(in: entry.folder)
                _ = try? RecordingLibrary.save(title: "Beta launch plan", in: entry.folder)
            }
            take.model.reload()
        },
        script: { take in
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.5)
            await take.move(toPanel: Spot.firstRow, 0.6)
            await take.click {
                guard let entry = take.model.recent.first else { return }
                take.model.card = .init(entry: entry, finishing: false, justRecorded: false)
            }
            await take.pause(0.6)
            await take.move(toPanel: Spot.labelSpeakers, 0.6)
            await take.click { take.model.labelSpeakers() }
            await take.pause(0.9)
            for (voice, name) in [(1, "Priya Shah"), (4, "José Ortiz")] {
                guard let entry = take.model.card?.entry else { break }
                let others = take.model.suggestions(matching: "", excluding: entry.people.names, limit: 12)
                let items = entry.people.names + (others.isEmpty ? [] : ["-"] + others)
                await take.pick(name, from: take.at(Spot.voice(voice)), items: items) {
                    take.model.speakers.name(voice, name, in: entry)
                }
                await take.pause(0.5)
            }
            await take.move(to: CGPoint(x: 250, y: 540), 0.8)
            await take.pause(2.2)
        })

    /// ··· → Import…, drag old recordings in from Finder, import them, and
    /// find them among the others in Recent.
    static let importing = Journey(
        name: "import", size: CGSize(width: 720, height: 640),
        setUp: { take in
            let folder = take.root.deletingLastPathComponent().appendingPathComponent("Old recordings")
            // Four spoken files, the copy of one left out.
            take.files = Array(ImportGallery.makeFiles(in: folder).prefix(4))
            take.director.finder = take.files.map(\.lastPathComponent)
            take.director.cursor = CGPoint(x: 360, y: 420)
        },
        script: { take in
            let imports = Imports(model: take.model)
            imports.close = { withAnimation(.easeOut(duration: 0.15)) { take.director.importing = nil } }
            await take.pause(0.15)
            await take.openPanel()
            await take.pause(0.5)
            await take.pickFromMore("Import…") {
                withAnimation(.easeOut(duration: 0.15)) {
                    take.director.panelOpen = false
                    take.director.itemPressed = false
                    take.director.importing = imports
                }
            }
            await take.pause(0.7)
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
            await take.move(to: CGPoint(x: 610, y: 560), 0.6)
            await transcribe(imports, in: take)
            await take.pause(1.6)
            await take.move(to: take.importButton, 0.6)
            await take.click(imports.close)
            await take.pause(0.4)
            await take.openPanel()
            await take.move(to: CGPoint(x: 360, y: 560), 0.8)
            await take.pause(2.4)
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
        take.model.openPeople()
        await mark("people")
        take.model.closePeople()
        take.model.openSettings()
        await mark("settings")
        take.model.closeSettings()
        if let entry = take.model.recent.first(where: { $0.title == nil }) {
            writeVoices(in: entry.folder)
            take.model.card = .init(entry: entry, finishing: false, justRecorded: false)
            take.model.labelSpeakers()
        }
        await mark("voices")
    }

    /// Who said each sample line: Priya, Sam (the microphone), José, Ana.
    static let voiceOfLine = [0, 1, 0, 2, 0, 3, 1, 0, 1, 0, 3, 1, 0, 2]

    /// Voices for the sample call as the speaker model would leave them,
    /// so Label speakers finds them at once.
    static func writeVoices(in folder: URL) {
        guard let lines = TranscriptDocument.lines(in: folder) else { return }
        let turns = lines.enumerated().map { index, line in
            VoiceTurn(start: line.start, end: line.end, voice: voiceOfLine[index % voiceOfLine.count])
        }
        var prints: [Int: [Float]] = [:]
        for voice in 0..<4 { prints[voice] = (0..<8).map { $0 == voice ? 1 : 0 } }
        try? VoicePrints(turns: turns, prints: prints).save(in: folder)
    }
}
