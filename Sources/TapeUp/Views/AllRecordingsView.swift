import SwiftUI
import TapeUpCore

/// Every recording, to browse and then search: chips for the people met
/// most and for what is missing, a search over titles, names and
/// transcripts, and the list by month, one line a recording.
struct AllRecordingsView: View {
    @Bindable var model: AppModel

    /// The list's height whatever it holds, so filtering never moves the
    /// page's edges.
    static let listHeight: CGFloat = 372

    private var filter: RecordingFilter { model.recordingsFilter }

    var body: some View {
        let all = model.allEntries
        let frequent = RecordingSearch.frequentPeople(in: all)
        let shown = all.filter { filter.matches($0, transcript: model.transcriptIndex.text(for: $0)) }
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "All recordings", back: model.closeAllRecordings) {
                if model.trashed != nil {
                    HStack(spacing: 2) {
                        Text("Moved to the Trash").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                        LinkButton("Undo", action: model.undoTrash)
                    }
                }
            } trailing: {
                EmptyView()
            }
            SearchField(model: model).padding(.top, 10)
            chips(all: all, frequent: frequent).padding(.top, 8)
            results(shown)
                .frame(height: Self.listHeight, alignment: .top)
                .padding(.top, 10)
        }
        .padding(Style.inset)
        .onChange(of: filter.query.isEmpty, initial: true) { _, empty in
            if !empty { model.transcriptIndex.load(model.allEntries) }
        }
        .onChange(of: model.allEntries) { _, entries in
            if !filter.query.isEmpty { model.transcriptIndex.load(entries) }
        }
    }

    // MARK: Search and chips

    /// Two rows at most: the backfill chips, always, then the people met
    /// most, as many whole chips as fit on one line.
    private func chips(all: [RecordingEntry], frequent: [(name: String, count: Int)]) -> some View {
        // Someone picked who has since dropped out of the most met keeps a
        // chip, first, so a filter that is on can always be seen and turned off.
        let keys = Set(frequent.map { RecordingSearch.fold($0.name) })
        let extra = filter.people.filter { !keys.contains(RecordingSearch.fold($0)) }.sorted().map { name in
            let key = RecordingSearch.fold(name)
            return (
                name: name, count: all.filter { $0.people.names.contains { RecordingSearch.fold($0) == key } }.count
            )
        }
        let people = extra + frequent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FilterChip(
                    title: "No transcript", count: all.filter(RecordingSearch.needsTranscript).count,
                    on: filter.noTranscript
                ) { model.recordingsFilter.noTranscript.toggle() }
                FilterChip(
                    title: "No names yet", count: all.filter(RecordingSearch.needsNames).count, on: filter.noNames
                ) { model.recordingsFilter.noNames.toggle() }
            }
            if !people.isEmpty {
                OneRowLayout(spacing: 6, height: 22) {
                    ForEach(people, id: \.name) { person in
                        // A chip is the person, however their name was last written.
                        let key = RecordingSearch.fold(person.name)
                        let picked = filter.people.filter { RecordingSearch.fold($0) == key }
                        FilterChip(title: person.name, count: person.count, on: !picked.isEmpty) {
                            if picked.isEmpty {
                                model.recordingsFilter.people.insert(person.name)
                            } else {
                                model.recordingsFilter.people.subtract(picked)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: The list

    @ViewBuilder
    private func results(_ shown: [RecordingEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if filter.noTranscript, !shown.isEmpty {
                transcribeAll(shown).padding(.bottom, 8)
            }
            if shown.isEmpty {
                empty
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            byMonth(shown)
                        }
                    }
                    .scrollIndicators(.automatic)
                    // The rows' hover fills reach past the text, as on Recent.
                    .padding(.horizontal, -6)
                    .onAppear {
                        // Back from a card opened here: that row in view again, once.
                        guard let anchor = model.recordingsAnchor else { return }
                        model.recordingsAnchor = nil
                        DispatchQueue.main.async { scroller.scrollTo(anchor, anchor: .center) }
                    }
                }
            }
        }
    }

    /// One click for every recording shown without a transcript; then how
    /// many are left, in the same place.
    @ViewBuilder
    private func transcribeAll(_ shown: [RecordingEntry]) -> some View {
        let waiting = shown.filter { !model.transcription.isWorking(on: $0) }
        if !waiting.isEmpty {
            FlatButton(kind: .primary, action: { model.makeTranscripts(waiting) }) {
                Text(waiting.count == 1 ? "Transcribe 1 recording" : "Transcribe \(waiting.count) recordings")
            }
            .hoverHelp("Make each transcript on this Mac, one after another")
            .clickTarget("Transcribe all")
        } else {
            // On the text edge the rows' times start from; each row shows its own state.
            Text("Transcribing, \(shown.count) left")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 32)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary)
            LinkButton(clearTitle) { model.recordingsFilter = RecordingFilter() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var clearTitle: String {
        let chips = !filter.people.isEmpty || filter.noTranscript || filter.noNames
        if filter.query.isEmpty { return "Clear filters" }
        return chips ? "Clear search and filters" : "Clear search"
    }

    private var emptyText: String {
        let alone = filter.query.isEmpty && filter.people.isEmpty
        if alone, filter.noTranscript, !filter.noNames { return "Every recording has a transcript" }
        if alone, filter.noNames, !filter.noTranscript { return "Every recording has its people named" }
        return "No recordings match"
    }

    /// A row, with a few words of its transcript when that is what the search found.
    private func row(_ entry: RecordingEntry, look: RecordingRow.Look) -> RecordingRow {
        var excerpt: RecordingSearch.Excerpt?
        if let word = filter.transcriptOnlyWord(entry, transcript: model.transcriptIndex.text(for: entry)),
            let spoken = model.transcriptIndex.spoken(for: entry)
        {
            excerpt = RecordingSearch.excerpt(of: word, in: spoken)
        }
        return RecordingRow(entry: entry, model: model, look: look, excerpt: excerpt)
    }

    /// Rows go by stamp, which naming a recording (and so its folder) keeps.
    private static func stamp(_ entry: RecordingEntry) -> String { RecordingLibrary.stamp(of: entry.folder) }

    /// One line a recording under each month, with the month's count.
    @ViewBuilder
    private func byMonth(_ shown: [RecordingEntry]) -> some View {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: shown) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.started)) ?? $0.started
        }
        .sorted { $0.key > $1.key }
        ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
            MonthHeading(text: Format.month(group.key), count: group.value.count)
                .padding(.top, index == 0 ? 2 : 14)
                .padding(.bottom, 2)
            ForEach(group.value.sorted { $0.started > $1.started }) { entry in
                // Two lines while searching, so what was said can show why.
                row(entry, look: filter.words.isEmpty ? .dense : .weekday).id(Self.stamp(entry))
            }
        }
    }
}

