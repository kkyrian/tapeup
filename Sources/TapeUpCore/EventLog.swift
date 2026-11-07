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

    /// Adds one event to a saved recording's `events.jsonl`, stamped with
    /// the time it happened, for work done after the recording.
    public static func append(_ event: String, _ fields: [String: Any] = [:], in folder: URL) {
        var entry = fields
        entry["event"] = event
        entry["at"] = ISO8601DateFormatter().string(from: Date())
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
            let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent("events.jsonl"))
        else { return }
        data.append(0x0A)
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
