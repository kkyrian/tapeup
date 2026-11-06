import AppKit
import Observation
import TapeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TapeUp"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.setAccessibilityLabel("TapeUp")
        panel = PanelController(model: model, anchor: button)
        hotKey = HotKey.record { [weak self] in self?.shortcutPressed() }
        renderStatusItem()
        model.recoverLeftovers()

        // A menu-bar app that shows nothing on first launch looks broken.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording || model.card?.finishing == true else { return .terminateNow }
        if model.isRecording {
            model.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        } else {
            waitForSave { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func waitForSave(_ done: @escaping @MainActor () -> Void) {
        guard model.card?.finishing == true else { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForSave(done) }
    }

    @objc private func statusItemClicked() {
        panel.toggle()
    }

    private func shortcutPressed() {
        let wasRecording = model.isRecording
        model.toggle()
        // Show the saved card without taking focus; starting stays quiet.
        if wasRecording, !panel.isVisible { panel.show() }
    }

    /// Redraws the menu-bar item whenever the phase or the clock changes.
    private func renderStatusItem() {
        withObservationTracking {
            draw()
        } onChange: { [weak self] in
            Task { @MainActor in self?.renderStatusItem() }
        }
    }

    /// The menu-bar glyph: a dot and two lanes, like the app icon.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 19, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 5.5, width: 5, height: 5)).fill()
            let top: [CGFloat] = [3.5, 5.5, 7, 4.5, 6]
            let bottom: [CGFloat] = [2, 4, 5.5, 3, 2]
            for (index, (high, low)) in zip(top, bottom).enumerated() {
                let x = 7.5 + CGFloat(index) * 2.4
                for (height, center) in [(high, 11.8), (low, 4.2)] {
                    let rect = NSRect(x: x, y: center - height / 2, width: 1.7, height: max(1.7, height))
                    NSBezierPath(roundedRect: rect, xRadius: 0.85, yRadius: 0.85).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TapeUp"
        return image
    }()

    private func draw() {
        guard let button = statusItem.button else { return }
        switch model.phase {
        case .idle:
            button.image = Self.glyph
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("TapeUp")
        case .recording, .saving:
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            button.image = dot
            button.imagePosition = .imageLeading
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let text = " " + Format.duration(model.elapsed)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
            button.setAccessibilityLabel("TapeUp, recording, \(Format.spokenDuration(model.elapsed))")
        }
    }
}