/// The search, always filled so it reads as a field: the glyph in the icon
/// column, the words on the text edge, Clear once something is typed. Its
/// own view, so hovering it never recomputes the list.
private struct SearchField: View {
    @Bindable var model: AppModel
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: Style.textEdge - Style.inset)
            TextField("Titles, names, transcripts", text: $model.recordingsFilter.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
            if !model.recordingsFilter.query.isEmpty {
                if model.transcriptIndex.loading {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 16, height: 16)
                        .hoverHelp("Reading transcripts")
                }
                IconButton(symbol: "xmark.circle.fill", help: "Clear", size: 20) {
                    model.recordingsFilter.query = ""
                }
            }
        }
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(focused || hovering ? Style.fillHover : Style.fill, in: .rect(cornerRadius: 6, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture {
            model.focusPanel()
            focused = true
        }
    }
}

/// A month's name over its recordings.
private struct MonthHeading: View {
    let text: String
    /// How many recordings it holds, ending where the lengths do.
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
    }
}

/// A chip that narrows the list: its name and how many recordings it holds.
/// On, it turns dark grey (light in dark mode), never the accent.
private struct FilterChip: View {
    let title: String
    let count: Int
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .opacity(on ? 0.75 : 1)
                    .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(fill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .clickTarget(title)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var fill: Color {
        on ? Color.primary.opacity(hovering ? 0.62 : 0.7) : hovering ? Style.fillHover : Style.fill
    }
}
