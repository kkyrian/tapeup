import Foundation

/// Every change to a recording's `meta.json` goes through here: read, change
/// the fields you own, write. The recorder and the who-was-there card both
/// edit the same file, so neither may rebuild it from scratch, and one lock
/// keeps their read-modify-write cycles from interleaving.
public enum MetaFile {
    private static let lock = NSRecursiveLock()

    /// One stable inode serializes metadata read-modify-write across the app
    /// and CLI. Nested patches reuse the flock; lock files are never unlinked.
    static func withLock<T>(in folder: URL, _ operation: (URL) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        func currentFolder() throws -> URL {
            let stamp = RecordingLibrary.stamp(of: folder)
            if VoiceFiles.isRecordingStamp(stamp),
                folder.deletingLastPathComponent().lastPathComponent == String(stamp.prefix(4))
            {
                let root = folder.deletingLastPathComponent().deletingLastPathComponent()
                let matches = RecordingLibrary(root: root).folders(withStamp: stamp)
                if matches.count > 1 { throw VoiceLibrary.Failure.ambiguousRecording(stamp) }
                if let match = matches.first { return match }
                // The recorder writes its first meta.json after making the directory.
                if FileManager.default.fileExists(atPath: folder.path),
                    !FileManager.default.fileExists(atPath: url(in: folder).path)
                {
                    return folder
                }
                throw CocoaError(.fileNoSuchFile)
            }
            return folder
        }
        let current = try currentFolder()
        let stamp = RecordingLibrary.stamp(of: current)
        let key = "TapeUpMetaLock:" + current.deletingLastPathComponent().path + ":" + stamp
        if Thread.current.threadDictionary[key] != nil { return try operation(current) }
        let descriptor = open(current.appendingPathComponent(".meta.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
        Thread.current.threadDictionary[key] = true
        defer {
            Thread.current.threadDictionary.removeObject(forKey: key)
            flock(descriptor, LOCK_UN)
        }
        return try operation(currentFolder())
    }

    public static func url(in folder: URL) -> URL { folder.appendingPathComponent("meta.json") }

    public static func read(_ folder: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func update(_ folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        try withLock(in: folder) { current in
            var meta = read(current) ?? [:]
            change(&meta)
            let data = try JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url(in: current), options: .atomic)
        }
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
