import Foundation

/// Ownership for persisted work markers. The folder lock protects audio;
/// the PID distinguishes a queued/live worker from an interrupted command.
public enum RecordingWork {
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func foreignOwner(in folder: URL) -> Int32? {
        let meta = MetaFile.read(folder) ?? [:]
        for key in ["transcript", "speaker_labels"] {
            guard let state = meta[key] as? [String: Any],
                ["waiting", "transcribing", "finding"].contains(state["status"] as? String ?? ""),
                let pid = state["pid"] as? Int32, pid != getpid(), isAlive(pid)
            else { continue }
            return pid
        }
        return nil
    }

    @discardableResult
    public static func recover(in folder: URL, appBusy: Bool = false, resumeTranscripts: Bool = false) throws -> Bool {
        let meta = MetaFile.read(folder) ?? [:]
        let keys = ["transcript", "speaker_labels"].filter { key in
            guard let state = meta[key] as? [String: Any],
                ["waiting", "transcribing", "finding"].contains(state["status"] as? String ?? "")
            else { return false }
            if let pid = state["pid"] as? Int32 { return !isAlive(pid) }
            return !appBusy  // older versions did not retain ownership
        }
        guard !keys.isEmpty, let held = FolderLock(folder: folder) else { return false }
        defer { held.release() }
        var changed = false
        try MetaFile.update(folder) { fresh in
            for key in keys {
                guard var state = fresh[key] as? [String: Any],
                    ["waiting", "transcribing", "finding"].contains(state["status"] as? String ?? "")
                else { continue }
                if let pid = state["pid"] as? Int32, isAlive(pid) { continue }
                let resume = resumeTranscripts && key == "transcript"
                state["status"] = resume ? "waiting" : "failed"
                state["error"] = resume ? nil : "The process stopped before finishing."
                state["pid"] = resume ? getpid() : nil
                fresh[key] = state
                changed = true
            }
        }
        return changed
    }
}
