import SwiftUI
import TapeUpCore

/// Every recording, to browse and then search: chips for the people met
/// most and for what is missing, a search over titles, names and
/// transcripts, and the list in one of three layouts on trial.
struct AllRecordingsView: View {
    @Bindable var model: AppModel

    /// The list's height whatever it holds, so filtering never moves the
    /// page's edges or the strip under it.
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
            results(shown, frequent: frequent.map(\.name))
                .frame(height: Self.listHeight, alignment: .top)
                .padding(.top, 10)
            Divider()
            designStrip.padding(.top, 8)
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

    private func chips(all: [RecordingEntry], frequent: [(name: String, count: Int)]) -> some View {
        // Someone picked who has since dropped out of the most met keeps a
        // chip, so a filter that is on can always be seen and turned off.
        let keys = Set(frequent.map { RecordingSearch.fold($0.name) })
        let extra = filter.people.filter { !keys.contains(RecordingSearch.fold($0)) }.sorted().map { name in
            let key = RecordingSearch.fold(name)
            return (
                name: name, count: all.filter { $0.people.names.contains { RecordingSearch.fold($0) == key } }.count
            )
        }
        return FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(frequent + extra, id: \.name) { person in
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
            FilterChip(
                title: "No transcript", count: all.filter(RecordingSearch.needsTranscript).count,
                on: filter.noTranscript
            ) { model.recordingsFilter.noTranscript.toggle() }
            FilterChip(
                title: "No names yet", count: all.filter(RecordingSearch.needsNames).count, on: filter.noNames
            ) { model.recordingsFilter.noNames.toggle() }
        }
    }

    // MARK: The list

