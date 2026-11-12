import Foundation

/// Every change to a recording's `meta.json` goes through here: read, change
/// the fields you own, write. The recorder and the who-was-there card both
/// edit the same file, so neither may rebuild it from scratch, and one lock
/// keeps their read-modify-write cycles from interleaving.
public enum MetaFile {
    private static let lock = NSRecursiveLock()

    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }

    public static func read(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func update(_ folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var meta = read(folder) ?? [:]
        change(&meta)
        let data = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url(in: folder), options: .atomic)
    }
}

/// An exclusive lock on a recording folder, held for as long as a recorder
/// writes into it, so crash recovery in another process never touches a
/// recording that is still running.
public final class FolderLock: @unchecked Sendable {
    private var descriptor: Int32
    private let path: String

    /// Nil when another process holds the folder.
    public init?(folder: URL) {
        path = folder.appendingPathComponent(".lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    /// Releases the lock. Keep its inode stable so processes cannot lock two
    /// different files for the same recording.
    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
