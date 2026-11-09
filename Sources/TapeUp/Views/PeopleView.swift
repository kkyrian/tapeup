import SwiftUI
import TapeUpCore

/// Who you record with: a list you add to, edit and prune by hand, which
/// your own AI assistant can also fill in.
struct PeopleView: View {
    @Bindable var model: AppModel
    @State private var filter = ""
    /// The copy-and-paste steps for filling the list from your AI.
    @State private var filling = false
    /// Decided when the page opens, so the rows never jump while typing.
    @State private var findShown = false
    @State private var findHovering = false
    @FocusState private var filterFocused: Bool

    private var list: PeopleList { model.peopleList }

    init(model: AppModel) {
        self.model = model
        _findShown = State(initialValue: model.peopleList.people.count > 8)
        _filling = State(initialValue: model.peopleOpensFilling)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "People", back: model.closePeople) {
                // Only notices here, short enough never to be cut.
                if let notice = shortNotice { notice }
            } trailing: {
                LinkButton(filling ? "Done" : "Fill from your AI") { filling.toggle() }
                    .padding(.trailing, -6)
                    .hoverHelp(filling ? "Hide the steps" : "Have your AI assistant write the list")
            }
            if filling {
                fillSteps
                Divider()
            }
            people
        }
        .padding(Style.inset)
        .onChange(of: model.peopleNotice) { _, notice in
            // The list arrived from the assistant: the steps are done.
            if case .added = notice { filling = false }
        }
    }

    // MARK: Filling from your AI

    private var copied: Bool { model.peopleNotice == .copied }

    private var fillSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if copied {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Claude Code or Codex saves it here directly. From a chat app, paste its answer.")
                    }
                } else if model.peopleNotice == .pasteFailed {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text("No list on the clipboard. Copy the assistant's whole answer, then paste again.")
                    }
                } else {
                    Text(
                        "Paste this request into your AI assistant, and it fills in the people you meet, so you don't type their names."
                    )
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            HStack(spacing: 6) {
                FlatButton(kind: .primary, action: model.copyAssistantPrompt) {
                    Label(copied ? "Copied" : "Copy request", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .clickTarget("Copy request")
                FlatButton(kind: .plain, action: model.pasteAssistantAnswer) {
                    Label("Paste answer", systemImage: "doc.on.clipboard")
                }
            }
        }
    }

    /// What just happened, in a few words beside the title.
    private var shortNotice: AnyView? {
        let text: String
        var failed = false
        switch model.peopleNotice {
        case .added(let count): text = count == 0 ? "Updated" : "\(count) added"
        case .pasteFailed where !filling:
            text = "Nothing to paste"
            failed = true
        case .taken:
            text = "Already listed"
            failed = true
        default: return nil
        }
        return AnyView(
            HStack(spacing: 4) {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : Color.green)
                Text(text).lineLimit(1).fixedSize()
            }
            .font(.system(size: 11))
            .task(id: model.peopleNotice) {
                try? await Task.sleep(for: .seconds(failed ? 4 : 3))
                if !Task.isCancelled { model.clearPeopleNotice() }
            })
    }

    // MARK: The list

    private var shown: [PeopleList.Person] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list.people }
        let ranked = model.suggestions(matching: query, excluding: [], limit: list.people.count)
        return ranked.compactMap { name in list.people.first { $0.name == name } }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 6) {
            if findShown {
                HStack(spacing: 0) {
                    RowMark(symbol: "magnifyingglass")
                    TextField("Find", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($filterFocused)
                }
                .rowChrome(editing: filterFocused, hovering: findHovering)
                .onHover { findHovering = $0 }
                .onTapGesture {
                    model.focusPanel()
                    filterFocused = true
                }
                .padding(.horizontal, -6)
            }
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if filter.isEmpty {
                            // Someone added lands at the end: bring them into view.
                            AddPersonRow(model: model) { name in
                                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(name, anchor: .bottom) }
                            }
                            YouRow(model: model, you: list.you)
                        }
                        ForEach(shown, id: \.name) { person in
                            PersonRow(model: model, person: person).id(person.name)
                        }
                    }
                }
            }
            // Eight and a half rows: the half row shows the list goes on.
            .frame(height: min(CGFloat(shown.count + (filter.isEmpty ? 2 : 0)) * 28, 238))
            .padding(.horizontal, -6)
        }
    }
}

/// Type a name, and a note if you like, then Return: the person is listed
/// and the field is ready for the next one.
private struct AddPersonRow: View {
    let model: AppModel
    let added: (String) -> Void
    @State private var name = ""
    @State private var note = ""
    @FocusState private var focus: Field?

    private enum Field { case name, note }

