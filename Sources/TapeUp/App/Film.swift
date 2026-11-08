import AppKit
import ScreenCaptureKit
import SwiftUI
import TapeUpCore

/// `TapeUp film --out <dir> [--only <name,…>]`: the README's journeys, each
/// recorded as a movie of the real panel on a made-up desktop, light and
/// dark. A drawn pointer moves and clicks; the panel's own animations play.
/// `scripts/shots.sh` turns the movies into GIFs.
@MainActor
enum Film {
    static func run(out: String, only: [String]) -> Never {
        // In a home of its own, so the settings, the folder and the paths
        // the panel shows are the film's (~/TapeUp), never the user's.
        guard ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] != nil else { exit(rerunInOwnHome()) }
        let outURL = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        Task { @MainActor in
            for journey in Journey.all where only.isEmpty || only.contains(journey.name) {
                for dark in [false, true] {
                    let file = outURL.appendingPathComponent("\(journey.name)-\(dark ? "dark" : "light").mov")
                    // A capture now and then fails to start; a second take does.
                    var attempt = 0
                    while true {
                        attempt += 1
                        do {
                            try await film(journey, dark: dark, to: file)
                            print(file.path)
                            break
                        } catch {
                            FileHandle.standardError.write(Data("\(journey.name): \(error)\n".utf8))
                            if attempt == 3 {
                                failed = true
                                break
                            }
                        }
                    }
                }
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        exit(failed ? 1 : 0)
    }

    private static var done = false
    private static var failed = false

    private static func rerunInOwnHome() -> Int32 {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tapeup-film-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = Array(CommandLine.arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment
        do { try process.run() } catch { return 1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// One take: a fresh made-up library, the stage on screen, the movie.
    private static func film(_ journey: Journey, dark: Bool, to file: URL) async throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("TapeUp")
        try? FileManager.default.removeItem(at: root)
        let take = Take(root: root, dark: dark, size: journey.size)
        defer { take.window.orderOut(nil) }
        journey.setUp(take)
        take.show()
        try await Task.sleep(for: .milliseconds(600))
        let recording = try await Recording.start(window: take.window, to: file)
        try await Task.sleep(for: .milliseconds(400))
        await journey.script(take)
        try await Task.sleep(for: .milliseconds(200))
        try await recording.stop()
    }
}

// MARK: Recording the window

/// The stage window alone, sixty frames a second, no system pointer: other
/// windows over it and the user's own mouse never get into the movie.
@MainActor
private final class Recording: NSObject, SCRecordingOutputDelegate {
    private let stream: SCStream
    private var finished: CheckedContinuation<Void, Error>?
    private var didFinish = false
    private var failure: Error?

    private init(stream: SCStream) { self.stream = stream }

    static func start(window: NSWindow, to file: URL) async throws -> Recording {
        try? FileManager.default.removeItem(at: file)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.shouldBeOpaque = true
        config.ignoreShadowsSingleWindow = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let recording = Recording(stream: stream)
        let output = SCRecordingOutputConfiguration()
        output.outputURL = file
        output.outputFileType = .mov
        output.videoCodecType = .hevc
        try stream.addRecordingOutput(SCRecordingOutput(configuration: output, delegate: recording))
        try await stream.startCapture()
        return recording
    }

    func stop() async throws {
        try await stream.stopCapture()
        if didFinish {
            if let failure { throw failure }
            return
        }
        try await withCheckedThrowingContinuation { finished = $0 }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.end(nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.end(error) }
    }

    private func end(_ error: Error?) {
        didFinish = true
        failure = error
        if let finished {
            self.finished = nil
            if let error { finished.resume(throwing: error) } else { finished.resume() }
        }
    }
}

// MARK: The stage

/// What the stage shows besides the panel: the pointer, the menu-bar item,
/// a drawn menu and a terminal.
@MainActor @Observable
final class Director {
    var cursor = CGPoint(x: 330, y: 220)
    var pressing = false
    var itemPressed = false
    var panelOpen = false
    var panelHeight: CGFloat = 0
    var menu: DrawnMenu?
    var terminal: [String]?
    /// The terminal's input line while it is being typed.
    var typing: String?
    /// A call going on in another app, under everything.
    var call = false
    /// Keys just pressed, shown large as a keystroke viewer would.
    var keys: String?
    /// The floating controls, centered under the menu bar.
    var pill = false
    /// The Import window, open on the stage, and its height as laid out.
    var importing: Imports?
    var importHeight: CGFloat = 0
    /// A Finder window of files to drag, which of them are selected, and
    /// the names being dragged under the pointer.
    var finder: [String]?
    var selected = false
    var dragging: [String]?

    struct DrawnMenu {
        var items: [String]
        var origin: CGPoint
        var highlighted: Int?
    }
}

/// A take: the made-up library, the model, the window and what moves in it.
@MainActor
final class Take {
    let model = AppModel()
    let director = Director()
    let window: NSPanel
    let host: NSHostingView<Stage>
    let dark: Bool
    let size: CGSize
    let root: URL
    var lanes = Shots.Lanes()
    private var ticker: Timer?
    /// Files on the made-up desktop, for the import journey.
    var files: [URL] = []
    /// The newest recording, moved aside while it is being "recorded".
    private var hidden: (folder: URL, aside: URL)?

    /// Where the panel's top-left corner sits on the stage.
    var panelOrigin: CGPoint { CGPoint(x: size.width - Stage.inset - PanelView.width - 18, y: Stage.inset + 26 + 6) }
    /// Where the floating controls sit: centered under the menu bar.
    static func pillOrigin(_ size: CGSize) -> CGPoint {
        CGPoint(x: (size.width - FloatingControlsView.width) / 2, y: Stage.inset + 26 + 10)
    }
    var pauseButton: CGPoint {
        let origin = Self.pillOrigin(size)
        return CGPoint(x: origin.x + FloatingControlsView.width - 38, y: origin.y + 15)
    }
    var stopButton: CGPoint {
        let origin = Self.pillOrigin(size)
        return CGPoint(x: origin.x + FloatingControlsView.width - 15, y: origin.y + 15)
    }
    /// Where the Finder window and the Import window sit on the stage.
    static let finderOrigin = CGPoint(x: 30, y: 120)
    static func importOrigin(_ size: CGSize) -> CGPoint {
        CGPoint(x: size.width - Stage.inset - ImportView.width - 22, y: Stage.inset + 26 + 34)
    }
    /// A point in the Import window, from its top-left corner.
    func inImport(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let origin = Self.importOrigin(size)
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }
    /// The Import window's bottom button: Import, then Done.
    var importButton: CGPoint { inImport(ImportView.width / 2, director.importHeight - 32) }
    /// A row in the Finder window.
    func finderRow(_ index: Int) -> CGPoint {
        CGPoint(x: Self.finderOrigin.x + 80, y: Self.finderOrigin.y + 52 + CGFloat(index) * 24)
    }

    /// The menu-bar item's centre.
    var item: CGPoint { CGPoint(x: size.width - Stage.inset - 174, y: Stage.inset + 13) }

    init(root: URL, dark: Bool, size: CGSize) {
        self.root = root
        // Films find controls by name, as the UI test does.
        ClickTargets.recording = true
        self.dark = dark
        self.size = size
        Shots.seed(root)
        // Three days of recordings keep the panel short enough for a picture.
        let library = RecordingLibrary(root: root)
        if let oldest = library.entries().last { try? FileManager.default.removeItem(at: oldest.folder) }
        model.root = root
        model.transcription.stage(download: .ready)
        model.agents.stage(states: [.claude: .signedIn, .codex: .signedIn], chosen: nil)
        model.stage(phase: .idle, microphone: "AirPods Pro", output: "MacBook Pro Speakers")
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.screens[0]
        let frame = NSRect(
            x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 40 - size.height, width: size.width,
            height: size.height)
        window = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.hasShadow = false
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.becomesKeyOnlyIfNeeded = true
        host = NSHostingView(rootView: Stage(model: model, director: director, dark: dark, size: size))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
    }

    func show() {
        window.orderFrontRegardless()
        // Behind the user's windows: the recording sees it anyway.
        window.orderBack(nil)
    }

    // MARK: Moving

    func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Glides the pointer to a point on the stage, easing in and out.
    func move(to point: CGPoint, _ seconds: Double = 0.7) async {
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: seconds)) { director.cursor = point }
        await pause(seconds)
    }

    /// A point in the panel's own coordinates, on the stage.
    func at(_ point: CGPoint) -> CGPoint { CGPoint(x: panelOrigin.x + point.x, y: panelOrigin.y + point.y) }

    /// Glides to the middle of a named control (see `clickTarget`).
    /// `at` places the pointer along it, 0 at the left edge and 1 at the
    /// right, so it can rest clear of the label.
    func move(toTarget name: String, at x: CGFloat = 0.5, _ seconds: Double = 0.7) async {
        guard let frame = ClickTargets.frame(name) else { return print("  no control named \(name)") }
        await move(to: CGPoint(x: frame.minX + frame.width * x, y: frame.midY), seconds)
    }

    /// Glides to a point in the panel's own coordinates.
    func move(toPanel point: CGPoint, _ seconds: Double = 0.7) async { await move(to: at(point), seconds) }

    /// A press and release, then the action as the button would run it.
    func click(_ action: () -> Void = {}) async {
        withAnimation(.easeOut(duration: 0.08)) { director.pressing = true }
        await pause(0.12)
        action()
        withAnimation(.easeOut(duration: 0.12)) { director.pressing = false }
        await pause(0.1)
    }

    /// Clicks the menu-bar item: it darkens, and the panel opens.
    func openPanel() async {
        await move(to: item, 0.65)
        withAnimation(.easeOut(duration: 0.06)) {
            director.pressing = true
            director.itemPressed = true
        }
        await pause(0.1)
        model.reload()
        withAnimation(.easeOut(duration: 0.12)) {
            director.panelOpen = true
            director.pressing = false
        }
        await pause(0.25)
    }

    /// Clicks a menu's button, then picks an item from the menu as drawn
    /// under it, kept on the stage as macOS keeps menus on the screen.
    func pick(_ item: String, from button: CGPoint, items: [String], then action: () -> Void) async {
        await move(to: button, 0.7)
        // Below the button, or above it when the screen ends first.
        let height = items.reduce(CGFloat(10)) { $0 + ($1 == "-" ? 9 : 22) }
        let below = button.y + 14
        let origin = CGPoint(
            x: min(button.x - 12, size.width - Stage.inset - DrawnMenuView.width - 6),
            y: below + height > size.height - Stage.inset - 6 ? button.y - 14 - height : below)
        await click { director.menu = .init(items: items, origin: origin) }
        await pause(0.4)
        guard let index = items.firstIndex(of: item) else { return }
        let rows = items.prefix(index).reduce(CGFloat(5)) { $0 + ($1 == "-" ? 9 : 22) }
        await move(to: CGPoint(x: origin.x + 56, y: origin.y + rows + 11), 0.5)
        director.menu?.highlighted = index
        await pause(0.3)
        await click {
            director.menu = nil
            action()
        }
    }

    /// The ··· menu at the top of Recent.
    func pickFromMore(_ item: String, then action: () -> Void) async {
        await pick(
            item, from: at(Spot.more),
            items: ["Import…", "People…", "Settings…", "-", "Check for Updates…", "Quit TapeUp ⌘Q"],
            then: action)
    }

    /// Types one character at a time into the field with this placeholder,
    /// or, with none, into the field already being typed in.
    func type(_ text: String, into placeholder: String? = nil, perCharacter: Double = 0.07) async {
        if let placeholder {
            guard let field = Self.textField(placeholder: placeholder, in: host) else {
                FileHandle.standardError.write(Data("film: no field \(placeholder)\n".utf8))
                return
            }
            window.makeKey()
            window.makeFirstResponder(field)
            await pause(0.15)
        }
        guard let editor = window.firstResponder as? NSTextView else {
            FileHandle.standardError.write(Data("film: nothing to type in\n".utf8))
            return
        }
        for character in text {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            await pause(perCharacter * Double.random(in: 0.7...1.3))
        }
    }

    /// Return in the focused field.
    func pressReturn() {
        (window.firstResponder as? NSTextView)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    /// Ends typing: the panel gives up the keyboard.
    func resignKeyboard() {
        window.makeFirstResponder(nil)
        window.resignKey()
    }

    // MARK: Recording, as staged

    /// The launch call is not in the list until it stops.
    func hideNewest() {
        guard let entry = model.recent.first(where: { $0.title == nil }) else { return }
        let aside = root.deletingLastPathComponent().appendingPathComponent("aside")
        guard (try? FileManager.default.moveItem(at: entry.folder, to: aside)) != nil else { return }
        hidden = (entry.folder, aside)
        model.reload()
    }

    /// Paused: the clock and the levels hold still.
    var paused = false

    /// Runs the clock, the levels and the live words as a recording would.
    func startRecording(from elapsed: TimeInterval, words: @escaping (TimeInterval) -> [String]) {
        var elapsed = elapsed
        var last = Date()
        let began = Date().addingTimeInterval(-elapsed)
        let step: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            let now = Date()
            if !paused {
                elapsed += now.timeIntervalSince(last)
                lanes.advance()
            }
            last = now
            model.transcription.stage(download: .ready, live: true, latest: words(elapsed))
            model.stage(
                phase: .recording(started: began), elapsed: elapsed, microphone: "AirPods Pro",
                output: "MacBook Pro Speakers", levels: paused ? nil : lanes.levels, paused: paused)
        }
        step()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { _ in
            MainActor.assumeIsolated { step() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    /// Stops the staged recording and shows its card, saving, then saved.
    /// - Parameter showPanel: stopped from outside the panel, which then
    ///   drops on its own with the saved recording, as after ⌥⌘R.
    func stopRecording(title: String?, showPanel: Bool = false) async {
        ticker?.invalidate()
        ticker = nil
        let duration = model.elapsed
        model.transcription.stage(download: .ready)
        model.stage(phase: .idle, microphone: "AirPods Pro", output: "MacBook Pro Speakers")
        if let hidden {
            try? FileManager.default.moveItem(at: hidden.aside, to: hidden.folder)
            self.hidden = nil
        }
        model.reload()
        guard let found = model.recent.first(where: { $0.title == nil }) else { return }
        // As long as it ran, with nobody named yet.
        let meta = found.folder.appendingPathComponent("meta.json")
        if var fields = (try? Data(contentsOf: meta)).flatMap({ try? JSONSerialization.jsonObject(with: $0) })
            as? [String: Any]
        {
            fields["duration_seconds"] = duration.rounded()
            try? JSONSerialization.data(withJSONObject: fields).write(to: meta)
        }
        try? RecordingLibrary.save(people: .init(), in: found.folder)
        model.reload()
        guard let entry = RecordingLibrary.entry(at: found.folder) else { return }
        var finishing = entry
        finishing.transcript = .pending
        model.card = .init(entry: finishing, finishing: true, justRecorded: true)
        if showPanel {
            withAnimation(.easeOut(duration: 0.15)) {
                director.itemPressed = true
                director.panelOpen = true
            }
        }
        await pause(0.9)
        model.card = .init(entry: entry, finishing: false, justRecorded: true)
        guard let title else { return }
        await pause(1.2)
        if let folder = try? RecordingLibrary.save(title: title, in: entry.folder),
            let saved = RecordingLibrary.entry(at: folder)
        {
            withAnimation(.easeOut(duration: 0.2)) { model.card?.entry = saved }
            model.reload()
        }
    }

    static func textField(placeholder: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        for subview in view.subviews {
            if let found = textField(placeholder: placeholder, in: subview) { return found }
        }
        return nil
    }
}

/// The made-up desktop: a screen with a menu bar, the panel under its item,
/// a drawn menu, a terminal and the pointer, on the page GitHub shows.
struct Stage: View {
    static let inset: CGFloat = 12
    let model: AppModel
    @Bindable var director: Director
    let dark: Bool
    let size: CGSize

    private var status: Shots.StatusLook {
        if case .recording = model.phase { return .recording(Format.duration(model.elapsed)) }
        return .idle
    }

    private var panelX: CGFloat { size.width - Self.inset - PanelView.width - 18 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Shots.Palette.page(dark)
            ZStack(alignment: .topLeading) {
                Shots.Palette.desktop(dark)
                if director.call {
                    CallWindow(dark: dark).padding(.leading, 18).padding(.top, 26 + 40)
                }
                if let lines = director.terminal {
                    Shots.Terminal(
                        text: lines.joined(separator: "\n"), typing: director.typing, compact: true, width: 740,
                        height: size.height - Self.inset * 2 - 26 - 12
                    )
                    .padding(.leading, 6)
                    .padding(.top, 26 + 6)
                    .transition(.opacity)
                }
                if let files = director.finder {
                    FinderWindow(files: files, selected: director.selected, dark: dark)
                        .offset(x: Take.finderOrigin.x - Self.inset, y: Take.finderOrigin.y - Self.inset)
                }
                if let imports = director.importing {
                    ImportWindowDrawn(imports: imports, dark: dark) { director.importHeight = $0 }
                        .offset(
                            x: Take.importOrigin(size).x - Self.inset, y: Take.importOrigin(size).y - Self.inset
                        )
                        .transition(.opacity)
                }
                Shots.MenuBar(dark: dark, status: status, wide: false, pressed: director.itemPressed)
                    .frame(width: size.width - Self.inset * 2, height: 26)
                if director.panelOpen {
                    panel
                        .offset(x: panelX - Self.inset, y: 26 + 6)
                        .transition(.opacity)
                }
                if director.pill {
                    FloatingControlsView(model: model, stop: {}, drag: { _, _ in })
                        .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
                        .overlay(
                            Capsule().strokeBorder(
                                dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 10, y: 4)
                        .offset(x: Take.pillOrigin(size).x - Self.inset, y: Take.pillOrigin(size).y - Self.inset)
                        .transition(.opacity)
                }
                if let keys = director.keys {
                    Text(keys)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                        .background(Color.black.opacity(0.62), in: .rect(cornerRadius: 14, style: .continuous))
                        .frame(width: size.width - Self.inset * 2)
                        .offset(y: size.height - Self.inset * 2 - 110)
                        .transition(.opacity)
                }
                if let menu = director.menu {
                    DrawnMenuView(menu: menu, dark: dark)
                        .offset(x: menu.origin.x - Self.inset, y: menu.origin.y - Self.inset)
                        .transition(.opacity.animation(.easeOut(duration: 0.1)))
                }
                if let names = director.dragging {
                    DragGhost(names: names, dark: dark)
                        .offset(x: director.cursor.x - Self.inset - 14, y: director.cursor.y - Self.inset - 10)
                }
                pointer.offset(x: director.cursor.x - Self.inset, y: director.cursor.y - Self.inset)
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Shots.Palette.hairline(dark), lineWidth: 0.5)
            )
            .padding(Self.inset)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private var panel: some View {
        PanelView(
            model: model, close: {},
            resized: { height in
                if director.panelHeight == 0 {
                    director.panelHeight = height
                } else {
                    // The window's own motion: a fifth of a second, easing out.
                    withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.2)) { director.panelHeight = height }
                }
            }
        )
        .frame(width: PanelView.width, height: max(director.panelHeight, 1), alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.45 : 0.12), radius: 16, y: 8)
        .shadow(color: .black.opacity(dark ? 0.3 : 0.06), radius: 2, y: 1)
    }

    private var pointer: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(dark ? Color.white.opacity(0.22) : Color.black.opacity(0.14))
                .frame(width: 26, height: 26)
                .offset(x: -13, y: -13)
                .scaleEffect(director.pressing ? 1 : 0.3, anchor: .topLeading)
                .opacity(director.pressing ? 1 : 0)
            Shots.Arrow().fill(Color.black).overlay(Shots.Arrow().stroke(Color.white, lineWidth: 1.2))
                .frame(width: 13, height: 20)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .scaleEffect(director.pressing ? 0.9 : 1, anchor: .topLeading)
        }
        .frame(width: 1, height: 1, alignment: .topLeading)
    }
}

