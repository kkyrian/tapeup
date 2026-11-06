import CoreAudio
import Foundation
import os

/// Listens to the mic and the Mac's audio without recording, so the panel can
/// show both levels before Record is pressed. Follows default device changes.
public final class LevelMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tapeup.level-monitor")
    private var microphone: MicrophoneCapture?
    private var computer: SystemAudioCapture?
    private var observation: AudioDevices.Observation?
    private var pendingRestart: DispatchWorkItem?
    private var wanted: (microphone: Bool, computer: Bool) = (false, false)
    private let peaks = OSAllocatedUnfairLock(initialState: (microphone: Float(0), computer: Float(0)))

    public init() {}

    /// Starts listening to the sources TapeUp has permission for.
    public func start(microphone: Bool, computer: Bool) {
        queue.async { [self] in
            wanted = (microphone, computer)
            open()
            observation = AudioDevices.observeDefaults(queue: queue) { [weak self] in self?.scheduleRestart() }
        }
    }

    /// Stops listening; returns once both devices are released, so a
    /// recording can start on them straight after.
    public func stop() {
        queue.sync {
            observation?.cancel()
            observation = nil
            pendingRestart?.cancel()
            close()
        }
        peaks.withLock { $0 = (0, 0) }
    }

    /// Peaks (0...1) since the last call.
    public func take() -> (microphone: Float, computer: Float) {
        peaks.withLock { state in
            let current = state
            state = (0, 0)
            return current
        }
    }

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.close()
            self?.open()
        }
        pendingRestart = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func open() {
        let rate = 16_000.0
        let ignore: @Sendable (String) -> Void = { _ in }
        if wanted.microphone {
            let capture = MicrophoneCapture(
                device: CoreAudioSystem.defaultDevice(kAudioHardwarePropertyDefaultInputDevice))
            if (try? capture.start(sampleRate: rate, sink: sink(microphone: true), issue: ignore)) != nil {
                microphone = capture
            }
        }
        if wanted.computer {
            let capture = SystemAudioCapture()
            if (try? capture.start(sampleRate: rate, sink: sink(microphone: false), issue: ignore)) != nil {
                computer = capture
            }
        }
    }

    private func close() {
        microphone?.stop()
        computer?.stop()
        microphone = nil
        computer = nil
    }

    private func sink(microphone: Bool) -> DeviceInputReader.Sink {
        { [weak self] _, samples in
            guard let self, !samples.isEmpty else { return }
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            peaks.withLock {
                if microphone { $0.microphone = max($0.microphone, peak) } else { $0.computer = max($0.computer, peak) }
            }
        }
    }
}
