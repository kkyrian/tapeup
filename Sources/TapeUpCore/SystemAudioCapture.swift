import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays through a global Core Audio process tap,
/// read through an aggregate device that contains only the tap.
///
/// The tap and aggregate are private to this process, so no other app lists
/// or can choose them, and they vanish with the process. The aggregate does
/// not use tap auto-start: a private aggregate with it waits for a tapped app
/// to play before it runs, so a silent Mac would deliver nothing and the
/// recorder would take the capture for broken.
final class SystemAudioCapture: @unchecked Sendable {
    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var reader: DeviceInputReader?

    private(set) var outputName = "none"

    func start(sampleRate: Double, sink: @escaping DeviceInputReader.Sink, issue: @escaping @Sendable (String) -> Void)
        throws
    {
        let pid = getpid()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "\(CoreAudioSystem.tapNamePrefix)\(pid)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("create process tap", AudioHardwareCreateProcessTap(description, &tapID))

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapeUp",
            kAudioAggregateDeviceUIDKey: "\(CoreAudioSystem.aggregatePrefix)\(pid)-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try check(
            "create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // The tap hears audio before the output device plays it; shift its
        // timestamps by the output latency so they line up with what the
        // listener heard and answered.
        let output = CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        outputName = CoreAudioSystem.name(of: output)
        let outputRate = CoreAudioSystem.nominalSampleRate(of: output)
        let latency = CoreAudioSystem.latencyFrames(of: output, input: false)
        let shift = outputRate > 0 ? Int64(Double(latency) / outputRate * 1e9) : 0
        do {
            let reader = try DeviceInputReader(device: aggregateID, shiftNanos: shift, sink: sink, issue: issue)
            try reader.start(sampleRate: sampleRate)
            self.reader = reader
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        reader?.stop()
        reader = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw DeviceInputReader.Failure(step: step, status: status)
        }
    }
}
