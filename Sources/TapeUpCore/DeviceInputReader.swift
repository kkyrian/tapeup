import AVFoundation
import CoreAudio
import Foundation

/// Reads the first input stream of one Core Audio device through an IOProc,
/// downmixed to mono and resampled to the recording rate.
///
/// Used for the microphone and for the system-audio tap alike. Reading the
/// device directly, rather than through AVAudioEngine, keeps the output side
/// out of it: an engine also opens the default output, which with AirPods
/// flips them in and out of call mode and restarts the engine in a loop.
final class DeviceInputReader: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// Receives the corrected host time of the chunk's first frame (nil when
    /// the device gave none) and its samples.
    typealias Sink = @Sendable (UInt64?, [Float]) -> Void

    let device: AudioDeviceID
    let deviceRate: Double
    private let format: AVAudioFormat
    private let buffersPerFrame: Int
    private let shiftNanos: Int64
    private let sink: Sink
    private let issue: @Sendable (String) -> Void
    private let ioQueue = DispatchQueue(label: "tapeup.device-input", qos: .userInteractive)
    private var procID: AudioDeviceIOProcID?
    private var list: UnsafeMutableAudioBufferListPointer?

    /// - Parameter shiftNanos: added to each timestamp so it names the moment
    ///   the sound happened; negative for input latency, positive for audio
    ///   that will still pass through an output device.
    init(
        device: AudioDeviceID, shiftNanos: Int64, sink: @escaping Sink,
        issue: @escaping @Sendable (String) -> Void
    ) throws {
        guard let (_, description) = CoreAudioSystem.firstInputStreamFormat(of: device) else {
            throw Failure(step: "read input stream format", status: -1)
        }
        var streamDescription = description
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw Failure(step: "interpret input stream format", status: -1)
        }
        self.device = device
        self.format = format
        deviceRate = description.mSampleRate
        buffersPerFrame = format.isInterleaved ? 1 : Int(format.channelCount)
        self.shiftNanos = shiftNanos
        self.sink = sink
        self.issue = issue
    }

    func start(sampleRate: Double) throws {
        let resampler = MonoResampler(sampleRate: sampleRate)
        let format = self.format
        let count = buffersPerFrame
        let sink = self.sink
        let issue = self.issue
        let shift = shiftNanos
        let list = AudioBufferList.allocate(maximumBuffers: count)
        self.list = list
        nonisolated(unsafe) var reportedShortList = false
        nonisolated(unsafe) var reportedUnreadable = false

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, ioQueue) { _, input, inputTime, _, _ in
            let delivered = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard delivered.count >= count else {
                if !reportedShortList {
                    reportedShortList = true
                    issue("expected \(count) buffer(s), got \(delivered.count)")
                }
                return
            }
            for index in 0..<count { list[index] = delivered[index] }
            guard
                let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer, deallocator: nil)
            else { return }
            let samples = resampler.process(buffer)
            if samples.isEmpty, buffer.frameLength > 0, !reportedUnreadable {
                reportedUnreadable = true
                issue("could not read buffers in format \(format)")
            }
            let time = inputTime.pointee
            let host: UInt64? =
                time.mFlags.contains(.hostTimeValid)
                ? UInt64(clamping: Int64(clamping: time.mHostTime) + Self.hostTicks(nanos: shift)) : nil
            sink(host, samples)
        }
        guard status == noErr else {
            stop()
            throw Failure(step: "create IO proc", status: status)
        }
        let started = AudioDeviceStart(device, procID)
        guard started == noErr else {
            stop()
            throw Failure(step: "start device", status: started)
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
            // Let a callback already queued finish, so nothing arrives after stop.
            ioQueue.sync {}
        }
        list?.unsafeMutablePointer.deallocate()
        list = nil
    }

    static func hostTicks(nanos: Int64) -> Int64 {
        let magnitude = Int64(clamping: AudioConvertNanosToHostTime(UInt64(nanos.magnitude)))
        return nanos < 0 ? -magnitude : magnitude
    }
}
