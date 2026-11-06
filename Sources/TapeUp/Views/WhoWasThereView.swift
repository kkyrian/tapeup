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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Who was there").font(.system(size: 13, weight: .semibold))
                Text("optional").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
                if savedFlash {
                    Label("Saved", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            countChips
            namesField
            suggestionsView
            if !model.hasSuggestionSource {
                Button(action: model.openPeople) {
                    Label("Fill in names from your AI assistant", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .animation(.snappy(duration: 0.2), value: people)
        .animation(.easeOut(duration: 0.2), value: savedFlash)
    }

    // MARK: Suggestions

    private var suggestions: [String] { model.suggestions(matching: query, excluding: people.names) }

    /// A typed name that matches nobody exactly can still be added as typed.
    private var newName: String? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, model.knownSpelling(of: typed) == nil,
            !people.names.contains(where: { $0.lowercased() == typed.lowercased() })
        else { return nil }
        return typed
    }

    @ViewBuilder private var suggestionsView: some View {
        let matches = suggestions
        if !matches.isEmpty || newName != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(query.isEmpty ? "Suggested" : "Return adds the first")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, name in
                        Chip(
                            text: name, symbol: "plus", selected: false,
                            highlighted: !query.isEmpty && index == 0
                        ) { add(name) }
                    }
                    if let newName {
                        Chip(text: "Add \u{201C}\(newName)\u{201D}", symbol: "plus", selected: false) { add(newName) }
                    }
                }
            }
            .transition(.opacity)
        }
    }

    // MARK: Count

    private var countChips: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { number in
                Chip(text: "\(number)", selected: people.count == number) {
                    editingOther = false
                    setCount(people.count == number ? nil : number)
                }
                .accessibilityLabel(number == 1 ? "1 person" : "\(number) people")
            }
            if editingOther {
                TextField("6+", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .frame(width: 44, height: 26)
                    .background(Color.accentColor.opacity(0.14), in: .capsule)
                    .focused($otherFocused)
                    .onSubmit(commitOther)
                    .onChange(of: otherFocused) { _, focused in if !focused { commitOther() } }
                    .onAppear { otherFocused = true }
            } else {
                Chip(text: otherLabel, selected: (people.count ?? 0) > 5) {
                    otherText = (people.count ?? 0) > 5 ? "\(people.count!)" : ""
                    editingOther = true
                }
            }
        }
    }

    private var otherLabel: String {
        if let count = people.count, count > 5 { return "\(count)" }
        return "Other"
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
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(people.names, id: \.self) { name in
                Chip(text: name, symbol: "xmark", selected: false, trailingSymbol: true, token: true) { remove(name) }
                    .accessibilityLabel("Remove \(name)")
            }
            TextField(people.names.isEmpty ? "Add names" : "Add", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(minWidth: 80, minHeight: 24)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(namesFocused ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: 1)
        )
        .contentShape(.rect)
        .onTapGesture { namesFocused = true }
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

struct Chip: View {
    let text: String
    var symbol: String?
    let selected: Bool
    var trailingSymbol = false
    var highlighted = false
    /// A chosen name: tinted rather than filled, so it reads apart from the count.
    var token = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol, !trailingSymbol { icon(symbol) }
                Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit()
                if let symbol, trailingSymbol { icon(symbol) }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 30, minHeight: 26)
            .foregroundStyle(selected ? Color.white : token ? Color.accentColor : Color.primary)
            .background(background, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(highlighted ? 0.8 : 0), lineWidth: 1.5))
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 9, weight: .bold)).opacity(0.75)
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor.gradient) }
        if token { return AnyShapeStyle(Color.accentColor.opacity(hovering ? 0.24 : 0.16)) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.07))
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
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
            let needed =
                rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