    @ViewBuilder
    private func results(_ shown: [RecordingEntry], frequent: [String]) -> some View {
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
                            switch model.recordingsDesign {
                            case 2: byPerson(shown, frequent: frequent)
                            case 3: byMonth(shown)
                            default: byDay(shown)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    // The rows' hover fills reach past the text, as on Recent.
                    .padding(.horizontal, -6)
                    .onAppear {
                        // Back from a card opened here: that row in view again, once.
                        guard let anchor = model.recordingsAnchor else { return }
                        model.recordingsAnchor = nil
                        let id = model.recordingsDesign == 2 ? personRowID(anchor, shown, frequent: frequent) : anchor
                        if let id { DispatchQueue.main.async { scroller.scrollTo(id, anchor: .center) } }
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
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                Text("Transcribing, \(shown.count) left")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 32)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary)
            LinkButton("Clear search and filters") { model.recordingsFilter = RecordingFilter() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private var emptyText: String {
        let alone = filter.query.isEmpty && filter.people.isEmpty
        if alone, filter.noTranscript, !filter.noNames { return "Every recording has a transcript" }
        if alone, filter.noNames, !filter.noTranscript { return "Every recording has its people named" }
        return "No recordings match"
    }

    // MARK: Design 1, by day

    /// Days under day headings, as on Recent; past this month, each month
    /// gets a heading and its days are named within it.
    @ViewBuilder
    private func byDay(_ shown: [RecordingEntry]) -> some View {
        let calendar = Calendar.current
        let now = Date()
        let groups = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.started) }
            .sorted { $0.key > $1.key }
        ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
            let thisMonth = calendar.isDate(group.key, equalTo: now, toGranularity: .month)
            let newMonth =
                !thisMonth
                && (index == 0 || !calendar.isDate(groups[index - 1].key, equalTo: group.key, toGranularity: .month))
            if newMonth {
                MonthHeading(text: Format.month(group.key)).padding(.top, index == 0 ? 2 : 18)
            }
            SectionLabel(text: thisMonth ? Format.day(group.key) : Format.dayInMonth(group.key))
                .padding(.horizontal, 6)
                .padding(.top, index == 0 ? 2 : newMonth ? 6 : 10)
                .padding(.bottom, 2)
            ForEach(group.value.sorted { $0.started > $1.started }) { entry in
                RecordingRow(entry: entry, model: model).id(Self.stamp(entry))
            }
        }
    }

    // MARK: Design 2, by person

    private struct PersonSection {
        /// The person's name, or "" for everyone else.
        var key: String
        var entries: [RecordingEntry]
    }

    private func personSections(_ shown: [RecordingEntry], frequent: [String]) -> [PersonSection] {
        RecordingSearch.byPerson(shown, people: frequent).map {
            PersonSection(key: $0.person ?? "", entries: $0.entries)
        }
    }

    private static let collapsed = 3

    private func rowID(_ section: String, _ stamp: String) -> String { section + "\u{1F}" + stamp }

    /// Where a recording shows in By person: the first section that has it
    /// in view, not folded away.
    private func personRowID(_ stamp: String, _ shown: [RecordingEntry], frequent: [String]) -> String? {
        guard filter.people.isEmpty else { return rowID("", stamp) }
        for section in personSections(shown, frequent: frequent) {
            guard let index = section.entries.firstIndex(where: { Self.stamp($0) == stamp }) else { continue }
            if index < Self.collapsed || !filter.isEmpty || model.expandedPeople.contains(section.key) {
                return rowID(section.key, stamp)
            }
        }
        return nil
    }

    /// Rows go by stamp, which naming a recording (and so its folder) keeps.
    private static func stamp(_ entry: RecordingEntry) -> String { RecordingLibrary.stamp(of: entry.folder) }

    /// A section for each person met most, their newest few first, then
    /// everyone else. Narrowed by a chip or a search, every match shows.
    @ViewBuilder
    private func byPerson(_ shown: [RecordingEntry], frequent: [String]) -> some View {
        // With people picked, every recording shown has them all: one list, no headings.
        let sections =
            filter.people.isEmpty
            ? personSections(shown, frequent: frequent) : [PersonSection(key: "", entries: shown)]
        let only = sections.count == 1 && sections[0].key.isEmpty
        // From every recording, so narrowing never moves the titles.
        let width = Format.dateColumnWidth(for: model.allEntries.map(\.started))
        ForEach(Array(sections.enumerated()), id: \.element.key) { index, section in
            let open = !filter.isEmpty || model.expandedPeople.contains(section.key)
            let limit = Self.collapsed
            if !only {
                MonthHeading(text: section.key.isEmpty ? "Others" : section.key)
                    .lineLimit(1)
                    .padding(.top, index == 0 ? 2 : 16)
                    .padding(.bottom, 2)
            }
            ForEach(open ? section.entries : Array(section.entries.prefix(limit))) { entry in
                RecordingRow(entry: entry, model: model, look: .date(width: width))
                    .id(rowID(section.key, Self.stamp(entry)))
            }
            if filter.isEmpty, section.entries.count > limit {
                // Its words start where the dates do.
                LinkButton(open ? "Show fewer" : "Show \(section.entries.count - limit) more") {
                    if model.expandedPeople.remove(section.key) == nil { model.expandedPeople.insert(section.key) }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Design 3, by month, compact

    /// One line a recording under each month, with the month's count.
    @ViewBuilder
    private func byMonth(_ shown: [RecordingEntry]) -> some View {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: shown) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.started)) ?? $0.started
        }
        .sorted { $0.key > $1.key }
        ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
            HStack(alignment: .firstTextBaseline) {
                MonthHeading(text: Format.month(group.key))
                Spacer()
                Text("\(group.value.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 6)
            }
            .padding(.top, index == 0 ? 2 : 14)
            .padding(.bottom, 2)
            ForEach(group.value.sorted { $0.started > $1.started }) { entry in
                RecordingRow(entry: entry, model: model, look: .dense).id(Self.stamp(entry))
            }
        }
    }

    // MARK: The trial's switch

    /// Temporary: the three layouts side by side for the owner to pick from.
    private var designStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(["By day", "By person", "By month, compact"].enumerated()), id: \.offset) { index, name in
                DesignTab(title: "Design \(index + 1)", help: name, on: model.recordingsDesign == index + 1) {
                    model.recordingsDesign = index + 1
                }
            }
            Spacer()
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

/// A month's or a person's name over their recordings.
private struct MonthHeading: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 6)
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
            .frame(height: 24)
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

/// One of the trial's layouts: a small tab, filled when shown.
private struct DesignTab: View {
    let title: String
    let help: String
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    on ? Style.fillHover : hovering ? Style.fill : .clear,
                    in: .rect(cornerRadius: 5, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .hoverHelp(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
