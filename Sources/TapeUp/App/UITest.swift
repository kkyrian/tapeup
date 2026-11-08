import AVFoundation
import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp uitest --out <dir> [--record]`: drives the real panel, the real
/// window and the real model through the flows a person uses, and after each
/// step checks that the window is exactly as tall as its content and that its
/// top stays put. With `--record` it also records, pauses, resumes and stops
/// for real (run it from the app bundle, which holds the permissions).
/// Saves a picture of every step and exits non-zero on any failure.
@MainActor
enum UITest {
    private static let keys = [
        "recordingsRoot", "recordMicrophone", "recordComputer", "floatingControls", "floatingControlsOrigin",
        "transcribe",
    ]

    private static func textField(placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for child in view.subviews {
            if let found = textField(placeholder: placeholder, in: child) { return found }
        }
        return nil
    }

    /// Silent stereo AAC, standing in for a recording's audio.
    private static func writeSilence(seconds: Int, to url: URL) {
        let rate = 16_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)),
            let file = try? AVAudioFile(
                forWriting: url,
                settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2])
        else { return }
        buffer.frameLength = buffer.frameCapacity
        for _ in 0..<seconds { try? file.write(from: buffer) }
    }

    static func run(out: String, record: Bool, agent: AgentKind? = nil) {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-uitest-\(UUID().uuidString)")
        let root = base.appendingPathComponent("recordings")
        Snapshot.seed(root)
        defaults.set(root.path, forKey: "recordingsRoot")
        for key in keys.dropFirst() { defaults.removeObject(forKey: key) }

        EditMenu.install()
        let model = AppModel()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "UITest"
        let panel = PanelController(model: model, anchor: item.button!)
        let floating = FloatingControls(model: model) {
            model.stop()
            if !panel.isVisible { panel.show(takingFocus: false) }
        }
        var failures: [String] = []
        var step = 0
        var top: CGFloat?

        func settle(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func expect(_ ok: Bool, _ what: String) {
            if !ok { failures.append("step \(step): \(what)") }
            print(ok ? "  ok  \(what)" : "  FAIL \(what)")
        }

        func check(_ name: String) {
            step += 1
            settle()
            for _ in 0..<40 where panel.isResizing { settle(0.05) }
            floating.update()
            print(String(format: "%02d %@", step, name))
            let window = panel.window
            guard window.isVisible else { return expect(false, "panel is visible") }
            let natural = naturalHeight(model: model)
            expect(
                abs(window.frame.height - natural) <= 1,
                "window height \(Int(window.frame.height)) matches content \(Int(natural))")
            if let content = window.contentView, let host = content.subviews.first {
                expect(
                    host.frame == content.bounds,
                    "content fills the window exactly (host \(host.frame), window \(content.bounds))")
            }
            expect(
                abs(PanelView.laidOutHeight - window.frame.height) <= 1,
                "SwiftUI lays out at the window height (\(Int(PanelView.laidOutHeight)))")
            if let top { expect(abs(window.frame.maxY - top) <= 1, "top edge stays put") }
            top = window.frame.maxY
            if floating.window.isVisible {
                let pill = Process()
                pill.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                pill.arguments = [
                    "-x", "-o", "-l\(floating.window.windowNumber)",
                    outURL.appendingPathComponent(String(format: "%02d-%@-floating.png", step, name)).path,
                ]
                try? pill.run()
                pill.waitUntilExit()
            }
            roundedOnScreen(
                window, file: outURL.appendingPathComponent(String(format: "%02d-%@-shadow.png", step, name)),
                expect: expect)
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = [
                "-x", "-o", "-l\(window.windowNumber)",
                outURL.appendingPathComponent(String(format: "%02d-%@-screen.png", step, name)).path,
            ]
            try? shot.run()
            shot.waitUntilExit()
            let shotURL = outURL.appendingPathComponent(String(format: "%02d-%@-screen.png", step, name))
            if let data = try? Data(contentsOf: shotURL), let image = NSBitmapImageRep(data: data) {
                // What is really on screen: the panel's edges must be painted,
                // not left see-through by a stale layout.
                let x = image.pixelsWide / 2
                let edges = [2, image.pixelsHigh / 2, image.pixelsHigh - 3]
                let clear = edges.filter { (image.colorAt(x: x, y: $0)?.alphaComponent ?? 0) < 0.5 }
                expect(clear.isEmpty, "panel painted at top, middle and bottom on screen")
            }
            if let content = window.contentView,
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: outURL.appendingPathComponent(String(format: "%02d-%@.png", step, name)))
            }
        }

        panel.show()
        check("idle")
        let idleHeight = panel.window.frame.height
        model.openPeople()
        check("people")
        let seeded = model.peopleList
        // ⌘V the way a person pastes a name copied from an email, through
        // the key equivalent, not by setting the text.
        if let field = textField(placeholder: "Add a person", in: panel.window.contentView) {
            let board = NSPasteboard.general
            let kept = board.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            board.clearContents()
            board.setString("Priya Shah", forType: .string)
            panel.window.makeFirstResponder(field)
            settle(0.2)
            let paste = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: panel.window.windowNumber, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
            expect(NSApp.mainMenu?.performKeyEquivalent(with: paste!) == true, "⌘V reaches the text field")
            settle(0.2)
            let locked = NSApp.keyWindow == nil ? ": no window has the keyboard; is the screen locked?" : ""
            expect(
                field.stringValue == "Priya Shah", "a pasted name lands in Add a person (\(field.stringValue))\(locked)"
            )
            field.stringValue = ""
            panel.window.makeFirstResponder(nil)
            board.clearContents()
            for item in kept ?? [] {
                let restored = NSPasteboardItem()
                for (type, data) in item { restored.setData(data, forType: type) }
                board.writeObjects([restored])
            }
        } else {
            expect(false, "the Add a person field is on the page")
        }
        expect(model.addPerson("Nora Quinn", note: "advisor"), "a person is added by hand")
        expect(!model.addPerson("nora quinn", note: nil), "a listed name is refused")
        expect(model.peopleNotice == .taken("nora quinn"), "and the page says so")
        expect(model.updatePerson("Nora Quinn", to: "Nora Quinn-Lee", note: "lab"), "a person is edited in place")
        if let you = seeded.you {
            expect(!model.updatePerson("Nora Quinn-Lee", to: you, note: nil), "no one can take the user's name")
        }
        check("people-edited")
        expect(
            model.peopleList.people.last == .init(name: "Nora Quinn-Lee", context: "lab"),
            "people.json holds the edit (\(model.peopleList.people.last.map(\.name) ?? "none"))")
        model.removePerson("Nora Quinn-Lee")
        expect(model.peopleList == seeded, "removing them leaves the list as it was")
        model.closePeople()
        check("people-back")
        model.openSettings()
        check("settings")
        model.closeSettings()
        check("settings-back")
        expect(abs(panel.window.frame.height - idleHeight) <= 1, "back from Settings at the same height")
        expect(abs(panel.window.frame.height - idleHeight) <= 1, "back to the same height as before")

        model.toggleTesting()
        check("checking-levels")
        model.toggleTesting()
        check("checking-off")

        model.toggleMicrophone()
        check("mic-off")
        expect(!model.microphoneOn, "mic is off")
        model.toggleComputer()
        expect(model.computerOn, "the last source on cannot be turned off")
        model.toggleMicrophone()
        check("mic-on")

        model.transcription.toggle()
        check("transcript-off")
        expect(!model.transcription.enabled && model.transcription.status == "Off", "transcript row says Off")
        model.transcription.toggle()
        check("transcript-on")
        expect(model.transcription.enabled, "transcripts back on")

        // An old recording with no audio: Transcribe, then the failure turns
        // the button into Try again.
        if let old = model.recent.last {
            model.open(old)
            check("card-no-transcript")
            expect(old.transcript == .none, "old recording has no transcript")
            model.makeTranscript(old)
            for _ in 0..<80 where model.card?.entry.transcript != .failed { settle(0.25) }
            check("card-transcript-failed")
            expect(model.card?.entry.transcript == .failed, "a recording with no audio fails and offers Try again")
            model.closeCard()
        }

        let entry = model.recent[1]
        model.open(entry)
        check("card")
        model.copy(entry)
        check("card-copied")
        model.setTitle("Lab sync renamed")
        check("card-renamed")
        let renamed = model.card?.entry.folder ?? entry.folder
        expect(RecordingLibrary.entry(at: renamed)?.title == "Lab sync renamed", "title saved to meta.json")
        expect(
            renamed.lastPathComponent.hasSuffix(" Lab sync renamed"), "folder renamed (\(renamed.lastPathComponent))")
        var people = entry.people
        people.names.append("Ana")
        model.setPeople(people)
        check("card-people")
        model.closeCard()
        check("card-back")
        expect(abs(panel.window.frame.height - idleHeight) <= 8, "list height close to before")

        // Speaker labels from voices already heard: the count sets how many,
        // without one the estimate is shown on its chip, names rewrite the file.
        if let labeled = model.recent.first(where: { VoicePrints.read(in: $0.folder) != nil }) {
            // A made title may rename the folder at any point; follow the card.
            func current() -> RecordingEntry { model.card?.entry ?? labeled }
            model.open(labeled)
            check("card-speakers-offered")
            expect(labeled.transcript == .done, "the seeded recording is transcribed")
            model.labelSpeakers()
            check("card-speakers-two")
            let two = model.speakers.result(for: current())
            expect(two?.voices.count == 2 && two?.estimated == false, "the count of 2 finds 2 voices")
            var people = labeled.people
            people.count = nil
            model.setPeople(people)
            check("card-speakers-estimated")
            let estimate = model.speakers.result(for: current())
            expect(estimate?.estimated == true && estimate?.voices.count == 3, "without a count, 3 voices estimated")
            model.speakers.name(1, "Priya Shah", in: current())
            check("card-speakers-named")
            let file = current().folder.appendingPathComponent(SpeakerLabels.fileName)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            expect(text.contains("Priya Shah: Thanks for making time"), "the name is in the labeled transcript")
            model.copyTranscript(current())
            expect(
                NSPasteboard.general.string(forType: .string)?.contains("Voice 2:") == true,
                "Copy transcript copies the labeled one")
            people.count = 3
            model.setPeople(people)
            check("card-speakers-same-count")
            expect(
                model.speakers.result(for: current())?.names[1] == "Priya Shah", "tapping the same number keeps names")
            // Play: a voice's turns back to back, its quote following the
            // line heard; another voice or a second click stops it, naming
            // keeps it going, and the row never moves. The seeded audio is
            // silence just long enough for the first two voices' first turns.
            let player = model.speakers.player
            if let result = model.speakers.result(for: current()), result.voices.count >= 2 {
                let (first, second) = (result.voices[0].id, result.voices[1].id)
                let lines = TranscriptDocument.lines(in: current().folder) ?? []
                let turns = SpeakerLabels.turns(
                    of: result, heard: VoicePrints.read(in: current().folder), lines: lines)
                let starts = [first, second].map { turns[$0]?.map(\.start).min() ?? 0 }
                writeSilence(seconds: Int(starts.max() ?? 0) + 10, to: current().audio)
                let opening = zip(lines, result.assigned).first { $0.1 == first }?.0.text
                player.toggle(first, in: current(), result: result)
                check("card-speakers-playing")
                let playingHeight = panel.window.frame.height
                expect(player.isPlaying(first, in: current()), "Play plays the voice")
                expect((player.playedSeconds() ?? 0) > 0.2, "its audio is heard (\(player.playedSeconds() ?? -1) s)")
                expect(
                    player.line != nil && player.line == opening,
                    "the quote is the line heard (\(player.line ?? "none"))")
                model.speakers.name(second, "Mei", in: current())
                settle(0.2)
                expect(player.isPlaying(first, in: current()), "naming a voice keeps it playing")
                player.toggle(second, in: current(), result: result)
                settle(0.3)
                expect(
                    player.isPlaying(second, in: current()) && !player.isPlaying(first, in: current()),
                    "playing another voice stops the first")
                player.toggle(second, in: current(), result: result)
                check("card-speakers-stopped")
                expect(player.playing == nil && player.line == nil, "clicking again stops")
                expect(panel.window.frame.height == playingHeight, "playing or stopped, the rows stay put")
                model.speakers.name(second, nil, in: current())
            } else {
                expect(false, "the seeded recording has two voices to play")
            }
            // A title made by the on-device model names the recording.
            if Titles.available {
                for _ in 0..<80 where model.card?.entry.title == nil { settle(0.25) }
                check("card-title-made")
                let title = model.card?.entry.title
                expect(title != nil, "the recording is named from its transcript (\(title ?? "none"))")
            }
            if let result = model.speakers.result(for: current()), let voice = result.voices.first {
                player.toggle(voice.id, in: current(), result: result)
                settle(0.2)
                expect(player.playing != nil, "a voice plays before the card closes")
            }
            model.closeCard()
            expect(player.playing == nil, "closing the card stops the voice")
        } else {
            expect(false, "a seeded recording has voices to label")
        }

        // The user's own agent, called for real (only with --agent): a title
        // through the fallback after a failing tuned call, then names said
        // aloud, suggested from the known people only.
        if let agent,
            let folder = try? RecordingLibrary(root: model.root).newFolder(at: Date().addingTimeInterval(-600))
        {
            model.agents.testing = agent
            model.agents.testingModel = "no-such-model"
            Snapshot.seedNamesSaidAloud(folder)
            model.reload()
            if let entry = model.recent.first(where: { $0.folder.lastPathComponent == folder.lastPathComponent }) {
                let began = Date()
                model.open(entry)
                for _ in 0..<600 where model.card?.entry.title == nil { settle(0.25) }
                let title = model.card?.entry.title
                expect(
                    title != nil,
                    "\(agent.name) names the recording after the tuned call fails (\(title ?? "none"), \(Int(Date().timeIntervalSince(began))) s)"
                )
                // Named, the recording's folder carries its title.
                let entry = model.card?.entry ?? entry
                model.agents.testingModel = nil
                let asked = Date()
                model.labelSpeakers()
                for _ in 0..<600 where model.speakers.result(for: entry)?.suggested.isEmpty != false { settle(0.25) }
                check("card-agent-names")
                let result = model.speakers.result(for: entry)
                let lines = TranscriptDocument.lines(in: entry.folder) ?? []
                func voice(saying text: String) -> Int? {
                    lines.firstIndex { $0.text == text }.flatMap { result?.assigned[$0] }
                }
                var expected: [Int: String] = [:]
                for (index, name) in ["Priya Shah", "José Ortiz", "Mei"].enumerated() {
                    if let voice = voice(saying: Snapshot.namesSaidAloud[index]) { expected[voice] = name }
                }
                expect(
                    result?.suggested == expected,
                    "\(agent.name) suggests each voice's name (\(result?.suggested ?? [:]), \(Int(Date().timeIntervalSince(asked))) s)"
                )
                expect(result?.names.isEmpty == true, "suggested names wait for the user")
                model.speakers.acceptSuggestedNames(in: entry)
                check("card-agent-names-used")
                expect(model.speakers.result(for: entry)?.names == expected, "Use names every voice")
                let events =
                    (try? String(contentsOf: entry.folder.appendingPathComponent("events.jsonl"), encoding: .utf8))
                    ?? ""
                expect(events.contains("\"by\":\"\(agent.rawValue)\""), "the title is logged as the agent's")
                expect(
                    events.components(separatedBy: "agent failed").count == 1,
                    "only the failing tuned call is retried, nothing logged (\(events.suffix(1500)))")
                model.closeCard()
            }
            // Signed out, or out of its weekly limit: nothing shows but a
            // dot on ···, the reason is logged, and the next recording tries again.
            let fake = base.appendingPathComponent("fake-agent")
            try? "#!/bin/sh\necho 'Weekly limit reached' >&2\nexit 1\n".write(
                to: fake, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            AgentRunner.testingBinary = fake
            if let other = try? RecordingLibrary(root: model.root).newFolder(at: Date().addingTimeInterval(-300)) {
                Snapshot.seedNamesSaidAloud(other)
                model.reload()
                if let entry = model.recent.first(where: { $0.folder.lastPathComponent == other.lastPathComponent }) {
                    model.open(entry)
                    model.labelSpeakers()
                    // The made title renames the folder; follow it by its stamp.
                    let stamp = RecordingLibrary.stamp(of: entry.folder)
                    func current() -> RecordingEntry {
                        RecordingLibrary(root: model.root).folder(withStamp: stamp).flatMap(RecordingLibrary.entry(at:))
                            ?? entry
                    }
                    func failures() -> Int {
                        let events = current().folder.appendingPathComponent("events.jsonl")
                        return ((try? String(contentsOf: events, encoding: .utf8)) ?? "").components(
                            separatedBy: "agent failed"
                        ).count - 1
                    }
                    for _ in 0..<120 where failures() < 2 { settle(0.25) }
                    model.closeCard()
                    check("list-agent-signed-out")
                    expect(failures() == 2, "a failing agent is logged once per suggestion (\(failures()))")
                    expect(
                        model.speakers.result(for: current())?.suggested.isEmpty == true, "and suggests no names")
                    expect(model.agents.needsAttention, "a signed-out agent puts a dot on ···")
                    expect(
                        model.agents.settingsTitle == "Settings… · \(agent.name) Signed Out",
                        "the Settings item says the agent is signed out")
                } else {
                    expect(false, "the second agent recording is listed (\(other.lastPathComponent))")
                }
            } else {
                expect(false, "a second agent recording can be made")
            }
            AgentRunner.testingBinary = nil
            model.agents.testing = nil
            model.agents.refreshNow()
        }

        // The command line, answered by this running model.
        let link = CommandLink.listen(model)
        func command(_ words: [String]) -> (status: Int32, out: String) {
            let process = Process()
            process.executableURL = Bundle.main.executableURL
            process.arguments = words + ["--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try? process.run()
            // A command that started a second app instead would never end.
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline { settle(0.1) }
            if process.isRunning { process.terminate() }
            return (
                process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
        if let target = model.recent.first(where: { $0.title == nil && $0.transcript == .none }) {
            let stamp = RecordingLibrary.stamp(of: target.folder)
            let named = command(["title", stamp, "Budget", "review"])
            expect(
                named.status == 0 && named.out.contains("Budget review"),
                "TapeUp title names a recording (\(named.out))")
            expect(
                model.recent.contains { $0.title == "Budget review" }, "the app's list shows the name at once")
            let speakers = command(["speakers", stamp])
            expect(
                speakers.status == 1 && speakers.out.contains("no_transcript"),
                "TapeUp speakers explains a missing transcript (\(speakers.out))")
            let transcribed = command(["transcribe", stamp])
            expect(
                transcribed.status == 1 && transcribed.out.contains("transcription_failed"),
                "TapeUp transcribe waits for the app and reports a recording with no audio (\(transcribed.out))")
            let missing = command(["title", "1999-01-01-0000", "x"])
            expect(
                missing.status == 1 && missing.out.contains("not_found"), "an unknown recording is named in the error")
            let folder = command(["folder"])
            expect(
                folder.out.replacingOccurrences(of: "\\/", with: "/").contains(model.root.path),
                "TapeUp folder shows this folder (\(folder.out))")
            for words in [["lists"], ["--version"], ["title", stamp]] {
                let wrong = command(words)
                expect(
                    wrong.status == 2 && wrong.out.contains("usage"),
                    "TapeUp \(words.joined(separator: " ")) is a usage error, not a second app (\(wrong.out))")
            }
            let home = model.root
            let away = home.deletingLastPathComponent().appendingPathComponent("moved-by-command")
            let moved = command(["folder", away.path, "--move"])
            expect(
                moved.status == 0 && model.root.standardizedFileURL == away.standardizedFileURL
                    && model.recent.contains { $0.title == "Budget review" },
                "TapeUp folder --move moves the recordings through the app (\(moved.out))")
            let back = command(["folder", home.path, "--move"])
            expect(
                back.status == 0 && model.root.standardizedFileURL == home.standardizedFileURL,
                "and back (\(back.out))")
        }
        DistributedNotificationCenter.default().removeObserver(link)

        let victim = model.recent[2]
        model.trash(victim)
        check("trashed")
        expect(!model.recent.contains { $0.folder == victim.folder }, "trashed recording left the list")
        model.undoTrash()
        check("undone")
        expect(model.recent.contains { $0.folder == victim.folder }, "undo put it back")

        importRecordings(model: model, base: base, out: outURL, expect: expect, settle: settle)

        panel.close()
        settle(0.3)
        panel.show()
        check("reopened")

        if record {
            let began = Date()
            // A busy main thread delays the start of a recording; the model
            // loading beside it must never cause one.
            let beats = Beats()
            let beat = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { beats.times.append(Date().timeIntervalSince(began)) }
            }
            model.start()
            settle(3)
            // Screenshots are the test's own main-thread work; leave them out.
            var shots: [ClosedRange<Double>] = []
            func timedCheck(_ name: String) {
                let from = Date().timeIntervalSince(began)
                check(name)
                shots.append(from...Date().timeIntervalSince(began))
            }
            timedCheck("recording")
            expect(model.isRecording, "recording started")
            if model.transcription.download == .ready {
                expect(model.transcription.liveRunning, "transcribing while recording")
            }
            expect(floating.window.isVisible, "floating controls show")
            let pausedAt = Date()
            model.togglePause()
            settle(2)
            timedCheck("paused")
            model.togglePause()
            let pausedFor = Date().timeIntervalSince(pausedAt)
            settle(2)
            let wall = Date().timeIntervalSince(began)
            beat.invalidate()
            let stalls = zip(beats.times, beats.times.dropFirst()).filter { gap in
                gap.1 - gap.0 > 0.25 && !shots.contains { $0.overlaps(gap.0...gap.1) }
            }
            expect(
                stalls.isEmpty,
                "main thread never stalls while recording \(stalls.map { String(format: "%.1fs at %.1fs", $1 - $0, $0) })"
            )
            model.stop()
            check("saving")
            for _ in 0..<40 where model.card?.finishing == true { settle(0.25) }
            check("saved")
            if model.transcription.download == .ready {
                for _ in 0..<120 where model.card?.entry.transcript != .done { settle(0.25) }
                check("saved-transcribed")
                let transcript = model.card?.entry.transcriptFile
                expect(model.card?.entry.transcript == .done, "transcript written after stop")
                expect(
                    transcript.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                    "transcript.md beside the audio")
                expect(
                    model.card?.entry.clipboardText.contains("\ntranscript: ") == true, "Copy path names the transcript"
                )
                // The speaker model, for real, inside the app.
                model.labelSpeakers()
                // A count tapped while voices are being found is the one used.
                if let card = model.card {
                    var people = card.entry.people
                    people.count = 2
                    model.setPeople(people)
                }
                for _ in 0..<240 where model.card.flatMap({ model.speakers.work(on: $0.entry) }) != nil { settle(0.25) }
                check("saved-speakers")
                expect(
                    model.card.flatMap { model.speakers.result(for: $0.entry) } != nil,
                    "speakers labeled on the recording just made")
                expect(
                    model.card.flatMap { model.speakers.result(for: $0.entry) }?.estimated == false,
                    "the count tapped while finding voices was used")
            }
            expect(!floating.window.isVisible, "floating controls hide after stop")
            if let saved = model.card?.entry, let meta = MetaFile.read(saved.folder) {
                let duration = meta["duration_seconds"] as? Double ?? 0
                let paused = meta["paused_seconds"] as? Double ?? 0
                print("  duration \(duration)s, paused \(paused)s")
                expect(abs(paused - pausedFor) < 0.3, "paused time recorded (\(paused)s of \(pausedFor)s)")
                // The file starts at the first audio, a little after the click.
                let expected = wall - pausedFor
                expect(
                    duration > expected - 1 && duration <= expected + 0.2,
                    "paused time left out of the audio (\(duration)s, expected about \(expected)s)")
                expect(
                    FileManager.default.fileExists(atPath: saved.audio.path), "audio.m4a exists")
            } else {
                expect(false, "saved recording has meta.json")
            }
            panel.close()
            settle(0.3)
            panel.show()
            check("reopened-after-recording")
            expect(model.card == nil, "reopening shows the list, not the old card")

            // Mac audio only, stopped while paused.
            model.toggleMicrophone()
            model.start()
            settle(2)
            check("recording-mac-only")
            model.togglePause()
            settle(0.5)
            model.stop()
            for _ in 0..<40 where model.card?.finishing != false { settle(0.25) }
            if let saved = model.card?.entry, let meta = MetaFile.read(saved.folder) {
                expect(
                    meta["sources"] as? [String] == ["computer audio"],
                    "only Mac audio recorded (\(meta["sources"] ?? "none"))")
                expect(saved.duration > 1, "stopping while paused keeps the audio (\(saved.duration)s)")
            } else {
                expect(false, "Mac-only recording saved")
            }
            model.toggleMicrophone()
            model.closeCard()
            check("after-mac-only")
        }

        let moved = base.appendingPathComponent("moved")
        let count = model.allEntries.count
        model.changeRoot(to: moved, moving: true)
        for _ in 0..<20 where model.root != moved { settle(0.2) }
        check("moved-folder")
        expect(model.allEntries.count == count, "all \(count) recordings moved")

        panel.close()
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: base)
        print(failures.isEmpty ? "PASS \(step) steps" : "FAILED\n" + failures.joined(separator: "\n"))
        exit(failures.isEmpty ? 0 : 1)
    }

    /// With its shadow, as it sits on screen: the panel's corners must be
    /// round, not a square of window behind them (a shadow taken from the
    /// window's rectangle showed white corners).
    private static func roundedOnScreen(_ window: NSWindow, file: URL, expect: (Bool, String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(window.windowNumber)", file.path]
        try? process.run()
        process.waitUntilExit()
        guard let data = try? Data(contentsOf: file), let image = NSBitmapImageRep(data: data) else {
            return expect(false, "the panel can be captured with its shadow")
        }
        // The opaque body's bounds. Just inside its corner, outside the
        // rounding, the shadow must fall as it does along an edge; a shadow
        // cut from the window's rectangle leaves that spot see-through.
        func alpha(_ x: Int, _ y: Int) -> CGFloat { image.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        let middleX = image.pixelsWide / 2
        let middleY = image.pixelsHigh / 2
        let rows = (0..<image.pixelsHigh).filter { alpha(middleX, $0) > 0.99 }
        let columns = (0..<image.pixelsWide).filter { alpha($0, middleY) > 0.99 }
        guard let top = rows.first, let left = columns.first, left > 2 else {
            return expect(false, "the panel body is found in its shadow capture")
        }
        let edge = alpha(left - 2, middleY)
        let corner = alpha(left + 2, top + 2)
        expect(
            corner > edge / 10,
            String(format: "the shadow is round at the corners (corner %.2f, edge %.2f)", corner, edge))
    }

    /// Import: a mono phone memo, the same file again, and a text file are
    /// dropped; only the memo comes in, as 48 kHz stereo named after itself,
    /// and dropping it once more marks it already in TapeUp.
    private static func importRecordings(
        model: AppModel, base: URL, out: URL, expect: (Bool, String) -> Void, settle: (Double) -> Void
    ) {
        let files = base.appendingPathComponent("to-import")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let memo = files.appendingPathComponent("Interview with Mei.wav")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3),
            let file = try? AVAudioFile(forWriting: memo, settings: format.settings)
        {
            buffer.frameLength = 44_100 * 3
            for index in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData?[0][index] = 0.3 * sin(Float(index) * 2 * .pi * 330 / 44_100)
            }
            try? file.write(from: buffer)
        }
        let twin = files.appendingPathComponent("Interview with Mei copy.wav")
        try? FileManager.default.copyItem(at: memo, to: twin)
        try? "notes".write(to: files.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let window = ImportWindow(model: model)
        let imports = window.imports
        func shot(_ name: String) {
            settle(0.6)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l\(window.window.windowNumber)", out.appendingPathComponent(name).path]
            try? process.run()
            process.waitUntilExit()
        }
        func waitWhile(_ busy: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while busy() && Date() < deadline { settle(0.1) }
        }
        window.show()
        shot("import-empty.png")
        expect(
            window.window.firstResponder === window.window,
            "nothing is focused when the window opens (\(String(describing: window.window.firstResponder)))")
        window.show(adding: [files])
        waitWhile { imports.items.count < 2 || imports.reading }
        expect(imports.items.count == 2, "a dropped folder lists its two audio files, not the text file")
        expect(imports.ready.count == 1, "the copy of the same file is marked a duplicate")
        expect(imports.items.last?.state == .duplicate, "the second, identical file is the duplicate")
        if let first = imports.items.first {
            imports.rename(first, to: "  Mei, first interview ")
            expect(imports.items.first?.shownName == "Mei, first interview", "a file is renamed before import")
        }
        shot("import-list.png")
        imports.transcribe = false
        shot("import-no-transcript.png")
        imports.start()
        waitWhile { imports.importing }
        expect(imports.copiedCount == 1, "one recording imported")
        // Of two identical files, the first listed comes in.
        let entry = model.allEntries.first { $0.title == "Mei, first interview" }
        expect(entry != nil, "it is in the list, with the name given")
        expect(
            entry?.folder.lastPathComponent.hasSuffix(" Mei, first interview") == true,
            "its folder carries the name")
        if let entry, let audio = try? AVAudioFile(forReading: entry.audio) {
            expect(
                audio.fileFormat.sampleRate == 48_000 && audio.fileFormat.channelCount == 2,
                "its audio is 48 kHz stereo (\(audio.fileFormat.sampleRate), \(audio.fileFormat.channelCount))")
        } else {
            expect(false, "its audio can be read")
        }
        expect(FileManager.default.fileExists(atPath: memo.path), "the original is left where it was")
        if let copied = imports.items.first(where: { $0.state == .copied }) {
            expect(imports.progress(of: copied) == nil, "with no transcript asked for, the row keeps its details")
            imports.open(copied)
            expect(model.card?.entry.title == "Mei, first interview", "the row opens its recording")
            model.closeCard()
        }
        shot("import-done.png")
        window.window.close()
        window.show(adding: [memo])
        waitWhile { imports.items.isEmpty || imports.reading }
        expect(imports.items.first?.state == .duplicate, "importing it again is marked already in TapeUp")
        shot("import-again.png")
        window.window.close()
        // Gone again, without going through the user's Trash.
        if let entry { try? FileManager.default.removeItem(at: entry.folder) }
        model.reload()
    }

    /// The panel content's own height, measured apart from the window.
    private static func naturalHeight(model: AppModel) -> CGFloat {
        let real = PanelView.laidOutHeight
        defer { PanelView.laidOutHeight = real }
        let host = NSHostingView(rootView: PanelView(model: model, close: {}, resized: { _ in }))
        return host.fittingSize.height
    }
}

/// When the main thread was free, for the stall check while recording.
@MainActor private final class Beats {
    var times: [Double] = []
}
