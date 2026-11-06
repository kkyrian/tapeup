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

        var reposition: @MainActor () -> Void = {}
        let host = NSHostingView(
            rootView: PanelView(model: model, close: { [weak self] in self?.close() }, resized: { reposition() }))
        host.sizingOptions = [.intrinsicContentSize]
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        background.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        reposition = { [weak self] in
            guard let self, isVisible else { return }
            position()
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? close() : show() }

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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        model.panelVisible = true
        anchor?.highlight(true)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
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
        let size = panel.contentView?.fittingSize ?? panel.frame.size
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
    }
}

/// Lets the borderless panel take keyboard focus for the names field.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
