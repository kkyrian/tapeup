import Foundation

/// Where the app keeps its settings. Pictures, films and the UI test run
/// against a scratch domain, so they never change the installed app's;
/// the commands they start inherit it.
enum Settings {
    nonisolated(unsafe) static var store = UserDefaults.standard
    private static let variable = "TAPEUP_STAGED_SETTINGS"

    /// For a staged run: a scratch domain, emptied first.
    static func stage() {
        let name = (Bundle.main.bundleIdentifier ?? "io.github.kkyrian.TapeUp") + ".staging"
        UserDefaults.standard.removePersistentDomain(forName: name)
        setenv(variable, name, 1)
        join()
    }

    /// A command started by a staged run uses the same scratch domain.
    static func join() {
        guard let name = ProcessInfo.processInfo.environment[variable], let suite = UserDefaults(suiteName: name)
        else { return }
        store = suite
    }
}
