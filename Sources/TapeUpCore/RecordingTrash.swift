import Foundation

/// The real Trash in normal use, or an explicitly supplied fixture directory.
/// Always returns the exact destination so restoration is unambiguous.
public enum RecordingTrash {
    public static func move(_ file: URL, fixture: URL? = nil) throws -> URL {
        if let fixture {
            let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                .resolvingSymlinksInPath().path.lowercased()
            let requested = fixture.resolvingSymlinksInPath().path.lowercased()
            guard requested != real, !requested.hasPrefix(real + "/") else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            var destination = fixture.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = fixture.appendingPathComponent(UUID().uuidString + " " + file.lastPathComponent)
            }
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
        var destination: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &destination)
        guard let destination else { throw CocoaError(.fileWriteUnknown) }
        return destination as URL
    }
}