    var body: some View {
        HStack(spacing: 6) {
            RowMark(symbol: "plus", color: .accentColor)
                .padding(.trailing, -6)
            TextField("Add a person", text: $name)
                .focused($focus, equals: .name)
                .onSubmit(add)
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                TextField("Note", text: $note)
                    .focused($focus, equals: .note)
                    .onSubmit(add)
                    .frame(width: 104)
                    .transition(.opacity)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onExitCommand(perform: clear)
        .rowChrome(editing: focus != nil, hovering: false)
        .animation(.easeOut(duration: 0.15), value: name.isEmpty)
        // While something is typed, Escape clears it instead of closing the panel.
        .onChange(of: name.isEmpty) { _, empty in model.renaming = !empty }
        .onDisappear { if !name.isEmpty { model.renaming = false } }
        .contentShape(.rect)
        .onTapGesture {
            model.focusPanel()
            focus = .name
        }
    }

    private func add() {
        guard model.addPerson(name, note: note) else { return }
        let person = name.trimmingCharacters(in: .whitespacesAndNewlines)
        clear()
        DispatchQueue.main.async { added(person) }
        focus = .name
    }

    private func clear() {
        name = ""
        note = ""
    }
}

/// The user's own name, first on the list. Click to set or change it.
private struct YouRow: View {
    let model: AppModel
    let you: String?
    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            RowMark(symbol: "person.crop.circle").hoverHelp("You")
            if editing {
                TextField("Your name", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: finish)
            } else {
                Text(you ?? "Your name")
                    .foregroundStyle(you == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .font(.system(size: 13))
        .rowChrome(editing: editing, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { if !editing { begin() } }
        .endsOnClickOutside(editing, perform: commit)
        .onChange(of: model.panelVisible) { _, visible in if !visible { commit() } }
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(editing ? [] : .isButton)
        .accessibilityHint(editing ? "" : "Set your name")
    }

    private func begin() {
        text = you ?? ""
        editing = true
        model.renaming = true
        model.focusPanel()
        DispatchQueue.main.async { focused = true }
    }

    private func commit() {
        guard editing else { return }
        if text.trimmingCharacters(in: .whitespaces) == (you ?? "") || model.setYou(text) { finish() }
    }

    private func finish() {
        editing = false
        model.renaming = false
    }
}

/// A person on the list. Click to edit the name and note in place; Return or
/// a click elsewhere keeps the change, Escape puts it back. Remove on hover.
private struct PersonRow: View {
    let model: AppModel
    let person: PeopleList.Person
    @State private var editing = false
    @State private var name = ""
    @State private var note = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            RowMark(symbol: nil).padding(.trailing, -6)
            if editing {
                TextField("Name", text: $name)
                    .focused($focused)
                    .onSubmit(commit)
                TextField("Note", text: $note)
                    .onSubmit(commit)
                    .frame(width: 104)
            } else {
                Text(person.name).lineLimit(1)
                if let context = person.context {
                    Text(context).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering {
                    IconButton(symbol: "xmark", help: "Remove \(person.name)", size: 20) {
                        model.removePerson(person.name)
                    }
                }
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onExitCommand(perform: finish)
        .rowChrome(editing: editing, hovering: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { if !editing { begin() } }
        .endsOnClickOutside(editing, perform: commit)
        // Closing the panel keeps what was typed, like a click elsewhere.
        .onChange(of: model.panelVisible) { _, visible in if !visible { commit() } }
        .accessibilityElement(children: editing ? .contain : .combine)
        .accessibilityAddTraits(editing ? [] : .isButton)
        .accessibilityHint(editing ? "" : "Edit")
        .accessibilityAction(named: "Remove") { model.removePerson(person.name) }
    }

    private func begin() {
        name = person.name
        note = person.context ?? ""
        editing = true
        // Escape then cancels the edit instead of closing the panel.
        model.renaming = true
        model.focusPanel()
        DispatchQueue.main.async { focused = true }
    }

    private func finish() {
        editing = false
        model.renaming = false
    }

    /// An emptied name keeps the old one; a name someone else has stays in
    /// the field, with a notice, until it is changed or Escape is pressed.
    private func commit() {
        guard editing else { return }
        let newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if (newName.isEmpty || newName == person.name) && newNote == (person.context ?? "") {
            finish()
        } else if model.updatePerson(person.name, to: newName, note: newNote) {
            finish()
        }
    }
}

/// The icon column every page shares, so names start on the text edge.
private struct RowMark: View {
    let symbol: String?
    var color = Color.secondary

    var body: some View {
        Image(systemName: symbol ?? "plus")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .opacity(symbol == nil ? 0 : 1)
            .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The list rows' padding, height and fill: a field's fill while
    /// editing, the hover fill otherwise.
    fileprivate func rowChrome(editing: Bool, hovering: Bool) -> some View {
        padding(.horizontal, 6)
            .frame(height: 28)
            .background(
                editing || hovering ? Style.fill : .clear,
                in: .rect(cornerRadius: 6, style: .continuous)
            )
            .contentShape(.rect)
    }

    /// Runs `perform` on a click outside this view while `active`. The panel
    /// never loses focus to a click inside it, so a field cannot tell.
    func endsOnClickOutside(_ active: Bool, perform: @escaping () -> Void) -> some View {
        modifier(ClickOutside(active: active, perform: perform))
    }
}

private struct ClickOutside: ViewModifier {
    let active: Bool
    let perform: () -> Void
    @State private var frame = CGRect.zero
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                frame = $0
            }
            .onChange(of: active, initial: true) { _, now in now ? start() : stop() }
            .onAppear { if active { start() } }
            .onDisappear(perform: stop)
    }

    private func start() {
        stop()
        // Clicks in other windows (the floating controls, a dialog) are not
        // clicks elsewhere in this one.
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if event.window === window, let height = event.window?.contentView?.bounds.height {
                    let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                    if !frame.contains(point) { perform() }
                }
            }
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
