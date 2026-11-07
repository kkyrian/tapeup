import Foundation
import NaturalLanguage
import Observation
import TapeUpCore

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Suggested titles from Apple's on-device model, where Apple Intelligence
/// runs (macOS 26 and later). One recording at a time, once per recording;
/// the suggestion waits in `meta.json` until the user accepts or replaces it.
@MainActor @Observable
final class Titles {
    var library: RecordingLibrary
    /// A suggestion was saved for this stamp.
    var suggested: (String) -> Void = { _ in }

    private var queue: [String] = []
    private var running = false
    private var tried: Set<String> = []

    init(library: RecordingLibrary) { self.library = library }

    static var available: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Suggests a title for a transcribed recording the user has not named.
    func suggest(for entry: RecordingEntry) {
        let stamp = RecordingLibrary.stamp(of: entry.folder)
        guard Self.available, entry.transcript == .done, entry.title == nil, entry.titleSuggestion == nil,
            tried.insert(stamp).inserted
        else { return }
        queue.append(stamp)
        next()
    }

    private func next() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let stamp = queue.removeFirst()
        Task { [weak self] in
            defer {
                self?.running = false
                self?.next()
            }
            guard let self, let folder = library.folder(withStamp: stamp),
                let entry = RecordingLibrary.entry(at: folder), entry.title == nil,
                let lines = TranscriptDocument.lines(in: folder), !lines.isEmpty
            else { return }
            guard let title = await Self.make(excerpt: TitleExcerpt.make(lines: lines), people: entry.people.names),
                let folder = library.folder(withStamp: stamp), RecordingLibrary.entry(at: folder)?.title == nil
            else { return }
            try? RecordingLibrary.save(titleSuggestion: title, in: folder)
            suggested(stamp)
        }
    }

    /// The model's title, in the Mac's language; nil when it cannot make one.
    nonisolated static func make(excerpt: String, people: [String]) async -> String? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) { return await Generator.title(excerpt: excerpt, people: people) }
        #endif
        return nil
    }

    /// Trims what a model may add around a title: quotes, a final period, a
    /// "Title:" label, more than one line.
    nonisolated static func tidy(_ raw: String) -> String? {
        var title = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let colon = title.range(of: "title:", options: [.caseInsensitive, .anchored]) {
            title.removeSubrange(colon)
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.。 ").union(.whitespaces))
        return title.isEmpty || title.count > 80 ? nil : title
    }
}

#if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable
    struct SuggestedTitle {
        @Guide(
            description:
                "A short title for this recording, 2 to 6 words, naming its topic the way a person would label a meeting in their notes. No dates, no quotes, no trailing period."
        )
        var title: String
    }

    @available(macOS 26, *)
    private enum Generator {
        /// Tested on real mixed-language meetings: naming the decision or
        /// plan, not the field, gave specific titles; examples of the user's
        /// own titles were copied word for word, so none are given.
        static func title(excerpt: String, people: [String]) async -> String? {
            let language = Locale.preferredLanguages.first.map { Locale(identifier: $0) } ?? Locale.current
            let name =
                Locale(identifier: "en").localizedString(
                    forLanguageCode: language.language.languageCode?.identifier ?? "en") ?? "English"
            var instructions = """
                You name recordings. You are given lines from a transcript of a meeting, lecture or call \
                recorded on a Mac, in order, with gaps. Name what it is about, specifically: the decision, \
                plan or question discussed, not just the field. Always in \(name). Reply with the title only.
                """
            if !people.isEmpty {
                instructions += "\nPeople in this recording besides the user: \(people.joined(separator: ", "))."
            }
            do {
                let session = LanguageModelSession(instructions: instructions)
                var title = try await session.respond(to: excerpt, generating: SuggestedTitle.self).content.title
                // A meeting held in another language can still come back in it.
                if let code = language.language.languageCode?.identifier, dominant(title) != code {
                    let translate = LanguageModelSession(
                        instructions:
                            "Translate recording titles into short natural \(name). Reply with the title only.")
                    title = try await translate.respond(to: title, generating: SuggestedTitle.self).content.title
                }
                return Titles.tidy(title)
            } catch {
                return nil
            }
        }

        private static func dominant(_ text: String) -> String? {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            return recognizer.dominantLanguage.map {
                Locale(identifier: $0.rawValue).language.languageCode?.identifier ?? $0.rawValue
            }
        }
    }
#endif
