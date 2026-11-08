import AppKit
import SwiftUI
import TapeUpCore

/// The import window: small, movable, and above other windows while the
/// user gathers files from Finder, which the menu-bar panel cannot do (it
/// closes on a click elsewhere).
@MainActor
final class ImportWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let imports: Imports

    init(model: AppModel) {
        imports = Imports(model: model)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ImportView.width, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        // Only Close shows beside the title.
        window.title = "Import"
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        let host = NSHostingController(
            rootView: ImportView(imports: imports, choose: { [weak self] in self?.choose() }))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        imports.close = { [weak self] in self?.window.performClose(nil) }
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the window, adding `urls` to its list.
    func show(adding urls: [URL] = []) {
        if !window.isVisible {
            if !imports.importing { imports.reset() }
            window.center()
        }
        imports.add(urls)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Nothing starts focused: AppKit would ring Choose Files… on open.
        window.makeFirstResponder(nil)
        DispatchQueue.main.async { [window] in window.makeFirstResponder(nil) }
    }

    /// Choose Files…, as a sheet on this window.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = RecordingImport.contentTypes
        panel.prompt = "Add"
        panel.message = "Choose recordings, or folders of them."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.imports.add(panel.urls) }
        }
    }
}

/// Files dropped on the menu-bar icon open the import window with them.
@MainActor
final class StatusItemDrop: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let onDrop: ([URL]) -> Void

    init(button: NSStatusBarButton, onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init()
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(sender)
        guard !dropped.isEmpty else { return false }
        onDrop(dropped)
        return true
    }
}
