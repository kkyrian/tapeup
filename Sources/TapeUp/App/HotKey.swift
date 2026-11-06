import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot-key API, which needs no
/// accessibility permission.
@MainActor
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &type, context, &handler)
        let id = EventHotKeyID(signature: OSType(0x5450_5550), id: 1)  // "TPUP"
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &reference)
        guard installed == noErr, registered == noErr else { return nil }
    }

    /// ⌥⌘R, shown on the Record and Stop buttons.
    static let recordShortcutLabel = "⌥⌘R"

    static func record(_ action: @escaping @MainActor () -> Void) -> HotKey? {
        HotKey(keyCode: kVK_ANSI_R, modifiers: optionKey | cmdKey, action: action)
    }
}
