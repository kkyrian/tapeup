import SwiftUI
import TapeUpCore

/// Everything inside the drop-down panel: the recorder with its two lanes and
/// Recent, or the card for one recording in the same place.
struct PanelView: View {
    static let width: CGFloat = 320

    @Bindable var model: AppModel
    let close: () -> Void
    let resized: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.showingPeople {
                PeopleView(model: model)
                    .transition(.opacity)
            } else if let card = model.card {
                CardView(model: model, card: card)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)), removal: .opacity))
            } else {
                RecorderView(model: model)
                    .transition(.opacity)
                if let problem = model.problem {
                    ProblemBanner(text: problem, dismiss: model.dismissProblem)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
                Divider().padding(.horizontal, 14)
                RecentView(model: model)
            }
        }
        .frame(width: Self.width)
        .focusEffectDisabled()
        .animation(.snappy(duration: 0.28), value: model.card?.entry.folder)
        .animation(.snappy(duration: 0.28), value: model.phase)
        .animation(.snappy(duration: 0.28), value: model.showingPeople)
        .animation(.snappy(duration: 0.2), value: model.problem)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { _ in
            resized()
        }
    }
}

struct ProblemBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
