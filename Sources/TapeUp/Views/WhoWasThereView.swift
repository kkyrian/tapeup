import SwiftUI
import TapeUpCore

/// Optional: how many people were there and who. Every tap saves.
struct WhoWasThereView: View {
    @Bindable var model: AppModel
    let people: RecordingEntry.People

    @State private var query = ""
    @State private var otherText = ""
    @State private var editingOther = false
    @State private var savedFlash = false
    @FocusState private var namesFocused: Bool
    @FocusState private var otherFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SectionLabel(text: "Who was there")
                Spacer()
                if savedFlash {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(height: 16)
            countChips
            namesField
            suggestionsView
            if !model.hasSuggestionSource {
                LinkButton("Get names from your AI assistant", action: model.openPeople).padding(.leading, -6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: savedFlash)
        .onAppear { if model.panelFocused { namesFocused = true } }
    }

    /// Typing goes straight to names, without a second click.
    private func focusNames() {
        model.focusPanel()
        namesFocused = true
    }

    // MARK: Suggestions

    /// Before typing, the most frequent few fit on one line; typing widens the search.
    private var suggestions: [String] {
        model.suggestions(matching: query, excluding: people.names, limit: 6)
    }

    /// A typed name that matches nobody exactly can still be added as typed.
    private var newName: String? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, model.knownSpelling(of: typed) == nil,
            !people.names.contains(where: { $0.lowercased() == typed.lowercased() })
        else { return nil }
        return typed
    }

    /// One row, always there, so the card keeps its shape while you type.
    @ViewBuilder private var suggestionsView: some View {
        let matches = suggestions
        if model.hasSuggestionSource || !query.isEmpty {
            OneRowLayout(spacing: 6) {
                ForEach(Array(matches.enumerated()), id: \.element) { index, name in
                    Chip(text: name, look: !query.isEmpty && index == 0 ? .suggested : .normal) {
                        add(name)
                    }
                }
                if let newName {
                    Chip(text: "Add \u{201C}\(newName)\u{201D}") { add(newName) }
                }
            }
        }
    }

    // MARK: Count

    private var countChips: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { number in
                Chip(text: "\(number)", look: people.count == number ? .selected : .normal) {
                    editingOther = false
                    setCount(people.count == number ? nil : number)
                    focusNames()
                }
                .accessibilityLabel(number == 1 ? "Just you" : "\(number) people")
                .help(number == 1 ? "Just you" : "\(number) people, including you")
            }
            if editingOther {
                TextField("6+", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 40, height: 24)
                    .background(Style.fill, in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
                    .focused($otherFocused)
                    .onSubmit(commitOther)
                    .onChange(of: otherFocused) { _, focused in if !focused { commitOther() } }
                    .onAppear { otherFocused = true }
            } else {
                let large = (people.count ?? 0) > 5
                Chip(text: large ? "\(people.count!)" : "6+", look: large ? .selected : .normal) {
                    otherText = large ? "\(people.count!)" : ""
                    editingOther = true
                }
                .accessibilityLabel(large ? "\(people.count!) people" : "6 or more")
            }
        }
    }

    private func commitOther() {
        guard editingOther else { return }
        editingOther = false
        if let number = Int(otherText.trimmingCharacters(in: .whitespaces)), number > 0 {
            setCount(number)
        }
    }

    private func setCount(_ count: Int?) {
        var updated = people
        updated.count = count
        save(updated)
    }

    // MARK: Names

    private var namesField: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            ForEach(people.names, id: \.self) { name in
                Chip(text: name, symbol: "xmark", look: .token, trailingSymbol: true) { remove(name) }
                    .accessibilityLabel("Remove \(name)")
            }
            TextField(people.names.isEmpty ? "Names" : "", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 24, minHeight: 24)
                .focused($namesFocused)
                .onSubmit { addTyped() }
                .onChange(of: query) { _, text in
                    if text.hasSuffix(",") {
                        query = String(text.dropLast())
                        addLiteral()
                    }
                }
                .onKeyPress(.delete) {
                    guard query.isEmpty, let last = people.names.last else { return .ignored }
                    remove(last)
                    return .handled
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(Style.fill, in: .rect(cornerRadius: Style.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Style.corner, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: namesFocused ? 1 : 0)
        )
        .contentShape(.rect)
        .onTapGesture(perform: focusNames)
    }

    /// Return takes the best match, so "ps" adds Priya Shah; a name nobody
    /// matches is added as typed.
    private func addTyped() {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        add(suggestions.first ?? typed)
    }

    /// A comma ends a name as typed, unless it is already known.
    private func addLiteral() {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        add(model.knownSpelling(of: typed) ?? typed)
    }

    private func add(_ name: String) {
        guard !people.names.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        var updated = people
        updated.names.append(name)
        // Names plus you: the count is never lower than the people named.
        if (updated.count ?? 0) < updated.names.count + 1 { updated.count = updated.names.count + 1 }
        query = ""
        save(updated)
    }

    private func remove(_ name: String) {
        var updated = people
        updated.names.removeAll { $0 == name }
        save(updated)
    }

    private func save(_ updated: RecordingEntry.People) {
        model.setPeople(updated)
        savedFlash = true
        let mark = updated
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if mark == model.card?.entry.people { savedFlash = false }
        }
    }
}
