import CoreAudio
import Foundation

/// Captures one input device, normally the system default, with its
/// timestamps moved back by the device's input latency.
final class MicrophoneCapture: @unchecked Sendable {
    let device: AudioDeviceID
    let name: String
    private var reader: DeviceInputReader?

    init(device: AudioDeviceID) {
        self.device = device
        name = CoreAudioSystem.name(of: device)
    }

    func start(sampleRate: Double, sink: @escaping DeviceInputReader.Sink, issue: @escaping @Sendable (String) -> Void)
        throws
    {
        let rate = CoreAudioSystem.nominalSampleRate(of: device)
        let latency = CoreAudioSystem.latencyFrames(of: device, input: true)
        let shift = rate > 0 ? -Int64(Double(latency) / rate * 1e9) : 0
        let reader = try DeviceInputReader(device: device, shiftNanos: shift, sink: sink, issue: issue)
        try reader.start(sampleRate: sampleRate)
        self.reader = reader
    }

    func stop() {
        reader?.stop()
        reader = nil
    }
}
