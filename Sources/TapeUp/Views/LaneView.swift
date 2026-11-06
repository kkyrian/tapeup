import SwiftUI

/// One source: its name, the device it comes from, and its level over the last
/// couple of seconds.
struct LaneView: View {
    let symbol: String
    let title: String
    let device: String
    let levels: [Float]
    let live: Bool
    let access: AppModel.Access
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    if access == .denied {
                        Button("Allow access", action: allow)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text(device)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .id(device)
                            .transition(.push(from: .bottom))
                    }
                }
                .animation(.snappy(duration: 0.3), value: device)
                LevelBars(levels: levels, live: live)
                    .frame(height: 18)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(access == .denied ? "no access" : device)")
    }
}

/// A row of bars, newest on the right. Flat dashes while not recording.
struct LevelBars: View {
    let levels: [Float]
    let live: Bool

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let gap: CGFloat = 2
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            for (index, level) in levels.enumerated() {
                let height = live ? max(3, CGFloat(level) * size.height) : 2
                let rect = CGRect(
                    x: CGFloat(index) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                let opacity = live ? (level > 0.04 ? 0.72 : 0.25) : 0.2
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(width, height) / 2),
                    with: .color(.primary.opacity(opacity)))
            }
        }
        .accessibilityHidden(true)
    }
}
