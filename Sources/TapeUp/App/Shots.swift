import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp shots --out <dir>`: the README's pictures and the frames of its
/// animation, from the real panel with made-up meetings, light and dark.
/// `TapeUp shots --demo <dir>` only makes the made-up library, for running
/// an agent against it. `scripts/shots.sh` runs both and builds the GIF.
@MainActor
enum Shots {
    static func run(out: String, demo: String?) -> Never {
        if let demo {
            let root = URL(fileURLWithPath: demo)
            try? FileManager.default.removeItem(at: root)
            // As the folder stands once its title is made.
            let folder = seed(root).flatMap { try? RecordingLibrary.save(title: "Beta launch plan", in: $0) }
            print(folder?.path ?? "")
            exit(0)
        }
        let outURL = URL(fileURLWithPath: out)
        let frames = outURL.appendingPathComponent("frames")
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-shots-\(UUID().uuidString)")
        let savedRoot = UserDefaults.standard.object(forKey: "recordingsRoot")
        func restore() {
            if let savedRoot {
                UserDefaults.standard.set(savedRoot, forKey: "recordingsRoot")
            } else {
                UserDefaults.standard.removeObject(forKey: "recordingsRoot")
            }
            try? FileManager.default.removeItem(at: root)
        }
        let past = root.appendingPathComponent("past")
        let full = root.appendingPathComponent("full")
        seed(past, withNewest: false)
        guard let latestFolder = seed(full) else {
            restore()
            Launcher.fail("could not make the sample library", code: 1)
        }

        let model = AppModel()
        model.root = full
        model.transcription.stage(download: .ready)
        let devices = (microphone: "AirPods Pro", output: "MacBook Pro Speakers")
        guard let latest = model.recent.first(where: { $0.folder.lastPathComponent == latestFolder.lastPathComponent })
        else {
            restore()
            Launcher.fail("the sample recording is missing", code: 1)
        }
        var lanes = Lanes()

        func picture(_ name: String, scene: SceneKind, status: StatusLook) {
            for dark in [false, true] {
                guard let panel = panelImage(model: model, dark: dark) else { continue }
                write(
                    Scene(panel: panel, dark: dark, status: status, kind: scene),
                    to: outURL.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        // The hero: recording, the latest words under the timer.
        model.root = past
        model.transcription.stage(download: .ready, live: true, latest: [said[2].1, said[3].1])
        model.stage(
            phase: .recording(started: Date()), elapsed: 74, microphone: devices.microphone,
            output: devices.output, levels: lanes.levels)
        if let panel = panelImage(model: model, dark: true) {
            let renderer = ImageRenderer(content: Social(panel: panel))
            renderer.scale = 1
            if let image = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: outURL.appendingPathComponent("social.png"))
            }
        }

        // What a recording leaves for the user to add: how many, who.
        model.root = full
        model.transcription.stage(download: .ready)
        model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
        var named = latest
        named.title = "Beta launch plan"
        named.transcript = .done
        named.people = .init(count: 4, names: ["Priya Shah", "José Ortiz", "Ana"])
        model.card = .init(entry: named, finishing: false, justRecorded: true)
        picture("context", scene: .panelOnly, status: .idle)
        model.card = nil
        model.openPeople()
        picture("people", scene: .panelOnly, status: .idle)
        model.closePeople()

        // The animation, ten frames a second, light only.
        var frame = 0
        func shoot(_ count: Int, status: StatusLook, change: (Int) -> Void = { _ in }) {
            for index in 0..<count {
                change(index)
                guard let panel = panelImage(model: model, dark: false) else { continue }
                write(
                    Scene(panel: panel, dark: false, status: status, kind: .animation),
                    to: frames.appendingPathComponent(String(format: "%03d.png", frame)))
                frame += 1
            }
        }
        model.card = nil
        model.root = past
        model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
        shoot(14, status: .idle)
        let words = said.prefix(3).map(\.1).joined(separator: " ").split(separator: " ")
        var shown = 0
        for index in 0..<56 {
            if index % 2 == 0, shown < words.count { shown += 1 }
            let text = words.prefix(shown).joined(separator: " ")
            let elapsed = Double(index) / 10
            model.transcription.stage(download: .ready, live: true, latest: lastTwoSentences(text))
            lanes.advance()
            model.stage(
                phase: .recording(started: Date()), elapsed: elapsed, microphone: devices.microphone,
                output: devices.output, levels: lanes.levels)
            shoot(1, status: .recording(Format.duration(elapsed)))
        }
        model.transcription.stage(download: .ready)
        model.root = full
        model.stage(phase: .idle, microphone: devices.microphone, output: devices.output)
        var saved = latest
        saved.title = nil
        saved.transcript = .pending
        model.card = .init(entry: saved, finishing: true, justRecorded: true)
        shoot(5, status: .idle)
        model.card = .init(entry: saved, finishing: false, justRecorded: true)
        shoot(10, status: .idle)
        saved.transcript = .done
        saved.title = "Beta launch plan"
        model.card = .init(entry: saved, finishing: false, justRecorded: true)
        shoot(18, status: .idle)
        model.card = .init(entry: saved, finishing: false, copied: true, justRecorded: true)
        shoot(22, status: .idle)

        if let handoff = try? String(contentsOfFile: "scripts/shots/handoff.md", encoding: .utf8) {
            write(Terminal(text: handoff), to: outURL.appendingPathComponent("handoff.png"))
        }
        print(outURL.path)
        restore()
        exit(0)
    }

    private static func lastTwoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }
        return Array(sentences.suffix(2))
    }

    /// Two moving lanes of levels: speech in bursts on the microphone, the
    /// call steadier on the computer side.
    @MainActor private struct Lanes {
        var microphone = (0..<AppModel.laneLength).map { i in i % 9 < 4 ? Float.random(in: 0.3...0.8) : 0.06 }
        var computer = (0..<AppModel.laneLength).map { _ in Float.random(in: 0.3...0.85) }
        var tick = 0
        var levels: ([Float], [Float]) { (microphone, computer) }
        mutating func advance() {
            tick += 1
            // The microphone talks for a while, then the call answers.
            let talking = (tick / 14) % 2 == 0
            microphone.removeFirst()
            microphone.append(talking ? Float.random(in: 0.3...0.85) : Float.random(in: 0.03...0.08))
            computer.removeFirst()
            computer.append(talking ? Float.random(in: 0.04...0.12) : Float.random(in: 0.3...0.9))
        }
    }

    // MARK: Rendering

    /// The panel's real pixels, from the window server, as the UI test takes
    /// them: drawing the view to a bitmap marks the name tokens' edges.
    private static func panelImage(model: AppModel, dark: Bool) -> NSImage? {
        let view = PanelView(model: model, close: {}, resized: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        // Sharp pictures need a Retina screen; use one when there is one.
        let screen = (NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main)?.visibleFrame ?? .zero
        let window = NSWindow(
            contentRect: NSRect(x: screen.minX, y: screen.minY, width: PanelView.width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.hasShadow = false
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let size = host.fittingSize
        window.setContentSize(size)
        window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        defer { window.orderOut(nil) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", file.path]
        try? capture.run()
        capture.waitUntilExit()
        guard let image = NSImage(contentsOf: file), let rep = image.representations.first else { return nil }
        let scale = window.backingScaleFactor
        image.size = NSSize(width: CGFloat(rep.pixelsWide) / scale, height: CGFloat(rep.pixelsHigh) / scale)
        return image
    }

    private static func write(_ scene: some View, to url: URL) {
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    enum StatusLook {
        case idle
        case recording(String)
    }

    enum SceneKind {
        /// A desktop with the menu bar across it, for the top of the page.
        case wide
        /// The panel alone on a soft backdrop.
        case panelOnly
        /// Narrower than the hero, one height for every frame.
        case animation
    }

    /// The panel where it lives: under its menu-bar item, on a desktop.
    private struct Scene: View {
        let panel: NSImage
        let dark: Bool
        let status: StatusLook
        let kind: SceneKind

        private var width: CGFloat {
            switch kind {
            case .wide: 880
            case .panelOnly: PanelView.width + 64
            case .animation: PanelView.width + 64
            }
        }

        private var height: CGFloat {
            switch kind {
            case .wide: 640
            case .panelOnly: panel.size.height + 64
            case .animation: 620
            }
        }

        var body: some View {
            ZStack(alignment: .topLeading) {
                Wallpaper(dark: dark)
                if kind == .panelOnly {
                    panelView.position(x: width / 2, y: height / 2)
                } else {
                    MenuBar(dark: dark, status: status, wide: kind == .wide)
                        .frame(width: width, height: 26)
                    panelView
                        .position(x: width - PanelView.width / 2 - 24, y: 26 + 8 + panel.size.height / 2)
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .environment(\.colorScheme, dark ? .dark : .light)
        }

        private var panelView: some View {
            Image(nsImage: panel)
                .resizable()
                .frame(width: panel.size.width, height: panel.size.height)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(dark ? 0.5 : 0.18), radius: 28, y: 14)
                .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 3, y: 1)
        }
    }

    private struct Wallpaper: View {
        let dark: Bool
        var body: some View {
            ZStack {
                LinearGradient(
                    colors: dark
                        ? [Color(red: 0.10, green: 0.11, blue: 0.20), Color(red: 0.20, green: 0.12, blue: 0.24)]
                        : [Color(red: 0.86, green: 0.90, blue: 0.98), Color(red: 0.98, green: 0.90, blue: 0.88)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [
                        (dark ? Color(red: 0.25, green: 0.30, blue: 0.60) : Color(red: 0.72, green: 0.82, blue: 1.0))
                            .opacity(0.7), .clear,
                    ], center: .init(x: 0.15, y: 0.85), startRadius: 0, endRadius: 520)
                RadialGradient(
                    colors: [
                        (dark ? Color(red: 0.55, green: 0.25, blue: 0.35) : Color(red: 1.0, green: 0.80, blue: 0.70))
                            .opacity(0.6), .clear,
                    ], center: .init(x: 0.9, y: 0.2), startRadius: 0, endRadius: 480)
            }
        }
    }

    private struct MenuBar: View {
        let dark: Bool
        let status: StatusLook
        let wide: Bool

        var body: some View {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.5))
                if wide {
                    HStack(spacing: 18) {
                        Image(systemName: "apple.logo").font(.system(size: 14))
                        Text("Finder").fontWeight(.bold)
                        ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
                    }
                    .padding(.leading, 18)
                    .frame(height: 26)
                }
                HStack(spacing: 16) {
                    item
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    if wide {
                        Image(systemName: "magnifyingglass")
                        Image(systemName: "switch.2")
                    }
                    Text("Thu 2:30 PM")
                }
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .font(.system(size: 13))
            .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
        }

        @ViewBuilder private var item: some View {
            Group {
                switch status {
                case .idle:
                    Cassette().stroke(lineWidth: 1.5).frame(width: 20, height: 16)
                case .recording(let time):
                    HStack(spacing: 5) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(time).font(.system(size: 13, weight: .medium).monospacedDigit())
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dark ? Color.white.opacity(0.2) : Color.black.opacity(0.1)))
        }
    }

    /// The menu-bar glyph, as AppDelegate draws it.
    private struct Cassette: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let sx = rect.width / 20
            let sy = rect.height / 16
            path.addRoundedRect(
                in: CGRect(x: 1.5 * sx, y: 2.5 * sy, width: 17 * sx, height: 11 * sy),
                cornerSize: CGSize(width: 2.5 * sx, height: 2.5 * sy))
            for x in [6.5, 13.5] {
                path.addEllipse(in: CGRect(x: (x - 2) * sx, y: 6 * sy, width: 4 * sx, height: 4 * sy))
            }
            path.move(to: CGPoint(x: 8.5 * sx, y: 8 * sy))
            path.addLine(to: CGPoint(x: 11.5 * sx, y: 8 * sy))
            return path
        }
    }

    /// A terminal window showing an agent being handed a recording:
    /// `>` lines were typed, `~` lines summarize its tools, the rest is its
    /// answer in Markdown (bold, lists and one kind of table).
    private struct Terminal: View {
        let text: String
        private let width: CGFloat = 760
        private let ink = Color(white: 0.88)
        private let dim = Color(white: 0.55)

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { color in
                        Circle().fill(color.opacity(0.85)).frame(width: 12, height: 12)
                    }
                    Spacer()
                }
                .overlay(Text("~/TapeUp — claude").font(.system(size: 12, weight: .medium)).foregroundStyle(dim))
                .padding(.horizontal, 14)
                .frame(height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .frame(width: width, alignment: .leading)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .padding(32)
            .background(Wallpaper(dark: true))
            .environment(\.colorScheme, .dark)
        }

        private var blocks: [AnyView] {
            var views: [AnyView] = []
            var table: [[String]] = []
            func flushTable() {
                guard !table.isEmpty else { return }
                let rows = table.filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
                let columns = rows.map(\.count).max() ?? 0
                let widths = (0..<columns).map { c in rows.map { c < $0.count ? plain($0[c]).count : 0 }.max() ?? 0 }
                for (index, row) in rows.enumerated() {
                    let cells = (0..<columns).map { c -> String in
                        let cell = c < row.count ? row[c] : ""
                        return cell + String(repeating: " ", count: widths[c] - plain(cell).count)
                    }
                    views.append(AnyView(line(cells.joined(separator: "   "), bold: index == 0)))
                    if index == 0 {
                        let rule = widths.map { String(repeating: "─", count: $0) }.joined(separator: "   ")
                        views.append(AnyView(line(rule, color: dim)))
                    }
                }
                table = []
            }
            for raw in text.components(separatedBy: "\n") {
                if raw.hasPrefix("|") {
                    table.append(
                        raw.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                            .map { $0.trimmingCharacters(in: .whitespaces) })
                    continue
                }
                flushTable()
                if raw.hasPrefix(">") {
                    views.append(AnyView(line(raw, color: Color(red: 0.62, green: 0.72, blue: 1.0))))
                } else if raw.hasPrefix("  ") && views.count < 8 {
                    views.append(AnyView(line(raw, color: Color(red: 0.62, green: 0.72, blue: 1.0))))
                } else if raw.hasPrefix("~ ") {
                    views.append(AnyView(line("⏺ " + raw.dropFirst(2), color: dim)))
                } else if raw.hasPrefix("- ") || raw.hasPrefix("  - ") {
                    let indent = raw.hasPrefix("  ") ? "    " : "  "
                    views.append(
                        AnyView(
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                line(indent + "• ")
                                line(raw.trimmingCharacters(in: .whitespaces).dropFirst(2).description)
                            }))
                } else {
                    views.append(AnyView(line(raw)))
                }
            }
            flushTable()
            return views
        }

        private func plain(_ text: String) -> String { text.replacingOccurrences(of: "**", with: "") }

        private func line(_ text: String, color: Color? = nil, bold: Bool = false) -> some View {
            let styled =
                (try? AttributedString(
                    markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
            return Text(styled)
                .font(.system(size: 12.5, weight: bold ? .bold : .regular, design: .monospaced))
                .foregroundStyle(color ?? ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: text.isEmpty ? 8 : nil, alignment: .leading)
        }
    }

    /// GitHub's link preview, 1280 by 640: the name and promise beside the
    /// panel at work.
    private struct Social: View {
        let panel: NSImage

        var body: some View {
            ZStack(alignment: .topLeading) {
                Wallpaper(dark: true)
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 18) {
                            if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") {
                                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                            }
                            Text("TapeUp").font(.system(size: 64, weight: .bold))
                        }
                        Text("Record any meeting on your Mac.\nGet a transcript you and your AI agent can use.")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 700, alignment: .leading)
                    .padding(.leading, 80)
                    Spacer()
                }
                .frame(width: 1280, height: 640)
                Image(nsImage: panel)
                    .resizable()
                    .frame(width: panel.size.width * 1.35, height: panel.size.height * 1.35)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.7)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
                    .offset(x: 1280 - panel.size.width * 1.35 - 70, y: 70)
            }
            .frame(width: 1280, height: 640)
            .clipped()
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        }
    }

    // MARK: The made-up library

    /// A beta launch call. The user is Sam, at the microphone; Priya, José
    /// and Ana are on the call. Everyone here is made up.
    static let said: [(Side, String)] = [
        (.computer, "Okay, so we ship the beta to the first fifty teams on Thursday."),
        (.microphone, "That works if the import fix lands by Wednesday."),
        (.computer, "José, can you own that fix?"),
        (.computer, "Yes, I'll have it merged by Wednesday morning."),
        (.computer, "And Ana, the onboarding email?"),
        (.computer, "I'll draft it today and send it to Priya for a read."),
        (.microphone, "I can write the release notes. Priya, I'll send them to you by Wednesday noon."),
        (.computer, "Perfect. What about pricing for the beta?"),
        (.microphone, "Let's keep it free for the beta and decide pricing next week, after we see usage."),
        (.computer, "Agreed. Next week then."),
        (.computer, "One more thing: support. Who answers beta emails?"),
        (.microphone, "I'll take the first week, then we rotate."),
        (.computer, "Great. So Thursday ship, José on the fix, Ana on the email, Sam on notes and support."),
        (.computer, "Sounds right. Thanks, everyone."),
    ]

    /// Fills `root` with a few recordings, the newest the launch call; returns its folder.
    @discardableResult
    static func seed(_ root: URL, withNewest: Bool = true) -> URL? {
        let library = RecordingLibrary(root: root)
        try? library.prepareRoot()
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date()
        let samples: [(days: Int, minutes: Int, duration: Double, title: String?, people: RecordingEntry.People)] = [
            (0, 0, 0, nil, .init(count: 4, names: ["Priya Shah", "José Ortiz", "Ana"])),
            (-1, 30, 2710, "Design review", .init(count: 3, names: ["Priya Shah", "Mei"])),
            (-2, -120, 3305, "Weekly team sync", .init(count: 9)),
            (-3, 60, 1812, "Customer interview", .init(count: 2)),
            (-6, 0, 2266, "1:1 with Priya", .init(count: 2, names: ["Priya Shah"])),
        ]
        var newest: URL?
        // The launch call's lines, and its length to match them.
        var lines: [TranscriptLine] = []
        var start = 4.0
        for (side, text) in said {
            let length = Double(text.split(separator: " ").count) * 0.42 + 1
            lines.append(TranscriptLine(start: start, end: start + length, side: side, text: text))
            start += length + Double.random(in: 1...6)
        }
        for sample in samples where withNewest || sample.days != 0 {
            let day = calendar.date(byAdding: .day, value: sample.days, to: today) ?? today
            let started = day.addingTimeInterval(Double(sample.minutes) * 60)
            guard var folder = try? library.newFolder(at: started) else { continue }
            // AirPods throughout, so lines say which side they were heard on.
            let meta: [String: Any] = [
                "status": "recorded", "audio": "audio.m4a",
                "duration_seconds": sample.days == 0 ? (start + 3).rounded() : sample.duration,
                "started": ISO8601DateFormatter().string(from: started),
                "sources": ["microphone", "computer audio"], "output_headphones": true,
            ]
            try? JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
            FileManager.default.createFile(atPath: folder.appendingPathComponent("events.jsonl").path, contents: nil)
            try? RecordingLibrary.save(people: sample.people, in: folder)
            if sample.days == 0 {
                try? TranscriptDocument.save(lines: lines, failures: 0, pieces: lines.count, model: .large, in: folder)
                newest = folder
            } else if let title = sample.title, let renamed = try? RecordingLibrary.save(title: title, in: folder) {
                folder = renamed
            }
        }
        try? PeopleList(
            you: "Sam",
            people: [
                .init(name: "Priya Shah", context: "product lead"), .init(name: "José Ortiz", context: "engineering"),
                .init(name: "Ana", context: "marketing"), .init(name: "Mei", context: "design"),
            ]
        ).save(to: root)
        return newest
    }
}
