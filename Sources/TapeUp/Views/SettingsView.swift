import SwiftUI
import TapeUpCore

/// Where recordings go, the user's AI, and how the app behaves. Every row
/// says how it stands in words; nothing is greyed out without a reason.
struct SettingsView: View {
    @Bindable var model: AppModel

    private var agents: Agents { model.agents }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PageHeader(title: "Settings", back: model.closeSettings)

            section("Recordings")
            SettingRow(
                symbol: "folder", title: "Folder", subtitle: (model.root.path as NSString).abbreviatingWithTildeInPath,
                action: canMoveFolder ? { FolderChooser.choose(model: model) } : nil
            ) {
                // The whole row changes it; the word only says so.
                Text("Change…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .opacity(canMoveFolder ? 1 : 0.4)
            }
            .hoverHelp(canMoveFolder ? "Choose another folder" : "Stop recording first")

            section("Your AI")
            Text(Agents.caption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 4)
            SettingRow(
                symbol: agents.chosen == nil ? "largecircle.fill.circle" : "circle",
                markColor: agents.chosen == nil ? .accentColor : .secondary, title: "Off",
                action: { agents.choose(nil) }
            ) { EmptyView() }
            ForEach(AgentKind.allCases, id: \.self) { kind in
                agentRow(kind)
            }

            section("App")
            SettingRow(
                symbol: "pip", title: "Floating controls",
                action: { model.showsFloatingControls.toggle() }
            ) { MiniSwitch(on: model.showsFloatingControls) }
            SettingRow(
                symbol: "power", title: "Open at login",
                action: { model.launchAtLogin.toggle() }
            ) { MiniSwitch(on: launchAtLogin) }
        }
        .padding(Style.inset)
        .task(id: agents.waiting) { await agents.followTerminal() }
    }

    private var canMoveFolder: Bool { model.phase == .idle && !model.movingRecordings }

    private var launchAtLogin: Bool {
        _ = model.launchAtLoginRevision
        return model.launchAtLogin
    }

    private func section(_ title: String) -> some View {
        SectionLabel(text: title).padding(.top, 12).padding(.bottom, 4)
    }

    /// One agent on one line: picked or not on the left, its state on the
    /// right as a mark or the one thing it needs. Only a signed-in agent
    /// can be picked.
    private func agentRow(_ kind: AgentKind) -> some View {
        let state = agents.state(of: kind)
        let picked = agents.chosen == kind
        let waiting = agents.waiting[kind] == state
        let status: String =
            switch state {
            case .checking: "Checking…"
            case .signedIn: "Signed in"
            case .signedOut: waiting ? "Finish signing in in Terminal" : "Signed out"
            case .notInstalled: waiting ? "Finish installing in Terminal" : "Not installed"
            }
        return SettingRow(
            symbol: picked ? "largecircle.fill.circle" : "circle", markColor: picked ? .accentColor : .secondary,
            title: kind.name, action: state == .signedIn && !picked ? { agents.choose(kind) } : nil
        ) {
            Group {
                if state == .checking || waiting {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                } else if state == .signedIn {
                    // Quiet beside the accent radio, which alone says which is on.
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 16, height: 16)
                } else if state == .signedOut {
                    LinkButton("Sign in") { agents.signIn(kind) }.padding(.trailing, -6)
                } else {
                    LinkButton("Install") { agents.install(kind) }.padding(.trailing, -6)
                }
            }
            .hoverHelp(status)
        }
        .accessibilityValue(picked ? "On, \(status)" : status)
    }
}

/// A settings row the height of the source rows: a mark, what it is over
/// how it stands, and its control. With an action, the whole row clicks.
struct SettingRow<Trailing: View>: View {
    let symbol: String?
    var markColor = Color.secondary
    let title: String
    /// How it stands, under the title; nil keeps the row to one line.
    var subtitle: String?
    var action: (() -> Void)?
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            // The column keeps its width with no mark, so titles line up.
            Image(systemName: symbol ?? "checkmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(markColor)
                .opacity(symbol == nil ? 0 : 1)
                .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.2), value: subtitle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(height: subtitle == nil ? 32 : 36)
        .padding(.horizontal, 6)
        .background(
            hovering && action != nil ? Style.fill : .clear,
            in: .rect(cornerRadius: Style.corner, style: .continuous)
        )
        .padding(.horizontal, -6)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { action?() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
    }
}
