import AppKit
import Sparkle

/// Updates through Sparkle: a quiet check once a day, a download in the
/// background, and the install when the app quits or sits idle, never while
/// recording. The feed, the key and the schedule are in the app's Info.plist
/// (scripts/bundle.sh writes them).
@MainActor
final class Updates: NSObject {
    /// True while a recording runs or is being saved: nothing installs then.
    private let recording: () -> Bool
    /// True while the user is in the app or it has work running: a quiet
    /// install waits for this to end too.
    private let busy: () -> Bool
    private var controller: SPUStandardUpdaterController!
    /// A downloaded update waiting for the app to sit idle.
    private var installQuietly: (() -> Void)?
    /// An update the user chose to install, waiting for the recording to end.
    private var relaunch: (() -> Void)?
    /// The quiet install just started, and when: a recording begun in the
    /// moment before Sparkle asks the app to quit sends it back to waiting.
    private var started: (install: () -> Void, at: Date)?
    private var timer: Timer?

    init(recording: @escaping () -> Bool, busy: @escaping () -> Bool) {
        self.recording = recording
        self.busy = busy
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        // A build without the release key (a fresh clone) cannot check:
        // Sparkle would say so in an alert at every launch.
        if Self.isSetUp { controller.startUpdater() }
    }

    static var isSetUp: Bool {
        !(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
    }

    /// Check for Updates…: Sparkle's own window, with what's new.
    func check() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Asked as the app is about to quit. True when a quiet install began
    /// moments ago and a recording has started since: the quit is cancelled
    /// and the install waits again (Sparkle allows its handler a second call).
    func holdsQuitForRecording() -> Bool {
        guard let started, Date.now.timeIntervalSince(started.at) < 30, recording() else { return false }
        self.started = nil
        installQuietly = started.install
        waitUntilFree()
        return true
    }

    /// Runs whatever waits for the app to be free, once it is.
    private func waitUntilFree() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfFree() }
        }
        runIfFree()
    }

    private func runIfFree() {
        if !recording(), let relaunch {
            self.relaunch = nil
            relaunch()
        }
        if !recording(), !busy(), let installQuietly {
            self.installQuietly = nil
            started = (installQuietly, .now)
            installQuietly()
        }
        if relaunch == nil, installQuietly == nil {
            timer?.invalidate()
            timer = nil
        }
    }
}

extension Updates: SPUUpdaterDelegate {
    /// A quiet download is ready: install it once the app sits idle, rather
    /// than only when the user quits a menu-bar app that rarely quits.
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installQuietly = immediateInstallHandler
        waitUntilFree()
        return true
    }

    /// The user chose Install and Relaunch: wait for a recording to end first.
    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard recording() else { return false }
        relaunch = installHandler
        waitUntilFree()
        return true
    }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    /// A menu-bar app has no Dock icon to bounce; Sparkle shows its window
    /// without one when it cannot install quietly.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
