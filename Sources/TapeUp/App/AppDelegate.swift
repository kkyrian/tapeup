import AppKit
import Observation
import TapeUpCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var hotKey: HotKey?
    private var commands: NSObjectProtocol?
    private var floating: FloatingControls!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TapeUp"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        button.setAccessibilityLabel("TapeUp")
        panel = PanelController(model: model, anchor: button)
        floating = FloatingControls(model: model) { [weak self] in self?.stopShowingCard() }
        hotKey = HotKey.record { [weak self] in self?.shortcutPressed() }
        commands = CommandLink.listen(model)
        if hotKey == nil { model.shortcutLabel = nil }
        renderStatusItem()
        model.recoverLeftovers()
        model.agents.refresh()

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
        guard model.phase != .idle else { return .terminateNow }
        if model.isRecording {
            model.stop { NSApp.reply(toApplicationShouldTerminate: true) }
        } else {
            waitForSave { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func waitForSave(_ done: @escaping @MainActor () -> Void) {
        guard model.phase != .idle else { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForSave(done) }
    }

    @objc private func statusItemClicked() {
        model.agents.refresh()
        guard NSApp.currentEvent?.type == .rightMouseDown else { return panel.toggle() }
        panel.close()
        statusItem.menu = appMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// The same app-wide items as the panel's ··· menu, on right-click.
    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, on: Bool? = nil, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            if let on { item.state = on ? .on : .off }
            return item
        }
        menu.addItem(
            item("People…") { [weak self] in
                self?.model.openPeople()
                self?.panel.show()
            })
        let folder = item("Change Recordings Folder…") { [weak self] in
            guard let self else { return }
            FolderChooser.choose(model: model)
        }
        folder.isEnabled = model.phase == .idle
        menu.addItem(folder)
        menu.addItem(
            item("Floating Controls While Recording", on: model.showsFloatingControls) { [weak self] in
                self?.model.showsFloatingControls.toggle()
            })
        menu.addItem(
            item("Open at Login", on: model.launchAtLogin) { [weak self] in
                guard let self else { return }
                model.launchAtLogin.toggle()
            })
        let agent = NSMenuItem(title: "Agent", action: nil, keyEquivalent: "")
        let agents = NSMenu()
        agents.autoenablesItems = false
        let caption = NSMenuItem(title: "Suggests titles and names", action: nil, keyEquivalent: "")
        caption.isEnabled = false
        agents.addItem(caption)
        for row in model.agents.rows {
            let entry = item(row.title, on: row.checked ? true : nil, row.action)
            entry.isEnabled = row.enabled
            agents.addItem(entry)
        }
        agent.submenu = agents
        menu.insertItem(agent, at: 1)
        menu.addItem(.separator())
        menu.addItem(item("Quit TapeUp") { NSApp.terminate(nil) })
        menu.autoenablesItems = false
        return menu
    }

    private func shortcutPressed() {
        if model.isRecording { stopShowingCard() } else { model.toggle() }
    }

    /// Stops from the shortcut or the floating controls: the saved card drops
    /// down without taking focus.
    private func stopShowingCard() {
        model.stop()
        if !panel.isVisible { panel.show(takingFocus: false) }
    }

    /// Redraws the menu-bar item whenever the phase or the clock changes.
    private func renderStatusItem() {
        withObservationTracking {
            draw()
            floating.update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.renderStatusItem() }
        }
    }

    /// The menu-bar glyph: a cassette, drawn to sit with the system's own icons.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let body = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 2.5, width: 17, height: 11), xRadius: 2.5, yRadius: 2.5)
            body.lineWidth = 1.5
            body.stroke()
            for x in [6.5, 13.5] {
                let reel = NSBezierPath(ovalIn: NSRect(x: x - 2, y: 6, width: 4, height: 4))
                reel.lineWidth = 1.4
                reel.stroke()
            }
            let tape = NSBezierPath()
            tape.move(to: NSPoint(x: 8.5, y: 8))
            tape.line(to: NSPoint(x: 11.5, y: 8))
            tape.lineWidth = 1.4
            tape.stroke()
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
            statusItem.length = NSStatusItem.variableLength
            button.image = Self.glyph
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("TapeUp")
        case .recording, .saving:
            let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold)
                .applying(.init(paletteColors: [model.paused ? .secondaryLabelColor : .systemRed]))
            let dot = NSImage(
                systemSymbolName: model.paused ? "pause.fill" : "circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            button.image = dot
            button.imagePosition = .imageLeading
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let text = " " + Format.duration(model.elapsed)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
            // A fixed width per hour of length, so the menu bar does not
            // shift as the seconds tick or at ten minutes.
            let widest = " " + (model.elapsed >= 3600 ? "00:00:00" : "00:00")
            let textWidth = ceil((widest as NSString).size(withAttributes: [.font: font]).width)
            statusItem.length = textWidth + 22
            button.setAccessibilityLabel(
                "TapeUp, \(model.paused ? "paused" : "recording"), \(Format.spokenDuration(model.elapsed))")
        }
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func runAction() { run() }
}
