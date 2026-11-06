import SwiftUI
import TapeUpCore

/// Who you record with, filled in by your own AI assistant: copy one prompt,
/// and either the assistant saves the list itself or you paste its answer.
struct PeopleView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: model.closePeople) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 1) {
                    Text("People").font(.system(size: 15, weight: .semibold))
                    Text("Names TapeUp suggests for who was there")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Step(number: 1, text: "Send this request to your AI assistant.") {
                    WideButton(
                        title: model.peopleNotice == .copied ? "Copied" : "Copy for your AI",
                        symbol: model.peopleNotice == .copied ? "checkmark" : "sparkles", prominent: true,
                        action: model.copyAssistantPrompt)
                }
                Step(number: 2, text: "In a chat app, copy its whole answer and paste it here.") {
                    WideButton(
                        title: "Paste answer", symbol: "doc.on.clipboard", prominent: false,
                        action: model.pasteAssistantAnswer)
                }
                HStack(spacing: 8) {
                    if model.peopleNotice == .copied { ProgressView().controlSize(.mini) }
                    Text("Claude Code or Codex on this Mac saves the list itself; it shows up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 28)
            }

            if let notice = model.peopleNotice, notice != .copied {
                NoticeLine(notice: notice)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !model.peopleList.people.isEmpty || model.peopleList.you != nil {
                Divider()
                list
            }
        }
        .padding(14)
        .animation(.snappy(duration: 0.25), value: model.peopleNotice)
        .animation(.snappy(duration: 0.25), value: model.peopleList)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(model.peopleList.people.count) people")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let you = model.peopleList.you {
                    Text("You: \(you)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ScrollView {
                FlowLayout(spacing: 6) {
                    ForEach(model.peopleList.people, id: \.name) { person in
                        PersonChip(person: person) { model.removePerson(person.name) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.07), in: .circle)
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                content
            }
        }
    }
}

struct WideButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: prominent ? .semibold : .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(background, in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
    }

    private var background: AnyShapeStyle {
        prominent
            ? AnyShapeStyle(Color.accentColor.opacity(hovering ? 1 : 0.92).gradient)
            : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.08))
    }
}

private struct NoticeLine: View {
    let notice: AppModel.PeopleNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(failed ? Color.orange : Color.green)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var failed: Bool { notice == .pasteFailed }

    private var text: String {
        switch notice {
        case .added(0): "List updated."
        case .added(1): "Added 1 person."
        case .added(let count): "Added \(count) people."
        case .pasteFailed:
            "The clipboard has no list from TapeUp's request. Copy the assistant's whole answer, then paste again."
        case .copied: ""
        }
    }
}

/// A person in the list; the remove button appears on hover.
private struct PersonChip: View {
    let person: PeopleList.Person
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(person.name).font(.system(size: 12, weight: .medium))
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove \(person.name)")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Color.primary.opacity(hovering ? 0.11 : 0.07), in: .capsule)
        .onHover { hovering = $0 }
        .help(person.context ?? person.name)
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}
