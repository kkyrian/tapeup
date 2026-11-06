import SwiftUI
import TapeUpCore

/// The top of the panel: what TapeUp does, the two sources, and Record or Stop.
struct RecorderView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 0) {
                LaneView(
                    symbol: "speaker.wave.2.fill", title: "Mac audio", device: model.outputDevice,
                    levels: model.computerLevels, live: model.isRecording, access: model.computerAccess,
                    allow: { model.openPrivacySettings(for: "computer") })
                Divider().padding(.leading, 28).padding(.vertical, 10)
                LaneView(
                    symbol: "mic.fill", title: "Your mic", device: model.microphoneDevice,
                    levels: model.microphoneLevels, live: model.isRecording, access: model.microphoneAccess,
                    allow: { model.openPrivacySettings(for: "microphone") })
            }
            RecordButton(model: model)
        }
        .padding(14)
    }

    @ViewBuilder private var header: some View {
        switch model.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 2) {
                Text("Record your Mac and your mic").font(.system(size: 13, weight: .semibold))
                Text("One file, ready to hand to your agents").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .recording, .saving:
            HStack(alignment: .center, spacing: 8) {
                RecordingDot(saving: model.phase != .idle && !model.isRecording)
                Text(Format.duration(model.elapsed))
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.snappy(duration: 0.2), value: Int(model.elapsed))
                Spacer()
                Text(model.isRecording ? "Recording both" : "Saving…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct RecordingDot: View {
    let saving: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(saving ? Color.secondary : Color.red)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

struct RecordButton: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button(action: model.toggle) {
            HStack(spacing: 8) {
                Image(systemName: model.isRecording ? "stop.fill" : "circle.fill")
                    .font(.system(size: model.isRecording ? 10 : 9, weight: .bold))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let shortcut = model.shortcutLabel {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .foregroundStyle(model.phase == .idle ? Color.white : Color.primary)
            .background(fill, in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .disabled(isSaving)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }

    private var isSaving: Bool {
        if case .saving = model.phase { return true }
        return false
    }

    private var title: String {
        switch model.phase {
        case .idle: "Record"
        case .recording: "Stop and save"
        case .saving: "Saving…"
        }
    }

    private var fill: AnyShapeStyle {
        switch model.phase {
        case .idle: AnyShapeStyle(Color(nsColor: .systemRed).mix(with: .black, by: hovering ? 0.08 : 0).gradient)
        default: AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.08))
        }
    }
}

/// Scales down slightly while pressed, so clicks feel physical.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
