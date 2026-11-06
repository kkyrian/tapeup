import SwiftUI
import TapeUpCore

/// Who you record with, written by your own AI assistant: copy one request,
/// and either the assistant saves the list itself or you paste its answer.
struct PeopleView: View {
    @Bindable var model: AppModel
    @State private var filter = ""

    private var list: PeopleList { model.peopleList }
    private var hasList: Bool { !list.people.isEmpty || list.you != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back", action: model.closePeople)
                Text("People").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !list.people.isEmpty {
                    Text("\(list.people.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if !hasList {
                Text("Your AI assistant writes the list. TapeUp suggests names from it when you note who was there.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 6) {
                FlatButton(kind: .primary, action: model.copyAssistantPrompt) {
                    Label(copyTitle, systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                FlatButton(kind: .plain, action: model.pasteAssistantAnswer) {
                    Label("Paste answer", systemImage: "doc.on.clipboard")
                }
            }

            status

            if hasList {
                Divider()
                people
            }
        }
        .padding(Style.inset)
    }

    private var copied: Bool { model.peopleNotice == .copied }

    private var copyTitle: String {
        if copied { return "Copied" }
        return hasList ? "Copy update request" : "Copy request for your AI"
    }

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
                count == 0 ? "List updated" : count == 1 ? "Added 1 person" : "Added \(count) people", failed: false)
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
    }

    private var shown: [PeopleList.Person] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list.people }
        let ranked = model.suggestions(matching: query, excluding: [], limit: list.people.count)
        return ranked.compactMap { name in list.people.first { $0.name == name } }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let you = list.you {
                HStack(spacing: 6) {
                    Text("You").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(you).font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 6)
            }
            if list.people.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Find", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Style.fill, in: .rect(cornerRadius: 6, style: .continuous))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown, id: \.name) { person in
                        PersonRow(person: person) { model.removePerson(person.name) }
                    }
                }
            }
            .frame(height: min(CGFloat(max(shown.count, 1)) * 28, 224))
            .scrollIndicators(.automatic)
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
