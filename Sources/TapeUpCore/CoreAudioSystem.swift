import CoreAudio
import Foundation

enum CoreAudioSystem {
    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    static func name(of device: AudioDeviceID) -> String {
        guard device != kAudioObjectUnknown else { return "none" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return "device \(device)" }
        return name.takeRetainedValue() as String
    }

    static func uid(of device: AudioDeviceID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Removes aggregate devices and taps a previous TapeUp process left behind.
    /// Public taps and aggregates outlive a crashed process, and a leftover one
    /// shows up in other apps' device menus.
    static func removeLeftovers(aggregatePrefix: String, tapName: String) -> Int {
        var removed = 0
        for device in objects(kAudioHardwarePropertyDevices) where uid(of: device)?.hasPrefix(aggregatePrefix) == true {
            if AudioHardwareDestroyAggregateDevice(device) == noErr { removed += 1 }
        }
        for tap in objects(kAudioHardwarePropertyTapList) {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var description: Unmanaged<CATapDescription>?
            var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
            guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr,
                description?.takeRetainedValue().name == tapName
            else { continue }
            if AudioHardwareDestroyProcessTap(tap) == noErr { removed += 1 }
        }
        return removed
    }

    /// Calls `handler` on `queue` whenever the system default for `selector` changes.
    @discardableResult
    static func onDefaultChange(
        _ selector: AudioObjectPropertySelector, queue: DispatchQueue, handler: @escaping @Sendable () -> Void
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in
            handler()
        }
    }
}
