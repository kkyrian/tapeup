import CoreAudio
import Foundation

enum CoreAudioSystem {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default fallback: T
    ) -> T {
        var address = address(selector, scope)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return fallback }
        return result
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var text: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &text) == noErr, let text else { return nil }
        return text.takeRetainedValue() as String
    }

    static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        value(system, selector, default: AudioDeviceID(kAudioObjectUnknown))
    }

    static func name(of device: AudioDeviceID) -> String {
        guard device != kAudioObjectUnknown else { return "none" }
        return string(device, kAudioObjectPropertyName) ?? "device \(device)"
    }

    static func uid(of device: AudioDeviceID) -> String? {
        guard device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// The format of the device's first input stream, as delivered to an IOProc.
    static func firstInputStreamFormat(of device: AudioDeviceID) -> (
        stream: AudioObjectID, format: AudioStreamBasicDescription
    )? {
        guard let stream = objects(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).first else {
            return nil
        }
        let format = value(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else { return nil }
        return (stream, format)
    }

    /// Frames between the moment sound happens and the moment its timestamp
    /// names, for one direction of a device.
    static func latencyFrames(of device: AudioDeviceID, input: Bool) -> UInt32 {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        let deviceLatency: UInt32 = value(device, kAudioDevicePropertyLatency, scope, default: 0)
        let safety: UInt32 = value(device, kAudioDevicePropertySafetyOffset, scope, default: 0)
        let streamLatency: UInt32 =
            objects(device, kAudioDevicePropertyStreams, scope).first.map {
                value($0, kAudioStreamPropertyLatency, default: UInt32(0))
            } ?? 0
        return deviceLatency + safety + streamLatency
    }

    static func nominalSampleRate(of device: AudioDeviceID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: 0)
    }

    /// Whether an output plays into the listener's ears, so the microphone
    /// cannot hear it: wired headphones, AirPods and most Bluetooth audio.
    /// Speakers, displays and AirPlay count as not.
    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        let name = name(of: device).lowercased()
        // A speaker taken for headphones would put every line in the
        // transcript twice, so only names that say headphones count.
        let speakers = ["speaker", "pill", "homepod", "soundbar", "boom", "sonos", "flip", "charge", "soundlink"]
        if speakers.contains(where: name.contains) { return false }
        let headphones = [
            "airpods", "headphone", "headset", "earbud", "buds", "beats", "earphone", "pods", "quietcomfort",
            "wh-1000", "wf-1000",
        ]
        if headphones.contains(where: name.contains) { return true }
        switch value(device, kAudioDevicePropertyTransportType, default: UInt32(0)) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // Renamed AirPods ("Sam's") carry no telling name. Apple's
            // Bluetooth audio is earbuds and headphones; its model UID is
            // "<product> <vendor>" in hex, and Apple's vendor ID is 0x4C.
            return isAppleBluetooth(modelUID: string(device, kAudioDevicePropertyModelUID))
        case kAudioDeviceTransportTypeBuiltIn:
            let source = value(
                device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, default: UInt32(0))
            return source == 0x6864_706E  // 'hdpn'
        default:
            return false
        }
    }

    static func isAppleBluetooth(modelUID: String?) -> Bool {
        modelUID?.lowercased().split(separator: " ").last == "4c"
    }

    static func builtInInput() -> AudioDeviceID? {
        objects(system, kAudioHardwarePropertyDevices).first { device in
            value(device, kAudioDevicePropertyTransportType, default: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                && firstInputStreamFormat(of: device) != nil
        }
    }

    // MARK: - Listeners

    /// A property listener that stays registered until `remove()` is called.
    final class Listener: @unchecked Sendable {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let queue: DispatchQueue
        private let block: AudioObjectPropertyListenerBlock
        private var active = false

        init(
            object: AudioObjectID, selector: AudioObjectPropertySelector, queue: DispatchQueue,
            handler: @escaping @Sendable () -> Void
        ) {
            self.object = object
            self.queue = queue
            address = CoreAudioSystem.address(selector)
            block = { _, _ in handler() }
            active = AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr
        }

        func remove() {
            guard active else { return }
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
            active = false
        }

        deinit { remove() }
    }

    // MARK: - Leftovers

    /// Prefix shared by every aggregate device TapeUp creates; the owning
    /// process ID follows it, so a running recording's devices are never touched.
    static let aggregatePrefix = "tapeup-"
    static let tapNamePrefix = "TapeUp-"

    /// Removes aggregate devices and taps that a TapeUp process which is no
    /// longer running left behind. Earlier builds made them public, and a
    /// public one outlives a crashed process and shows up in other apps'
    /// device menus; the private ones made now vanish with the process.
    static func removeLeftovers() -> Int {
        func ownerIsGone(_ suffix: Substring) -> Bool {
            guard let pid = Int32(suffix.prefix { $0.isNumber }) else { return true }
            return pid != getpid() && kill(pid, 0) != 0 && errno == ESRCH
        }
        var removed = 0
        for device in objects(system, kAudioHardwarePropertyDevices) {
            guard let uid = uid(of: device), uid.hasPrefix(aggregatePrefix),
                ownerIsGone(uid.dropFirst(aggregatePrefix.count))
            else { continue }
            if AudioHardwareDestroyAggregateDevice(device) == noErr { removed += 1 }
        }
        for tap in objects(system, kAudioHardwarePropertyTapList) {
            var address = address(kAudioTapPropertyDescription)
            var description: Unmanaged<CATapDescription>?
            var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
            guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr,
                let name = description?.takeRetainedValue().name, name.hasPrefix(tapNamePrefix),
                ownerIsGone(name.dropFirst(tapNamePrefix.count))
            else { continue }
            if AudioHardwareDestroyProcessTap(tap) == noErr { removed += 1 }
        }
        return removed
    }
}
