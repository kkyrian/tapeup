import SwiftUI
import TapeUpCore

/// The two sources and the one button. Record and Stop are the same button in
/// the same place, so the pointer is already on Stop.
struct RecorderView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            lane(
                symbol: "speaker.wave.2.fill", label: "Computer audio", device: model.outputDevice,
                levels: model.computerLevels, access: model.computerAccess, on: model.computerOn,
                canTurnOff: model.microphoneOn, toggle: model.toggleComputer, pane: "computer")
            lane(
                symbol: "mic.fill", label: "Microphone", device: model.microphoneDevice,
                levels: model.microphoneLevels, access: model.microphoneAccess, on: model.microphoneOn,
                canTurnOff: model.computerOn, toggle: model.toggleMicrophone, pane: "microphone")
            HStack(spacing: 8) {
                RecordButton(model: model)
                if model.isRecording {
                    PauseButton(paused: model.paused, toggle: model.togglePause)
                } else {
                    LevelCheckButton(on: model.testing, toggle: model.toggleTesting)
                        .disabled(model.phase != .idle)
                }
            }
            .padding(.top, 8)
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
                    PausableTime(elapsed: model.elapsed, paused: model.paused)
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
        case .recording: "Stop"
        case .saving: "Saving…"
        }
    }
}

/// Sits under the meters it turns on. Resting the pointer on it for a second
/// starts the check, the button filling as the second passes; a click
/// toggles at once. Passing over it does nothing, so the mic is never opened
/// by accident.
struct LevelCheckButton: View {
    static let width: CGFloat = 82
    static let hold: Double = 1.0

    let on: Bool
    let toggle: () -> Void
    @State private var hovering = false
    @State private var progress: CGFloat = 0
    @State private var pending: Task<Void, Never>?

    var body: some View {
        Button(action: toggle) {
            ZStack {
                // On the pointer, the button says what it does; at rest it is an icon.
                if hovering {
                    Text(on ? "Checking" : "Check levels").font(.system(size: 11, weight: .medium)).lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                } else {
                    Image(systemName: "waveform").font(.system(size: 14, weight: .semibold)).transition(.opacity)
                }
            }
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .frame(width: Self.width, height: 32)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: Self.width * (on ? 0 : progress))
            }
            .background(
                on ? Color.accentColor.opacity(hovering ? 0.26 : 0.18) : hovering ? Style.fillHover : Style.fill
            )
            .clipShape(.rect(cornerRadius: Style.corner, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover(perform: hover)
        .onChange(of: on) { _, _ in cancelHold() }
        .accessibilityLabel(on ? "Stop checking levels" : "Check levels")
    }

    /// Resting on the button starts the check after a moment, so passing over
    /// never opens the microphone; leaving it stops the check.
    private func hover(_ inside: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        guard inside else {
            cancelHold()
            if on { toggle() }
            return
        }
        guard !on else { return }
        withAnimation(.linear(duration: Self.hold)) { progress = 1 }
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.hold))
            guard !Task.isCancelled, hovering, !on else { return }
            toggle()
        }
    }

    private func cancelHold() {
        pending?.cancel()
        pending = nil
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}

/// Takes the level check's place while recording, at the same size.
struct PauseButton: View {
    let paused: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: LevelCheckButton.width, height: 32)
                .background(
                    hovering ? Style.fillHover : Style.fill, in: .rect(cornerRadius: Style.corner, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .help(paused ? "Resume" : "Pause")
        .accessibilityLabel(paused ? "Resume" : "Pause")
    }
}

/// The running time inside Stop; it blinks while paused.
struct PausableTime: View {
    let elapsed: TimeInterval
    let paused: Bool
    @State private var dim = false

    var body: some View {
        Text(Format.duration(elapsed))
            .monospacedDigit()
            .opacity(paused ? (dim ? 0.35 : 0.85) : 0.85)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: Int(elapsed))
            .onChange(of: paused, initial: true) { _, now in
                if now {
                    withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
                } else {
                    withAnimation(.default) { dim = false }
                }
            }
    }
}
