import SwiftUI
import TapeUpCore

/// The two sources and the one button. While recording, the timer sits on top.
struct RecorderView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.phase != .idle {
                HStack(spacing: 8) {
                    RecordingDot(active: model.isRecording && !model.paused)
                    Text(Format.duration(model.elapsed))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: Int(model.elapsed))
                        .foregroundStyle(model.paused ? .secondary : .primary)
                    if model.paused {
                        Text("Paused").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            LaneView(
                symbol: "speaker.wave.2.fill", label: "Mac audio", device: model.outputDevice,
                levels: model.computerLevels, live: model.isRecording || model.testing,
                access: model.computerAccess, on: model.computerOn,
                canToggle: model.phase == .idle && (model.microphoneOn || !model.computerOn),
                toggle: model.toggleComputer, allow: { model.openPrivacySettings(for: "computer") })
            LaneView(
                symbol: "mic.fill", label: "Your mic", device: model.microphoneDevice,
                levels: model.microphoneLevels, live: model.isRecording || model.testing,
                access: model.microphoneAccess, on: model.microphoneOn,
                canToggle: model.phase == .idle && (model.computerOn || !model.microphoneOn),
                toggle: model.toggleMicrophone, allow: { model.openPrivacySettings(for: "microphone") })
            HStack(spacing: 8) {
                RecordButton(model: model)
                if model.isRecording {
                    IconButton(
                        symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause",
                        size: 32, action: model.togglePause)
                }
                if model.phase == .idle {
                    IconButton(
                        symbol: "waveform", help: model.testing ? "Stop checking levels" : "Check levels",
                        size: 32, active: model.testing, action: model.toggleTesting)
                }
            }
            .padding(.top, 2)
        }
        .padding(Style.inset)
    }
}

struct RecordingDot: View {
    let active: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(active ? Style.red : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(dim && active ? 0.3 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct RecordButton: View {
    @Bindable var model: AppModel

    var body: some View {
        FlatButton(kind: model.phase == .idle ? .destructive : .plain, action: model.toggle) {
            HStack(spacing: 7) {
                Image(systemName: model.phase == .idle ? "circle.fill" : "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                Spacer()
                if let shortcut = model.shortcutLabel {
                    Text(shortcut).font(.system(size: 11, weight: .medium)).opacity(0.65)
                }
            }
            .padding(.horizontal, 12)
        }
        .disabled(isSaving)
        .accessibilityLabel(title)
    }

    private var isSaving: Bool {
        if case .saving = model.phase { return true }
        return false
    }

    private var title: String {
        switch model.phase {
        case .idle: "Record"
        case .recording: "Stop"
        case .saving: "Saving…"
        }
    }
}
