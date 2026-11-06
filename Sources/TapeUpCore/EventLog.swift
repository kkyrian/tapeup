import Foundation

/// Append-only JSON Lines log of what happened during a recording.
public final class EventLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()
    private let start = Date()

    public init(url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    public func record(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["t"] = (Date().timeIntervalSince(start) * 1000).rounded() / 1000
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        handle?.write(data)
        FileHandle.standardError.write(data)
    }
}
