import Foundation

/// System-audio capture permission. macOS has no public API to check or request
/// it, so this uses the TCC private framework the same way Apple's own sample
/// apps for process taps are commonly adapted. If the framework is missing,
/// the status is `.unknown` and capture simply proceeds.
public enum AudioCapturePermission {
    public enum Status: String { case authorized, denied, unknown }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request =
        @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }
    nonisolated(unsafe) private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    public static func status() -> Status {
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt when the user has not decided yet.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        guard let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { completion($0) }
    }
}
