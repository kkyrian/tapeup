import AppKit
import SwiftUI

/// A small pill that floats over every window while recording: the time,
/// Pause and Stop. Easier to find than the menu bar; drag it anywhere, and it
/// remembers where.
@MainActor
final class FloatingControls {
    private let model: AppModel
    private let panel: NSPanel
    private static let originKey = "floatingControlsOrigin"

    init(model: AppModel, stop: @escaping @MainActor () -> Void) {
        self.model = model
        let size = NSSize(width: FloatingControlsView.width, height: FloatingControlsView.height)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = .roundedMask(radius: size.height / 2, continuous: false)
        var drag: @MainActor (CGSize, Bool) -> Void = { _, _ in }
        let host = NSHostingView(rootView: FloatingControlsView(model: model, stop: stop, drag: { drag($0, $1) }))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        drag = { [weak self] moved, ended in self?.drag(moved: moved, ended: ended) }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: Self.originKey)
            }
        }
    }

    var window: NSPanel { panel }

    /// Where the pointer and the pill were when a drag began.
    private var dragStart: (pointer: NSPoint, origin: NSPoint)?

    /// - Parameter moved: how far the pointer had gone when the drag was first
    ///   noticed, so the pill keeps the spot it was grabbed by.
    private func drag(moved: CGSize, ended: Bool) {
        let pointer = NSEvent.mouseLocation
        let start =
            dragStart ?? (NSPoint(x: pointer.x - moved.width, y: pointer.y + moved.height), panel.frame.origin)
        dragStart = ended ? nil : start
        var origin = NSPoint(
            x: start.origin.x + pointer.x - start.pointer.x, y: start.origin.y + pointer.y - start.pointer.y)
        // It stays whole on the display under the pointer.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? panel.screen
            ?? NSScreen.main
        {
            let visible = screen.visibleFrame.insetBy(dx: 4, dy: 4)
            let size = panel.frame.size
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    /// Shows or hides the pill to match the model.
    func update() {
        let wanted = model.isRecording && model.showsFloatingControls
        if wanted, !panel.isVisible {
            panel.setFrameOrigin(origin())
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().alphaValue = 1
            }
        } else if !wanted, panel.isVisible {
            panel.orderOut(nil)
            HoverHelp.shared.hide()
        }
    }

    /// The remembered place if it is still on a screen, otherwise centered
    /// just under the menu bar, where the eye already goes.
    private func origin() -> NSPoint {
        let size = panel.frame.size
        if let text = UserDefaults.standard.string(forKey: Self.originKey) {
            let saved = NSPointFromString(text)
            let frame = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return saved }
        }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10)
    }
}

struct FloatingControlsView: View {
    static let height: CGFloat = 30
    /// Sized for the longest time it shows, so it never grows mid-recording.
    static let width: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let time = ceil(("0:00:00" as NSString).size(withAttributes: [.font: font]).width)
        return 10 + 7 + 5 + time + 4 + 22 + 1 + 22 + 4
    }()

    @Bindable var model: AppModel
    let stop: () -> Void
    /// Called as the pill is dragged, with how far it has gone; true when it ends.
    let drag: (CGSize, Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            RecordingDot(active: !model.paused)
                .scaleEffect(0.875)
                .padding(.leading, 10)
                .padding(.trailing, 5)
            Text(Format.duration(model.elapsed))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.paused ? .secondary : .primary)
            Spacer(minLength: 4)
            IconButton(
                symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause", size: 22,
                action: model.togglePause)
            IconButton(symbol: "stop.fill", help: "Stop and save", size: 22, tinted: true, action: stop)
                .padding(.leading, 1)
                .padding(.trailing, 4)
        }
        .frame(width: Self.width, height: Self.height)
        // Everywhere but the buttons drags the pill.
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag($0.translation, false) }
                .onEnded { drag($0.translation, true) }
        )
        .focusEffectDisabled()
    }
}
