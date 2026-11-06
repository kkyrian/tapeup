import SwiftUI

/// One source: the device it comes from and its level over the last two seconds.
struct LaneView: View {
    let symbol: String
    let label: String
    let device: String
    let levels: [Float]
    let live: Bool
    let access: AppModel.Access
    /// Whether the next recording takes this source; tapping the icon flips it.
    let on: Bool
    /// False while recording, or when this is the only source left on.
    let canToggle: Bool
    let toggle: () -> Void
    let allow: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    Image(systemName: on ? symbol : offSymbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(on ? Color.secondary : Color.secondary.opacity(0.6))
                        .frame(width: 22, height: 20)
                        .background(
                            hovering && canToggle ? Style.fillHover : .clear, in: .rect(cornerRadius: 5)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canToggle)
                .onHover { hovering = $0 }
                .help(on ? "Don't record \(label.lowercased())" : "Record \(label.lowercased())")
                .accessibilityLabel(label)
                .accessibilityValue(on ? "On" : "Off")
                if !on {
                    Text("\(label) off")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
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
                Spacer(minLength: 0)
            }
            .animation(.snappy(duration: 0.3), value: device)
            LevelBars(levels: levels, live: live && on)
                .frame(height: 16)
                .opacity(on ? 1 : 0.4)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .contain)
    }

    private var offSymbol: String { symbol.hasPrefix("mic") ? "mic.slash" : "speaker.slash" }
}

/// A row of bars, newest on the right; a flat line when not listening.
struct LevelBars: View {
    let levels: [Float]
    let live: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for (index, level) in levels.enumerated() {
                let height = live ? max(2, CGFloat(level) * size.height) : 2
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                let opacity = live && level > 0.04 ? 0.7 : 0.18
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                    with: .color(.primary.opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}
