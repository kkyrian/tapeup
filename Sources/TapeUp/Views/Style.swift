import AppKit
import SwiftUI

/// Shared measures and the flat controls every view uses: solid fills, no
/// gradients, no shadows, hover by a slightly stronger fill.
enum Style {
    static let width: CGFloat = 312
    /// The content edge; icons sit in a column from here to `textEdge`.
    static let inset: CGFloat = 12
    /// Where text starts beside an icon column.
    static let textEdge: CGFloat = 40
    static let corner: CGFloat = 8
    static let red = Color(nsColor: .systemRed)
    static let fill = Color.primary.opacity(0.07)
    static let fillHover = Color.primary.opacity(0.11)
}

/// A full-width flat button.
struct FlatButton<Label: View>: View {
    enum Kind { case primary, destructive, plain }

    let kind: Kind
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .foregroundStyle(kind == .plain ? Color.primary : Color.white)
                .background(fill, in: .rect(cornerRadius: Style.corner, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch kind {
        case .primary: Color.accentColor.opacity(hovering ? 0.88 : 1)
        case .destructive: Style.red.opacity(hovering ? 0.88 : 1)
        case .plain: hovering ? Style.fillHover : Style.fill
        }
    }
}

/// A small square icon button.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 24
    var active = false
    /// On, shown by an accent glyph on a fill rather than a solid block.
    var tinted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(active ? Color.white : tinted ? Color.accentColor : Color.secondary)
                .background(
                    active
                        ? Color.accentColor : tinted || hovering ? (hovering ? Style.fillHover : Style.fill) : .clear,
                    in: .rect(cornerRadius: size * 0.28, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .hoverHelp(help)
        .accessibilityLabel(help)
    }
}

/// A text-only action, such as Undo or Paste answer: accent text that
/// gains a fill on hover, like every other clickable thing.
struct LinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
    }
}

/// The ··· menu button, with the same hover fill as the icon buttons.
struct MoreButton<Items: View>: View {
    let help: String
    @ViewBuilder let items: Items
    @State private var hovering = false

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(hovering ? Style.fillHover : .clear, in: .rect(cornerRadius: 24 * 0.28, style: .continuous))
        .onHover { hovering = $0 }
        .hoverHelp(help)
        .accessibilityLabel(help)
    }
}

/// Dims slightly while pressed.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A rounded chip: counts, suggestions and names.
struct Chip: View {
    enum Look { case normal, selected, token, suggested }

    let text: String
    var symbol: String?
    var look: Look = .normal
    var trailingSymbol = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol, !trailingSymbol { icon(symbol) }
                Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
                if let symbol, trailingSymbol { icon(symbol).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 28, minHeight: 24)
            .foregroundStyle(foreground)
            .background(background, in: .capsule)
            .overlay(
                Capsule().strokeBorder(Color.accentColor, lineWidth: look == .suggested || look == .token ? 1 : 0)
            )
            .contentShape(.capsule)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(look == .selected ? .isSelected : [])
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 8, weight: .bold)).opacity(0.7)
    }

    private var foreground: Color {
        switch look {
        case .selected: .white
        default: .primary
        }
    }

    private var background: Color {
        switch look {
        case .selected: .accentColor
        default: hovering ? Style.fillHover : Style.fill
        }
    }
}

/// A left-aligned section label.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row())
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Lays children out left to right on one line of fixed height; whatever
/// does not fit is left out rather than wrapped.
struct OneRowLayout: Layout {
    var spacing: CGFloat = 6
    var height: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                // Out of sight and out of reach.
                subview.place(at: CGPoint(x: bounds.minX - 10_000, y: bounds.minY), proposal: .zero)
                x = bounds.maxX + 1
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}
