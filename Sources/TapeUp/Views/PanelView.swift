import SwiftUI
import TapeUpCore

/// Everything inside the drop-down panel. One page at a time: the recorder
/// with Recent, a recording's card, or People. Pages swap without a
/// cross-fade, so the window never sizes itself to two pages at once.
struct PanelView: View {
    static let width = Style.width

    @Bindable var model: AppModel
    let close: () -> Void
    /// Reports the content's own height, which the window then takes.
    let resized: (CGFloat) -> Void
    /// The height SwiftUI last laid the whole panel out at, for `TapeUp uitest`.
    @MainActor static var laidOutHeight: CGFloat = 0

    var body: some View {
        page
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                resized($0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                Self.laidOutHeight = $0
            }
            .focusEffectDisabled()
    }

    @ViewBuilder private var page: some View {
        if model.showingPeople {
            PeopleView(model: model)
        } else if let card = model.card {
            CardView(model: model, card: card)
        } else {
            VStack(spacing: 0) {
                RecorderView(model: model)
                if let problem = model.problem {
                    ProblemBanner(text: problem, dismiss: model.dismissProblem)
                        .padding([.horizontal, .bottom], Style.inset)
                }
                Divider()
                RecentView(model: model)
            }
        }
    }
}

struct ProblemBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark", help: "Dismiss", size: 18, action: dismiss)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: Style.corner, style: .continuous))
    }
}
