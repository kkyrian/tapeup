import Foundation
import TapeUpCore

@MainActor
enum Trash {
    private static let fallback = FileManager.default.temporaryDirectory.appendingPathComponent(
        "TapeUp-fixture-trash-\(UUID())")

    static func move(_ file: URL) throws -> URL {
        let fixture =
            Settings.isStaged
            ? Settings.store.string(forKey: "fixtureTrash").map { URL(fileURLWithPath: $0) } ?? fallback : nil
        return try RecordingTrash.move(file, fixture: fixture)
    }
}
