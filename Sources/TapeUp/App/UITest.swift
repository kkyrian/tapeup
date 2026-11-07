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

    static func run(out: String, record: Bool) {
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-uitest-\(UUID().uuidString)")
        let root = base.appendingPathComponent("recordings")
        Snapshot.seed(root)
        defaults.set(root.path, forKey: "recordingsRoot")
        for key in keys.dropFirst() { defaults.removeObject(forKey: key) }

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
        model.closePeople()
        check("people-back")
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
            model.open(labeled)
            check("card-speakers-offered")
            expect(labeled.transcript == .done, "the seeded recording is transcribed")
            model.labelSpeakers()
            check("card-speakers-two")
            let two = model.speakers.result(for: labeled)
            expect(two?.voices.count == 2 && two?.estimated == false, "the count of 2 finds 2 voices")
            var people = labeled.people
            people.count = nil
            model.setPeople(people)
            check("card-speakers-estimated")
            let estimate = model.speakers.result(for: labeled)
            expect(estimate?.estimated == true && estimate?.voices.count == 3, "without a count, 3 voices estimated")
            model.speakers.name(1, "Priya Shah", in: labeled)
            check("card-speakers-named")
            let file = labeled.folder.appendingPathComponent(SpeakerLabels.fileName)
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            expect(text.contains("Priya Shah: Thanks for making time"), "the name is in the labeled transcript")
            model.copyTranscript(labeled)
            expect(
                NSPasteboard.general.string(forType: .string)?.contains("Voice 2:") == true,
                "Copy transcript copies the labeled one")
            people.count = 3
            model.setPeople(people)
            check("card-speakers-same-count")
            expect(
                model.speakers.result(for: labeled)?.names[1] == "Priya Shah", "tapping the same number keeps names")
            // A title suggested by the on-device model, accepted in one click.
            if Titles.available {
                for _ in 0..<80 where model.card?.entry.titleSuggestion == nil { settle(0.25) }
                check("card-title-suggested")
                let suggestion = model.card?.entry.titleSuggestion
                expect(suggestion != nil, "a title is suggested from the transcript (\(suggestion ?? "none"))")
                expect(model.card?.entry.title == nil, "nothing is named until the suggestion is accepted")
                model.acceptSuggestedTitle()
                check("card-title-accepted")
                expect(model.card?.entry.title == suggestion, "Use names the recording")
            }
            model.closeCard()
        } else {
            expect(false, "a seeded recording has voices to label")
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
            while process.isRunning { settle(0.1) }
            return (
                process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
        if let target = model.recent.first(where: { $0.title == nil && $0.transcript == .none }) {
            let stamp = RecordingLibrary.stamp(of: target.folder)
            let named = command(["title", stamp, "Budget review"])
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
        }
        DistributedNotificationCenter.default().removeObserver(link)

        let victim = model.recent[2]
        model.trash(victim)
        check("trashed")
        expect(!model.recent.contains { $0.folder == victim.folder }, "trashed recording left the list")
        model.undoTrash()
        check("undone")
        expect(model.recent.contains { $0.folder == victim.folder }, "undo put it back")

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
            check("recording")
            expect(model.isRecording, "recording started")
            if model.transcription.download == .ready {
                expect(model.transcription.liveRunning, "transcribing while recording")
            }
            expect(floating.window.isVisible, "floating controls show")
            let pausedAt = Date()
            model.togglePause()
            settle(2)
            check("paused")
            model.togglePause()
            let pausedFor = Date().timeIntervalSince(pausedAt)
            settle(2)
            let wall = Date().timeIntervalSince(began)
            beat.invalidate()
            let stalls = zip(beats.times, beats.times.dropFirst()).filter { $1 - $0 > 0.25 }
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
