import SwiftUI

/// One source: a round on/off switch, the device it comes from, and while
/// listening, its level over the last two seconds.
struct LaneView: View {
    let symbol: String
    let label: String
    let device: String
    let levels: [Float]
    /// Listening now: recording, or checking levels.
    let live: Bool
    let recording: Bool
    let access: AppModel.Access
    /// Whether the next recording takes this source.
    let on: Bool
    /// False when this is the only source left on.
    let canTurnOff: Bool
    let toggle: () -> Void
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            SourceSwitch(
                symbol: on ? symbol : (symbol.hasPrefix("mic") ? "mic.slash.fill" : "speaker.slash.fill"),
                on: on, enabled: !recording && (!on || canTurnOff), toggle: toggle,
                help: recording
                    ? label
                    : !on
                        ? "Record \(label.lowercased())"
                        : canTurnOff ? "Don't record \(label.lowercased())" : "One source must stay on"
            )
            .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            if !on {
                Text("\(label) off").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if access == .denied {
                Button("Allow access to \(label.lowercased())", action: allow)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            } else {
                Text(device)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .id(device)
                    .transition(.push(from: .bottom))
            }
            Spacer(minLength: 8)
            // The meter has a place of its own in the row, so nothing moves
            // when listening starts; it is empty until there is something to show.
            LevelBars(levels: Array(levels.suffix(18)), tint: recording ? Style.red : .accentColor)
                .frame(width: 72, height: 16)
                .opacity(live && on ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: live && on)
        }
        .frame(height: 24)
        .animation(.snappy(duration: 0.3), value: device)
        .accessibilityElement(children: .contain)
    }
}

/// A round switch in the Control Center idiom: filled when on.
struct SourceSwitch: View {
    let symbol: String
    let on: Bool
    let enabled: Bool
    let toggle: () -> Void
    let help: String
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    on
                        ? Color.accentColor.opacity(hovering && enabled ? 0.85 : 1)
                        : (hovering && enabled ? Style.fillHover : Style.fill),
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(Pressable())
        .allowsHitTesting(enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// A row of bars, newest on the right. Silence is a solid tinted line, so
/// "listening, quiet" never looks like "off".
struct LevelBars: View {
    let levels: [Float]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let baseline = CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)
            context.fill(Path(roundedRect: baseline, cornerRadius: 1), with: .color(tint.opacity(0.35)))
            for (index, level) in levels.enumerated() where level > 0.04 {
                let height = max(2, CGFloat(level) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: min(width, height) / 2), with: .color(tint))
            }
        }
        .accessibilityHidden(true)
    }
}
