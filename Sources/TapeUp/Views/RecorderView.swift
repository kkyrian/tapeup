import SwiftUI
import TapeUpCore

/// The two sources and the one button. Record and Stop are the same button in
/// the same place, so the pointer is already on Stop.
struct RecorderView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            lane(
                symbol: "speaker.wave.2.fill", label: "Mac audio", device: model.outputDevice,
                levels: model.computerLevels, access: model.computerAccess, on: model.computerOn,
                canTurnOff: model.microphoneOn, toggle: model.toggleComputer, pane: "computer")
            lane(
                symbol: "mic.fill", label: "Mic", device: model.microphoneDevice,
                levels: model.microphoneLevels, access: model.microphoneAccess, on: model.microphoneOn,
                canTurnOff: model.computerOn, toggle: model.toggleMicrophone, pane: "microphone")
            HStack(spacing: 8) {
                RecordButton(model: model)
                if model.isRecording {
                    IconButton(
                        symbol: model.paused ? "play.fill" : "pause.fill", help: model.paused ? "Resume" : "Pause",
                        size: 32, action: model.togglePause)
                } else {
                    IconButton(
                        symbol: "waveform",
                        help: model.testing ? "Stop checking levels" : "Check levels (uses the mic)",
                        size: 32, tinted: model.testing, action: model.toggleTesting
                    )
                    .disabled(model.phase != .idle)
                }
            }
            .padding(.top, 4)
        }
        .padding(Style.inset)
    }

    private func lane(
        symbol: String, label: String, device: String, levels: [Float], access: AppModel.Access, on: Bool,
        canTurnOff: Bool, toggle: @escaping () -> Void, pane: String
    ) -> some View {
        LaneView(
            symbol: symbol, label: label, device: device, levels: levels,
            live: model.isRecording || model.testing, recording: model.isRecording, access: access, on: on,
            canTurnOff: canTurnOff, toggle: toggle, allow: { model.openPrivacySettings(for: pane) })
    }
}

struct RecordingDot: View {
    let active: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(active ? Style.red : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(dim && active ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct RecordButton: View {
    @Bindable var model: AppModel

    var body: some View {
        FlatButton(kind: .destructive, action: model.toggle) {
            HStack(spacing: 7) {
                Image(systemName: model.phase == .idle ? "circle.fill" : "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                if model.phase != .idle {
                    Text(Format.duration(model.elapsed))
                        .monospacedDigit()
                        .opacity(model.paused ? 0.6 : 0.85)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: Int(model.elapsed))
                }
                Spacer()
                if let shortcut = model.shortcutLabel {
                    Text(shortcut).font(.system(size: 11, weight: .medium)).opacity(0.65)
                }
            }
            .padding(.horizontal, 12)
        }
        .disabled(isSaving)
        .accessibilityLabel(model.phase == .idle ? title : "\(title), \(Format.spokenDuration(model.elapsed))")
    }

    private var isSaving: Bool {
        if case .saving = model.phase { return true }
        return false
    }

    private var title: String {
        switch model.phase {
        case .idle: "Record"
        case .recording: model.paused ? "Paused" : "Stop"
        case .saving: "Saving…"
        }
    }
}
