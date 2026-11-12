import SwiftUI
import TapeUpCore

/// Everything inside the drop-down panel. One page at a time: the recorder
/// with Recent, a recording's card, People, Settings or All recordings. Pages swap without a
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
        } else if model.showingSettings {
            SettingsView(model: model)
        } else if let card = model.card {
            // Opened from All recordings, the card's back returns there.
            CardView(model: model, card: card)
        } else if model.showingFreeUpSpace {
            FreeUpSpaceView(model: model)
        } else if model.showingAllRecordings {
            AllRecordingsView(model: model)
        } else {
            VStack(spacing: 0) {
                RecorderView(model: model)
                if let problem = model.problem {
                    ProblemBanner(text: problem, dismiss: model.dismissProblem)
                        .padding(.horizontal, Style.inset)
                        .padding(.bottom, Style.inset)
                }
                // Information, so below a problem the user has to act on.
                if let version = model.updatedTo {
                    UpdatedBanner(version: version, dismiss: { model.updatedTo = nil })
                        .padding(.horizontal, Style.inset)
                        .padding(.bottom, Style.inset)
                }
                Divider().padding(.horizontal, Style.inset)
                RecentView(model: model)
            }
        }
    }
}

/// One line after an update: the version, its release notes, a dismiss.
struct UpdatedBanner: View {
    let version: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            Text("Updated to \(version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let page = Updates.releasePage(for: version) {
                // Read, the line has done its job.
                LinkButton("What's new") {
                    NSWorkspace.shared.open(page)
                    dismiss()
                }
                .fixedSize()
                .hoverHelp("Open the release notes")
            }
            IconButton(symbol: "xmark", help: "Dismiss", size: 18, action: dismiss)
        }
        // The problem line's height: the buttons' hover fills spill into the padding.
        .frame(height: 16)
    }
}

struct ProblemBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            IconButton(symbol: "xmark", help: "Dismiss", size: 18, action: dismiss)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
    }
}
