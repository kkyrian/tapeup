import SwiftUI
import TapeUpCore

/// One recording: saved, its paths one click away, and who was there.
struct CardView: View {
    @Bindable var model: AppModel
    let card: AppModel.Card
    /// "Saved" confirms a recording that just stopped, for two seconds.
    @State private var savedShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 8) {
                // Text only: three actions share the row, and icons appear
                // only where they say something (copied, working, failed).
                FlatButton(kind: .primary, action: { model.copy(card.entry) }) {
                    HStack(spacing: 5) {
                        if model.copiedFlash { Image(systemName: "checkmark") }
                        Text(model.copiedFlash ? "Copied" : "Copy path")
                    }
                }
                .hoverHelp(card.entry.clipboardText)
                TranscriptButton(model: model, entry: card.entry)
                SquareButton(symbol: "folder", help: "Show in Finder") { model.reveal(card.entry) }
            }
            .disabled(card.finishing)
            Divider().padding(.vertical, 2)
            WhoWasThereView(model: model, people: card.entry.people)
            // Without its audio, a recording keeps the speakers it already has.
            if card.entry.transcript == .done, !card.finishing,
                card.entry.hasAudio || model.speakers.started(card.entry)
            {
                SpeakersView(model: model, entry: card.entry)
            }
        }
        .padding(Style.inset)
        .onAppear { if card.justRecorded, !card.finishing { flashSaved() } }
        .onChange(of: card.finishing) { was, now in if was, !now { flashSaved() } }
    }

    private func flashSaved() {
        savedShown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.3)) { savedShown = false }
        }
    }

    private var removedHere: Bool {
        model.removedAudio?.stamp == RecordingLibrary.stamp(of: card.entry.folder)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            IconButton(
                symbol: card.justRecorded ? "xmark" : "chevron.left", help: card.justRecorded ? "Close" : "Back",
                action: model.closeCard
            )
            .clickTarget(card.justRecorded ? "Close" : "Back")
            // The chevron sits in the icon column and the title on the text
            // edge, as on every page.
            .padding(.leading, -6)
            .frame(width: Style.textEdge - Style.inset, alignment: .leading)
            TitleField(entry: card.entry, model: model) {
                HStack(spacing: 4) {
                    if card.finishing {
                        ProgressView().controlSize(.mini)
                        Text("Saving…")
                    } else if savedShown {
                        Group {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                            Text("Saved ·")
                        }
                        .transition(.opacity)
                    }
                    if removedHere {
                        Text("Audio removed, transcript kept ·")
                        // Laid out at the line's height, so the header never moves.
                        LinkButton("Undo", action: model.undoRemoveAudio)
                            .frame(height: 13)
                            .padding(.leading, -4)
                    } else {
                        Text(
                            "\(Format.when(card.entry.started)) · \(Format.length(card.entry.duration))"
                                + (card.entry.hasAudio || card.finishing ? "" : " · Transcript only")
                        )
                        .monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.leading, -6)
            if !card.finishing {
                if model.canRemoveAudio(card.entry) {
                    IconButton(symbol: "waveform.badge.minus", help: "Remove audio, keep the transcript") {
                        model.removeAudio(card.entry)
                    }
                    .clickTarget("Remove audio")
                    .padding(.leading, 4)
                }
                IconButton(symbol: "trash", help: "Move recording and transcript to Trash") {
                    model.trash(card.entry)
                }
                .padding(.leading, 4)
            }
        }
    }
}

/// The recording's name and when it was made. The whole block renames: click
/// anywhere on it, type, then Return or a click elsewhere keeps the name and
/// Escape puts the old one back. The time is never part of the name.
struct TitleField<Subtitle: View>: View {
    let entry: RecordingEntry
    let model: AppModel
    @ViewBuilder let subtitle: Subtitle

    @State private var editing = false
    @State private var text = ""
    @State private var hovering = false
    @State private var frame = CGRect.zero
    @State private var clickMonitor: Any?
    @FocusState private var focused: Bool

