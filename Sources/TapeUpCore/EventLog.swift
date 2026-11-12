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
    @discardableResult
    public static func append(_ event: String, _ fields: [String: Any] = [:], in folder: URL) -> Bool {
        append(event, fields, in: folder, capture: nil)
    }

    private static let appendLock = NSLock()

    /// The stable lock also protects undo's comparison against a concurrent
    /// post-recording append. The recorder itself holds FolderLock instead.
    private static func withAppendLock<T>(in folder: URL, _ operation: () throws -> T) throws -> T {
        appendLock.lock()
        defer { appendLock.unlock() }
        let descriptor = open(folder.appendingPathComponent(".events.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    static func append(
        _ event: String, _ fields: [String: Any], in folder: URL,
        capture: ((Data?, Data?) -> Void)?
    ) -> Bool {
        do {
            return try withAppendLock(in: folder) {
                var entry = fields
                entry["event"] = event
                entry["at"] = ISO8601DateFormatter().string(from: Date())
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(0x0A)
                let url = folder.appendingPathComponent("events.jsonl")
                let existed = FileManager.default.fileExists(atPath: url.path)
                let before = capture != nil && existed ? try Data(contentsOf: url) : nil
                let descriptor = open(url.path, O_CREAT | O_RDWR | O_APPEND, 0o644)
                guard descriptor >= 0 else { return false }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                do {
                    let size = try handle.seekToEnd()
                    if size > 0 {
                        try handle.seek(toOffset: size - 1)
                        if try handle.read(upToCount: 1)?.last != 0x0A { data.insert(0x0A, at: 0) }
                    }
                    try handle.write(contentsOf: data)
                    capture?(before, (before ?? Data()) + data)
                    return true
                } catch {
                    if let after = try? Data(contentsOf: url) { capture?(before, after) }
                    return false
                }
            }
        } catch { return false }
    }

    static func restore(_ original: Data?, ifCurrentIs expected: Data?, in folder: URL) throws -> Bool {
        try withAppendLock(in: folder) {
            let url = folder.appendingPathComponent("events.jsonl")
            let exists = FileManager.default.fileExists(atPath: url.path)
            let current: Data?
            do { current = exists ? try Data(contentsOf: url) : nil } catch { return false }
            guard current == expected else { return false }
            if let original {
                if !exists {
                    try original.write(to: url, options: .atomic)
                } else {
                    // Keep an existing event handle attached to the same inode.
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: original)
                }
            } else if exists {
                try FileManager.default.removeItem(at: url)
            }
            return true
        }
    }
}
