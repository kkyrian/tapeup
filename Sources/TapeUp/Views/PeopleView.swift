import SwiftUI
import TapeUpCore

/// Who you record with, written by your own AI assistant: copy one request,
/// and either the assistant saves the list itself or you paste its answer.
struct PeopleView: View {
    @Bindable var model: AppModel
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    private var list: PeopleList { model.peopleList }
    private var hasList: Bool { !list.people.isEmpty || list.you != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                IconButton(symbol: "chevron.left", help: "Back", action: model.closePeople)
                    .frame(width: Style.textEdge - Style.inset, alignment: .leading)
                Text("People").font(.system(size: 13, weight: .semibold))
                if !list.people.isEmpty {
                    Text("  \(list.people.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if hasList {
                HStack(spacing: 10) {
                    // A notice takes the label's place, so nothing moves.
                    if model.peopleNotice == nil || copied {
                        Text(copied ? "Waiting for your AI…" : "Update from your AI")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        status.lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    textButton(copied ? "Copied" : "Copy request", action: model.copyAssistantPrompt)
                    textButton("Paste answer", action: model.pasteAssistantAnswer)
                }
            } else {
                // The explanation and any notice share one slot of fixed height.
                Group {
                    if model.peopleNotice == nil {
                        Text(
                            "Your AI assistant writes the list. TapeUp suggests names from it when you note who was there."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    } else {
                        status
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                VStack(spacing: 6) {
                    FlatButton(kind: .primary, action: model.copyAssistantPrompt) {
                        Label(
                            copied ? "Copied" : "Copy request for your AI",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .contentTransition(.symbolEffect(.replace))
                    }
                    FlatButton(kind: .plain, action: model.pasteAssistantAnswer) {
                        Label("Paste answer", systemImage: "doc.on.clipboard")
                    }
                }
            }

            if hasList {
                people
            }
        }
        .padding(Style.inset)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
    }

    private var copied: Bool { model.peopleNotice == .copied }

    @ViewBuilder private var status: some View {
        switch model.peopleNotice {
        case .copied:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Claude Code or Codex saves it here directly. From a chat app, paste its answer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .added(let count):
            noticeLine(
                count == 0 ? "Updated" : "\(count) added", failed: false)
        case .pasteFailed:
            noticeLine("No list on the clipboard. Copy the assistant's whole answer, then paste again.", failed: true)
        case nil:
            EmptyView()
        }
    }

    private func noticeLine(_ text: String, failed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Color.orange : Color.green)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: model.peopleNotice) {
            try? await Task.sleep(for: .seconds(failed ? 6 : 3))
            if !Task.isCancelled { model.clearPeopleNotice() }
        }
    }

    private var shown: [PeopleList.Person] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list.people }
        let ranked = model.suggestions(matching: query, excluding: [], limit: list.people.count)
        return ranked.compactMap { name in list.people.first { $0.name == name } }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            if list.people.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Find", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($filterFocused)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Style.fill, in: .rect(cornerRadius: 6, style: .continuous))
                .onAppear { if model.panelFocused { filterFocused = true } }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let you = list.you, filter.isEmpty {
                        HStack(spacing: 6) {
                            Text(you).font(.system(size: 13))
                            Text("you").font(.system(size: 12)).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                    }
                    ForEach(shown, id: \.name) { person in
                        PersonRow(person: person) { model.removePerson(person.name) }
                    }
                }
            }
            .frame(height: min(CGFloat(max(shown.count + (list.you == nil ? 0 : 1), 1)) * 28, 224))
            .padding(.horizontal, -6)
        }
    }
}

/// A person in the list; remove appears on hover.
private struct PersonRow: View {
    let person: PeopleList.Person
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(person.name).font(.system(size: 13)).lineLimit(1)
            if let context = person.context {
                Text(context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                IconButton(symbol: "xmark", help: "Remove \(person.name)", size: 20, action: remove)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(hovering ? Style.fill : .clear, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}
