import AppKit
import SwiftUI
import TapeUpCore

/// `TapeUp shots --out <dir>`: GitHub's link preview, from the real panel
/// with made-up meetings. `TapeUp shots --demo <dir>` only makes the made-up
/// library, for running an agent against it. The README's journeys are
/// filmed by `TapeUp film`, which shares the parts here; `scripts/shots.sh`
/// runs both.
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
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tapeup-shots-\(UUID().uuidString)")
        let savedRoot = Settings.store.object(forKey: "recordingsRoot")
        func restore() {
            if let savedRoot {
                Settings.store.set(savedRoot, forKey: "recordingsRoot")
            } else {
                Settings.store.removeObject(forKey: "recordingsRoot")
            }
            try? FileManager.default.removeItem(at: root)
        }
        seed(root, withNewest: false)
        let model = AppModel()
        let devices = (microphone: "AirPods Pro", output: "MacBook Pro Speakers")
        let lanes = Lanes()

        // Recording, the latest words in the Transcript row.
        model.root = root
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

        print(outURL.path)
        restore()
        exit(0)
    }

    /// Claude Code's real answer to the sample recording; scripts/shots/README.md says how it was made.
    static var handoff: String? { try? String(contentsOfFile: "scripts/shots/handoff.md", encoding: .utf8) }

    static func lastTwoSentences(_ text: String) -> [String] {
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
    @MainActor struct Lanes {
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

    enum StatusLook {
        case idle
        case recording(String)
    }

    /// The system pointer's shape, tip at the top left.
    struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            let w = rect.width / 13
            let h = rect.height / 20
            var path = Path()
            let points: [(CGFloat, CGFloat)] = [
                (0, 0), (0, 16.5), (4, 12.6), (6.8, 19), (9.3, 18), (6.6, 11.8), (12, 11.8),
            ]
            path.move(to: CGPoint(x: rect.minX + points[0].0 * w, y: rect.minY + points[0].1 * h))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: rect.minX + point.0 * w, y: rect.minY + point.1 * h))
            }
            path.closeSubpath()
            return path
        }
    }

    /// Flat surfaces only, from the product's own materials: the page
    /// GitHub shows the picture on, and a quiet desktop under the menu bar.
    enum Palette {
        static func page(_ dark: Bool) -> Color {
            dark ? Color(red: 0.051, green: 0.067, blue: 0.090) : .white
        }
        static func desktop(_ dark: Bool) -> Color {
            dark ? Color(red: 0.145, green: 0.145, blue: 0.155) : Color(red: 0.925, green: 0.925, blue: 0.93)
        }
        static func menuBar(_ dark: Bool) -> Color {
            dark ? Color(red: 0.10, green: 0.10, blue: 0.11) : Color(red: 0.975, green: 0.975, blue: 0.98)
        }
        static func hairline(_ dark: Bool) -> Color { dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10) }
        /// The app icon's graphite.
        static let graphite = Color(red: 0.086, green: 0.086, blue: 0.094)
    }

    struct MenuBar: View {
        let dark: Bool
        let status: StatusLook
        let wide: Bool
        /// Clicked: the item darkens, as the real one does while its panel opens.
        var pressed = false

        /// Two minutes after the sample call began, in this Mac's own format.
        private var clock: String {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
            let start = Calendar.current.date(bySettingHour: 14, minute: 2, second: 0, of: Date()) ?? Date()
            return formatter.string(from: start)
        }

        var body: some View {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Palette.menuBar(dark))
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline(dark)).frame(height: 0.5) }
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
                    Text(clock)
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
                    .fill(
                        dark ? Color.white.opacity(pressed ? 0.24 : 0.16) : Color.black.opacity(pressed ? 0.14 : 0.08)))
        }
    }

    /// The menu-bar glyph, as AppDelegate draws it.
    struct Cassette: Shape {
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
    struct Terminal: View {
        let text: String
        /// What is being typed at the prompt, under the text, with a caret.
        var typing: String?
        /// In a film the window sits on the desktop, not on the page.
        var compact = false
        var width: CGFloat = 760
        var height: CGFloat?
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
                // With a height, a terminal: text starts at the top, and once
                // it fills the window the oldest lines scroll off.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
                    if let typing { prompt(typing) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 24)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: height.map { $0 - 36 }, alignment: .top)
                .frame(height: height.map { $0 - 36 }, alignment: .bottom)
                .clipped()
            }
            .frame(width: width, alignment: .leading)
            .background(Color(red: 0.11, green: 0.115, blue: 0.13), in: .rect(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .padding(compact ? 0 : 32)
            .environment(\.colorScheme, .dark)
        }

        /// The prompt: the first line after `>`, the rest indented, then a caret.
        private func prompt(_ typed: String) -> some View {
            let lines = typed.components(separatedBy: "\n")
            let blue = Color(red: 0.62, green: 0.72, blue: 1.0)
            return VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                    HStack(spacing: 0) {
                        line((index == 0 ? "> " : "  ") + text, color: blue)
                        if index == lines.count - 1 {
                            Rectangle().fill(blue.opacity(0.8)).frame(width: 7.5, height: 15)
                        }
                    }
                }
            }
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
                Palette.graphite
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
