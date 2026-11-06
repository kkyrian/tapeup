import AppKit
import SwiftUI

/// The window that drops from the menu-bar item. A non-activating panel, so
/// opening it, or showing the saved card after a shortcut stop, never takes
/// focus from the call.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: Panel
    private let model: AppModel
    private weak var anchor: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    /// The display the panel opened on, kept while it stays open.
    private var target: NSScreen?
    /// The height the SwiftUI content asks for; the window always matches it.
    private(set) var contentHeight: CGFloat = 200

    init(model: AppModel, anchor: NSStatusBarButton) {
        self.model = model
        self.anchor = anchor
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.delegate = self

        var resized: @MainActor (CGFloat) -> Void = { _ in }
        let host = NSHostingView(
            rootView: PanelView(model: model, close: { [weak self] in self?.close() }, resized: { resized($0) }))
        host.sizingOptions = []
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        // Plain autoresizing, no constraints: constraints let the hosting view
        // resize the window's content on top of each window resize, so the
        // panel drew one height change too far (cut off, or see-through).
        background.frame = NSRect(x: 0, y: 0, width: PanelView.width, height: 200)
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        model.focusPanel = { [weak self] in
            self?.panel.makeKey()
            self?.model.panelFocused = true
        }
        resized = { [weak self] height in
            guard let self, abs(height - contentHeight) > 0.5 else { return }
            contentHeight = height
            if isVisible { position() }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSPanel { panel }

    /// When a click outside last closed the panel. A click on the menu-bar
    /// icon reaches that monitor first; without this, the icon's own click
    /// would open the panel again, so a second click flashed instead of closing.
    private var closedByOutsideClick = Date.distantPast

    func toggle() {
        if isVisible { return close() }
        guard Date().timeIntervalSince(closedByOutsideClick) > 0.3 else { return }
        show()
    }

    /// - Parameter takingFocus: false when the panel appears on its own (after
    ///   a shortcut stop): it then becomes key only if the user clicks a field.
    func show(takingFocus: Bool = true) {
        model.refreshAccess()
        model.reload()
        if model.card?.justRecorded == false, !isVisible { model.closeCard() }
        panel.contentView?.layoutSubtreeIfNeeded()
        target = nil
        position()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if takingFocus { panel.makeKey() }
        model.panelFocused = takingFocus
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        model.panelVisible = true
        anchor?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.closedByOutsideClick = Date()
                self.close()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === panel else { return event }
            if event.keyCode == 53 {  // Escape
                MainActor.assumeIsolated { self.close() }
                return nil
            }
            return event
        }
    }

    func close() {
        guard isVisible else { return }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
        panel.orderOut(nil)
        model.panelVisible = false
        anchor?.highlight(false)
        // A card for a finished recording stays only until the panel closes.
        if model.card?.finishing == false { model.closeCard() }
    }

    /// Keeps the panel's top edge under the menu-bar item as its height changes.
    ///
    /// With several displays each menu bar shows the item, but the button
    /// reports only one of them, so the panel goes to the display under the
    /// pointer, at the same distance from its right edge.
    func position() {
        guard let button = anchor, let window = button.window, let home = window.screen ?? NSScreen.main else {
            return
        }
        if target == nil {
            target = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? home
        }
        let screen = target ?? home
        let size = NSSize(width: PanelView.width, height: contentHeight)
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        let fromRight = home.frame.maxX - buttonFrame.midX
        // Menu bars differ in height (a notched display's is taller).
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let belowTop = menuBar > 0 ? menuBar : home.frame.maxY - buttonFrame.minY
        let visible = screen.visibleFrame
        var x = screen.frame.maxX - fromRight - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let top = screen.frame.maxY - belowTop - 6
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
    }
}

/// Lets the borderless panel take keyboard focus for the names field.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