/// The real Import window's content in a drawn window frame: a title bar
/// with only Close, as the app's own.
private struct ImportWindowDrawn: View {
    let imports: Imports
    let dark: Bool
    let measured: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Import").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                HStack {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 9)
            }
            .frame(height: 28)
            ImportView(imports: imports, choose: {})
        }
        .fixedSize()
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 18, y: 10)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            measured($0)
        }
    }
}

/// A Finder window of old recordings, drawn.
private struct FinderWindow: View {
    let files: [String]
    let selected: Bool
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.primary.opacity(0.16)).frame(width: 11, height: 11)
                }
                Text("Old recordings").font(.system(size: 12, weight: .semibold)).padding(.leading, 10)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            ForEach(Array(files.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 7) {
                    Image(systemName: "waveform").font(.system(size: 11)).frame(width: 16)
                    Text(name).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(selected ? Color.accentColor : .clear, in: .rect(cornerRadius: 5))
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 230, height: 190, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.35 : 0.1), radius: 12, y: 6)
    }
}

/// Files being dragged: their icons stacked, with the count.
private struct DragGhost: View {
    let names: [String]
    let dark: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { index, _ in
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(Image(systemName: "waveform").font(.system(size: 14)).foregroundStyle(.secondary))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
                    .frame(width: 30, height: 36)
                    .offset(x: CGFloat(index) * 4, y: CGFloat(index) * 3)
            }
            Text("\(names.count)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .background(Color.red, in: .capsule)
                .offset(x: 14, y: -8)
        }
        .opacity(0.9)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/// A macOS menu, drawn: the ··· menu cannot open for real in a recording.
struct DrawnMenuView: View {
    static let width: CGFloat = 168
    let menu: Director.DrawnMenu
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                if item == "-" {
                    Divider().padding(.horizontal, 10).frame(height: 9)
                } else {
                    HStack {
                        Text(item.replacingOccurrences(of: " ⌘Q", with: ""))
                        Spacer(minLength: 24)
                        if item.hasSuffix("⌘Q") { Text("⌘Q").foregroundStyle(highlighted(index) ? .white : .secondary) }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(highlighted(index) ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(
                        highlighted(index) ? Color.accentColor : .clear, in: .rect(cornerRadius: 4, style: .continuous)
                    )
                    .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: Self.width)
        .background(
            dark ? Color(white: 0.2) : Color(white: 0.97), in: .rect(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 12, y: 6)
    }

    private func highlighted(_ index: Int) -> Bool { menu.highlighted == index }
}

/// A video call in some other app: four people in tiles, no one's brand.
private struct CallWindow: View {
    let dark: Bool
    private let people = [("Priya Shah", "PS"), ("José Ortiz", "JO"), ("Ana", "A"), ("You", "S")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 11, height: 11)
                }
                Spacer()
            }
            .overlay(Text("Beta launch").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(dark ? Color(white: 0.2) : Color(white: 0.86))
                        Circle()
                            .fill(dark ? Color(white: 0.32) : Color(white: 0.72))
                            .frame(width: 46, height: 46)
                            .overlay(Text(person.1).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(person.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.4), in: .rect(cornerRadius: 4))
                            .padding(6)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.green.opacity(index == 0 ? 0.9 : 0), lineWidth: 2)
                    )
                    .frame(height: 118)
                }
            }
            .padding(6)
        }
        .frame(width: 420)
        .background(dark ? Color(white: 0.12) : Color(white: 0.96), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 14, y: 6)
    }
}
