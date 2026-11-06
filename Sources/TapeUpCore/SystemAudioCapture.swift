import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays through a global Core Audio process tap.
///
/// The tap is read through a private aggregate device. When the default output
/// changes the recorder rebuilds this capture; the timeline turns the rebuild
/// into silence of the right length rather than a shift.
final class SystemAudioCapture: @unchecked Sendable {
    enum Mode: String {
        /// The aggregate also contains the default output device, which clocks it.
        case withOutput
        /// The aggregate contains only the tap.
        case tapOnly
    }

    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    private let mode: Mode
    private let sink: @Sendable (UInt64, [Float]) -> Void
    var diagnostic: @Sendable (String) -> Void = { _ in }
    private let ioQueue = DispatchQueue(label: "tapeup.system-audio.io", qos: .userInteractive)
    private let resampler: MonoResampler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    private(set) var outputName = "none"

    init(mode: Mode, sampleRate: Double, sink: @escaping @Sendable (UInt64, [Float]) -> Void) {
        self.mode = mode
        self.sink = sink
        resampler = MonoResampler(sampleRate: sampleRate)
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "TapeUp"
        description.isPrivate = false
        description.muteBehavior = .unmuted
        try check("create process tap", AudioHardwareCreateProcessTap(description, &tapID))

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            "read tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription))
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw Failure(step: "interpret tap format", status: -1)
        }

        let output = CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        outputName = CoreAudioSystem.name(of: output)
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapeUp",
            kAudioAggregateDeviceUIDKey: "tapeup-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        if mode == .withOutput, let uid = CoreAudioSystem.uid(of: output) {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = uid
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: uid]]
        }
        try check(
            "create aggregate device",
            AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let resampler = self.resampler
        let sink = self.sink
        let diagnostic = self.diagnostic
        nonisolated(unsafe) var reported = false
        try check(
            "create IO proc",
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, inputTime, _, _ in
                if !reported {
                    reported = true
                    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                    diagnostic(
                        "first callback: \(list.count) buffer(s), bytes \(list.map { $0.mDataByteSize }), "
                            + "channels \(list.map { $0.mNumberChannels }), tap format \(format)")
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                else {
                    sink(AudioGetCurrentHostTime(), [])
                    return
                }
                let time = inputTime.pointee
                let host =
                    time.mFlags.contains(.hostTimeValid) ? time.mHostTime : AudioGetCurrentHostTime()
                sink(host, resampler.process(buffer))
            })
        try check("start aggregate device", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw Failure(step: step, status: status)
        }
    }
}
