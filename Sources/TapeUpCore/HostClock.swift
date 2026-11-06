import CoreAudio
import Foundation

/// Converts Core Audio host times to frames on the recording's clock.
public struct HostClock: Sendable {
    public let startHostTime: UInt64
    public let sampleRate: Double

    public init(startHostTime: UInt64 = AudioGetCurrentHostTime(), sampleRate: Double) {
        self.startHostTime = startHostTime
        self.sampleRate = sampleRate
    }

    public func frame(atHostTime hostTime: UInt64) -> Int64 {
        let nanos =
            Double(AudioConvertHostTimeToNanos(hostTime))
            - Double(AudioConvertHostTimeToNanos(startHostTime))
        return Int64((nanos / 1e9 * sampleRate).rounded())
    }

    public func nowFrame() -> Int64 { frame(atHostTime: AudioGetCurrentHostTime()) }

    public func seconds(atHostTime hostTime: UInt64) -> Double {
        Double(frame(atHostTime: hostTime)) / sampleRate
    }
}
