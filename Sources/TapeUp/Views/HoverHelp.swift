import AppKit
import SwiftUI

extension View {
    /// Help text that appears a fifth of a second after the pointer arrives.
    /// macOS tooltips (`.help`) never show in TapeUp's panels, because they
    /// open without making TapeUp the active app.
    func hoverHelp(_ text: String) -> some View { modifier(HoverHelpOwner(text: text)) }
}

private struct HoverHelpOwner: ViewModifier {
    let text: String
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                // Empty help is none.
                if inside, !text.isEmpty { HoverHelp.shared.show(text, for: id) } else { HoverHelp.shared.hide(id) }
            }
            .onDisappear { HoverHelp.shared.hide(id) }
            .accessibilityHint(text)
    }
}

/// The one small window that shows hover help, under the pointer like a
/// macOS tooltip, above the pointer near the bottom of the screen.
@MainActor
final class HoverHelp {
    static let shared = HoverHelp()

    private let window: NSPanel
    private var owner: UUID?
    private var pending: DispatchWorkItem?
    private var clickMonitor: Any?

    private init() {
        window = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false
        // A click acts on the button, so its help gets out of the way.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { HoverHelp.shared.hide() }
            return event
        }
    }

    func show(_ text: String, for owner: UUID) {
        pending?.cancel()
        self.owner = owner
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(text) }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (window.isVisible ? 0 : 0.2), execute: item)
    }

    /// Hides `owner`'s help, or whatever shows when nil. Leaving one button
    /// after entering the next leaves the next one's help alone.
    func hide(_ owner: UUID? = nil) {
        guard owner == nil || owner == self.owner else { return }
        pending?.cancel()
        pending = nil
        self.owner = nil
        window.orderOut(nil)
    }

    private func present(_ text: String) {
        // Up to 320 points of text wide, wrapping beyond that.
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 320, height: 1000), options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: Label.fontSize)])
        let size = NSSize(
            width: ceil(bounds.width) + 2 * Label.inset.width + 2, height: ceil(bounds.height) + 2 * Label.inset.height)
        let host = NSHostingView(rootView: Label(text: text))
        host.sizingOptions = []
        window.contentView = host
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: pointer.x - 4, y: pointer.y - 24 - size.height)
        if origin.y < visible.minY + 4 { origin.y = pointer.y + 10 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }

    private struct Label: View {
        static let fontSize: CGFloat = 11
        static let inset = CGSize(width: 7, height: 4)
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: Self.fontSize))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.horizontal, Self.inset.width)
                .padding(.vertical, Self.inset.height)
                .background(.regularMaterial, in: .rect(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}
