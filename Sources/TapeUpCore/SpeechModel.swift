import Foundation
import IOKit.ps

/// The Qwen3-ASR model a Mac transcribes with, chosen by its memory: a model
/// qualifies when its measured peak fits in 40 % of RAM, and laptops on
/// battery use the lighter one.
public enum SpeechModel: String, Sendable, CaseIterable {
    case large
    case small

    public var id: String {
        switch self {
        case .large: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        case .small: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        }
    }

    /// The name the panel shows.
    public var name: String {
        switch self {
        case .large: "Qwen3-ASR 1.7B"
        case .small: "Qwen3-ASR 0.6B"
        }
    }

    /// Bytes to download, voice detection included.
    public var downloadBytes: Int64 {
        switch self {
        case .large: 2_467_854_870 + Self.voiceDetectorBytes
        case .small: 712_777_119 + Self.voiceDetectorBytes
        }
    }

    public static let voiceDetectorBytes: Int64 = 1_238_036

    /// Peak memory while transcribing, measured on real meetings.
    var peakBytes: UInt64 {
        switch self {
        case .large: 5_400_000_000
        case .small: 2_600_000_000
        }
    }

    /// The 0.6B falls into loops when given name hints, so only the 1.7B gets them.
    public var takesHints: Bool { self == .large }

    public static func choose(memoryBytes: UInt64, onBattery: Bool) -> SpeechModel {
        let fits = Double(SpeechModel.large.peakBytes) <= Double(memoryBytes) * 0.4
        return fits && !onBattery ? .large : .small
    }

    /// The model this Mac's memory allows: the one downloaded first.
    public static func forThisMac() -> SpeechModel {
        choose(memoryBytes: ProcessInfo.processInfo.physicalMemory, onBattery: false)
    }

    /// The model for a recording starting now: one lighter on battery.
    public static func forNow() -> SpeechModel {
        choose(memoryBytes: ProcessInfo.processInfo.physicalMemory, onBattery: PowerSource.onBattery())
    }
}

public enum PowerSource {
    /// True on Macs with a built-in battery.
    public static func hasBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    /// True when a laptop is running on its battery.
    public static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
