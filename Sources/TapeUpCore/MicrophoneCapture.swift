import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures the current default input. A new engine is built for each device,
/// because an engine bound to a device that went away does not recover.
final class MicrophoneCapture: @unchecked Sendable {
    struct NoInput: Error, CustomStringConvertible {
        var description: String { "no usable input device" }
    }

    private let sampleRate: Double
    private let sink: @Sendable (UInt64, [Float]) -> Void
    private let onConfigurationChange: @Sendable () -> Void
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    private(set) var inputName = "none"

    init(
        sampleRate: Double, sink: @escaping @Sendable (UInt64, [Float]) -> Void,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) {
        self.sampleRate = sampleRate
        self.sink = sink
        self.onConfigurationChange = onConfigurationChange
    }

    func start() throws {
        var device = CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard device != kAudioObjectUnknown else { throw NoInput() }
        inputName = CoreAudioSystem.name(of: device)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw NoInput() }

        let resampler = MonoResampler(sampleRate: sampleRate)
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            let host = when.isHostTimeValid ? when.hostTime : AudioGetCurrentHostTime()
            sink(host, resampler.process(buffer))
        }
        let onChange = onConfigurationChange
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in onChange() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