    var body: some View {
        // One container, so its modifiers see a single view whether or not
        // the name is being edited.
        ZStack {
            if editing {
                block
            } else {
                // A button, not a tap gesture: it takes the first click even
                // while the panel is not focused.
                Button(action: begin) { block }
                    .buttonStyle(.plain)
                    .hoverHelp("Rename")
                    .accessibilityLabel(entry.title.map { "\($0), rename" } ?? "Add a title")
            }
        }
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: {
            frame = $0
        }
        .onDisappear(perform: commit)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if editing {
                    TextField("Title", text: $text)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onExitCommand(perform: cancel)
                        .onChange(of: focused) { _, now in if !now { commit() } }
                } else {
                    HStack(spacing: 5) {
                        Text(entry.title ?? "Add a title")
                            .foregroundStyle(entry.title == nil ? .tertiary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(height: 18)
            subtitle
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            editing ? Style.fill : hovering ? Style.fillHover : .clear,
            in: .rect(cornerRadius: Style.corner - 2, style: .continuous)
        )
        .contentShape(.rect)
    }

    private func begin() {
        text = entry.title ?? ""
        editing = true
        model.renaming = true
        model.focusPanel()
        DispatchQueue.main.async { focused = true }
        // The panel never loses focus to a click inside it, so a click outside
        // the field ends the rename here.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                if let height = event.window?.contentView?.bounds.height {
                    let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
                    if !frame.contains(point) { commit() }
                }
            }
            return event
        }
    }

    private func commit() {
        guard editing else { return }
        finish()
        if text.trimmingCharacters(in: .whitespacesAndNewlines) != (entry.title ?? "") { model.setTitle(text) }
    }

    private func cancel() {
        guard editing else { return }
        finish()
    }

    private func finish() {
        editing = false
        model.renaming = false
        stopWatchingClicks()
    }

    private func stopWatchingClicks() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}

/// Copy transcript, in the state the transcript is in: spinning while it is
/// made, Try again when it failed, Transcribe when there is none.
struct TranscriptButton: View {
    @Bindable var model: AppModel
    let entry: RecordingEntry

    var body: some View {
        let working = model.transcription.isWorking(on: entry)
        FlatButton(kind: .plain, action: act) {
            HStack(spacing: 6) {
                if let progress = model.transcription.progress(of: entry) {
                    ProgressRing(fraction: progress.fraction, size: 12).frame(width: 14, height: 14)
                } else if working {
                    ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 14, height: 14)
                } else if let symbol {
                    Image(systemName: symbol)
                }
                Text(title).lineLimit(1)
            }
        }
        .allowsHitTesting(!working)
        .hoverHelp(help(working: working))
        .accessibilityLabel(working ? "Transcribing" : title)
    }

    private func act() {
        switch entry.transcript {
        case .done: model.copyTranscript(entry)
        case .none, .failed: model.makeTranscript(entry)
        case .pending: break
        }
    }

    private var title: String {
        if let progress = model.transcription.progress(of: entry) {
            return "Transcribing \(Int((progress.fraction * 100).rounded()))%"
        }
        if model.transcription.isWorking(on: entry) { return "Transcribing" }
        switch entry.transcript {
        case .done: return model.transcriptCopiedFlash ? "Copied" : "Copy transcript"
        case .failed: return "Try again"
        case .none, .pending: return "Transcribe"
        }
    }

    private var symbol: String? {
        switch entry.transcript {
        case .done: model.transcriptCopiedFlash ? "checkmark" : nil
        case .failed: "arrow.clockwise"
        case .none, .pending: nil
        }
    }

    private func help(working: Bool) -> String {
        if let left = model.transcription.progress(of: entry)?.remaining() {
            return "Transcribing on this Mac, " + Format.left(left)
        }
        if working {
            return model.transcription.download == .ready
                ? "Transcribing on this Mac" : "Waiting for \(model.transcription.model.name) to download"
        }
        switch entry.transcript {
        case .done: return "Copy the transcript's text"
        case .failed: return "The transcript could not be made. Try again"
        case .none, .pending: return "Make a transcript on this Mac"
        }
    }
}

/// Accepts a suggestion in one click.
struct UseButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Use")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(
                    Color.accentColor.opacity(hovering ? 0.22 : 0.12), in: .capsule
                )
                .contentShape(.capsule)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .hoverHelp(help)
        .accessibilityLabel(help)
    }
}

/// A square button the height of the flat buttons, for an action an icon names.
struct SquareButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .background(
                    hovering ? Style.fillHover : Style.fill, in: .rect(cornerRadius: Style.corner, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .hoverHelp(help)
        .accessibilityLabel(help)
    }
}
