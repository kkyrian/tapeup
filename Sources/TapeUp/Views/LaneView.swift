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

    @State private var refused = 0
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: on ? symbol : (symbol.hasPrefix("mic") ? "mic.slash" : "speaker.slash"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.secondary : Color.secondary.opacity(0.6))
                .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            if !on {
                Text("\(label) off").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if access == .denied {
                LinkButton("Allow access", action: allow).padding(.leading, -6)
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
            LevelBars(levels: Array(levels.suffix(13)), tint: recording ? Style.red : .accentColor)
                .frame(width: 48, height: 16)
                .opacity(live && on ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: live && on)
                .padding(.trailing, 8)
            MiniSwitch(on: on, refused: refused)
                .opacity(recording ? 0.35 : 1)
        }
        .frame(height: 26)
        .padding(.horizontal, 6)
        .background(hovering && !recording ? Style.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, -6)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: tap)
        .help(help)
        .animation(.snappy(duration: 0.3), value: device)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(on ? (access == .denied ? "On, no access" : "On, \(device)") : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction(.default, tap)
    }

    private var help: String {
        if recording { return label }
        if on && !canTurnOff { return "One source must stay on" }
        return on ? "Don't record \(label.lowercased())" : "Record \(label.lowercased())"
    }

    /// The whole row is the switch. The last source on refuses with a shake.
    private func tap() {
        guard !recording else { return }
        if on && !canTurnOff {
            withAnimation(.linear(duration: 0.3)) { refused += 1 }
        } else {
            toggle()
        }
    }
}

/// A small flat on/off switch: the familiar shape that says "this turns off".
struct MiniSwitch: View {
    let on: Bool
    /// Bumped when a change is refused; the switch shakes.
    var refused = 0

    var body: some View {
        Capsule()
            .fill(on ? Color.accentColor : Color.primary.opacity(0.18))
            .frame(width: 26, height: 15)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 11, height: 11).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .animation(.snappy(duration: 0.2), value: on)
            .modifier(Shake(amount: refused))
            .accessibilityHidden(true)
    }
}

struct Shake: GeometryEffect {
    var amount: Int
    var animatableData: CGFloat

    init(amount: Int) {
        self.amount = amount
        animatableData = CGFloat(amount)
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 3 * sin(animatableData * .pi * 4), y: 0))
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
