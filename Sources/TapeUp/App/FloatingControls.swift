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
        let size = NSSize(width: FloatingControlsView.width, height: 40)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
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
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: FloatingControlsView(model: model, stop: stop))
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host)
        panel.contentView = background
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                UserDefaults.standard.set(NSStringFromPoint(self.panel.frame.origin), forKey: Self.originKey)
            }
        }
    }

    var window: NSPanel { panel }

    /// Shows or hides the pill to match the model.
    func update() {
        let wanted = model.isRecording && model.showsFloatingControls
        if wanted, !panel.isVisible {
            panel.setFrameOrigin(origin())
            panel.orderFrontRegardless()
        } else if !wanted, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// The remembered place if it is still on a screen, otherwise the top
    /// right of the main screen.
    private func origin() -> NSPoint {
        let size = panel.frame.size
        if let text = UserDefaults.standard.string(forKey: Self.originKey) {
            let saved = NSPointFromString(text)
            let frame = NSRect(origin: saved, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) { return saved }
        }
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16)
    }
}

struct FloatingControlsView: View {
    /// Sized for the longest time it shows, so it never grows mid-recording.
    static let width: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let time = ceil(("0:00:00" as NSString).size(withAttributes: [.font: font]).width)
        return 10 + 8 + 6 + time + 8 + 28 + 2 + 28 + 6
    }()

    @Bindable var model: AppModel
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RecordingDot(active: !model.paused)
                .padding(.leading, 10)
                .padding(.trailing, 6)
            Text(Format.duration(model.elapsed))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(model.paused ? .secondary : .primary)
            Spacer(minLength: 8)
            IconButton(
                symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause", size: 28,
                action: model.togglePause)
            IconButton(symbol: "stop.fill", help: "Stop and save", size: 28, tinted: true, action: stop)
                .padding(.leading, 2)
                .padding(.trailing, 6)
        }
        .frame(width: Self.width, height: 40)
        .focusEffectDisabled()
    }
}
