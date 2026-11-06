import CoreAudio
import Foundation

/// The default devices, for showing which ones a recording will use.
public enum AudioDevices {
    public static func defaultInputName() -> String {
        CoreAudioSystem.name(of: CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
    }

    public static func defaultOutputName() -> String {
        CoreAudioSystem.name(of: CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    }

    /// Removes audio devices a crashed TapeUp left behind; returns how many.
    @discardableResult
    public static func removeLeftovers() -> Int { CoreAudioSystem.removeLeftovers() }

    /// Calls `handler` on `queue` whenever the default input or output changes,
    /// until the returned observation is cancelled or released.
    public static func observeDefaults(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void)
        -> Observation
    {
        Observation(
            listeners: [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
                CoreAudioSystem.Listener(object: CoreAudioSystem.system, selector: $0, queue: queue, handler: handler)
            })
    }

    public final class Observation: @unchecked Sendable {
        private let listeners: [CoreAudioSystem.Listener]
        init(listeners: [CoreAudioSystem.Listener]) { self.listeners = listeners }
        public func cancel() { for listener in listeners { listener.remove() } }
    }
}
