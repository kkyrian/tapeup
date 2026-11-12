import Foundation
import Testing

@testable import TapeUpCore

struct VoiceMatchingTests {
    private func store() throws -> VoiceStore {
        var store = VoiceStore()
        try store.addExample(voiceExample("a"), for: "Mei")
        try store.addExample(voiceExample("b", print: voicePrint(0, 1)), for: "Ana")
        return store
    }

    @Test func clearMatchFillsAndShortOrUnknownVoicesStayEmpty() throws {
        let store = try store()
        let fills = VoiceMatching.match(
            prints: [1: voicePrint(), 2: voicePrint(0, 1), 3: voicePrint(-1)], seconds: [1: 60, 2: 59, 3: 100],
            store: store)
        #expect(fills.map(\.person) == ["Mei"])
        #expect(VoiceMatching.match(prints: [:], seconds: [:], store: store).isEmpty)
        #expect(VoiceMatching.match(prints: [1: [1]], seconds: [1: 100], store: store).isEmpty)
    }

    @Test func twoVoicesCompeteForOnePersonByBestGlobalAssignment() throws {
        let fills = VoiceMatching.match(
            prints: [1: voicePrint(0.8, 0.3), 2: voicePrint()], seconds: [1: 100, 2: 100], store: try store())
        #expect(fills.count == 1)
        #expect(fills.first?.voice == 2)
        #expect(fills.first?.person == "Mei")
        // Directly exercise a non-greedy optimum, independent of margin gating.
        #expect(VoiceMatching.assignment([[0.8, 0.7, 0, 0], [0.9, -1, 0, 0]]) == [1, 0])
    }

    @Test func oneVoiceCloseToTwoPeopleStaysEmpty() throws {
        #expect(VoiceMatching.match(prints: [1: voicePrint(1, 1)], seconds: [1: 100], store: try store()).isEmpty)
    }

    @Test func twoClearVoicesFillTwoDifferentPeople() throws {
        let fills = VoiceMatching.match(
            prints: [2: voicePrint(0, 1), 1: voicePrint()], seconds: [1: 100, 2: 100], store: try store())
        #expect(fills.map(\.person) == ["Mei", "Ana"])
    }

    @Test func negativeExamplesSuppressOnlyNearbyPrints() throws {
        var store = try store()
        try store.addNegative(voiceExample("negative"), for: "Mei")
        #expect(VoiceMatching.match(prints: [1: voicePrint()], seconds: [1: 100], store: store).isEmpty)
        #expect(
            VoiceMatching.match(prints: [1: voicePrint(0, 1)], seconds: [1: 100], store: store).first?.person == "Ana")
    }

    @Test func microphoneShortcutRequiresHeadphonesAndExactlyOneVoice() {
        func match(_ headphones: Bool, _ voices: Set<Int>) -> [VoiceMatching.Fill] {
            VoiceMatching.match(
                prints: [:], seconds: [1: 10, 2: 10], store: VoiceStore(), headphones: headphones,
                microphoneOnlyVoices: voices, you: "Sam")
        }
        #expect(match(false, [1]).isEmpty)
        #expect(match(true, [1, 2]).isEmpty)
        #expect(match(true, []).isEmpty)
        #expect(match(true, [1]).first?.person == "Sam")
        #expect(match(true, [1]).first?.microphone == true)
    }

    @Test func mixedOrUnknownSidesCannotEstablishMicrophoneIdentity() {
        let mic = TranscriptLine(start: 0, end: 10, side: .microphone, text: "A line.")
        let computer = TranscriptLine(start: 10, end: 20, side: .computer, text: "Another line.")
        let unknown = TranscriptLine(start: 20, end: 30, text: "A third line.")
        #expect(SpeakerLabels.microphoneOnlyVoices(lines: [mic, computer], assigned: [1, 2]) == [1])
        #expect(SpeakerLabels.microphoneOnlyVoices(lines: [mic, mic], assigned: [1, 2]).isEmpty)
        #expect(SpeakerLabels.microphoneOnlyVoices(lines: [mic, computer], assigned: [1, 1]).isEmpty)
        #expect(SpeakerLabels.microphoneOnlyVoices(lines: [mic, unknown], assigned: [1, 1]).isEmpty)
        #expect(SpeakerLabels.microphoneOnlyVoices(lines: [mic, mic, computer], assigned: [1, 2, 2]).isEmpty)
    }

    @Test func confirmedFeedbackLowersBarAndCorrectionsRaiseItWithinBounds() throws {
        var store = try store()
        let initial = VoiceMatching.bar(for: store.people["Mei"]!)
        for index in 0..<30 {
            store.recordFeedback(for: "Mei", stamp: "\(index)", voice: 1, similarity: 0.55, confirmed: true)
        }
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) < initial)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) >= 0.5)
        for index in 0..<30 {
            store.recordFeedback(for: "Mei", stamp: "\(index)", voice: 1, similarity: 1, confirmed: false)
        }
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) > initial)
        #expect(VoiceMatching.bar(for: store.people["Mei"]!) <= 0.9)
    }

    @Test func cosineNormalizesAndRejectsMalformedPrints() {
        #expect(VoiceMatching.cosine(voicePrint(2), voicePrint(8)) == 1)
        #expect(VoiceMatching.cosine([1], voicePrint()) == -1)
        #expect(VoiceMatching.cosine(voicePrint(.nan), voicePrint()) == -1)
    }

    @Test func topKBalancesModesAndPenalizesIsolatedOutliers() throws {
        var store = VoiceStore()
        for index in 0..<3 { try store.addExample(voiceExample("\(index)", print: voicePrint(0, 1)), for: "Mei") }
        try store.addExample(voiceExample("outlier"), for: "Mei")
        #expect(VoiceMatching.similarity(voicePrint(), to: store.people["Mei"]!) < 0.65)
        #expect(VoiceMatching.similarity(voicePrint(0, 1), to: store.people["Mei"]!) == 1)
    }

    @Test func namedPeopleRemainCompetitorsAndCannotFillTwice() throws {
        let store = try store()
        #expect(
            VoiceMatching.match(prints: [2: voicePrint()], seconds: [2: 100], store: store, named: [1: "Mei"]).isEmpty)
        #expect(
            VoiceMatching.match(
                prints: [:], seconds: [2: 100], store: store, headphones: true,
                microphoneOnlyVoices: [2], you: "Mei", named: [1: "Mei"]
            ).isEmpty)
    }

    @Test func invalidDurationDoesNotMatch() throws {
        for seconds in [Double.nan, .infinity, -1] {
            #expect(VoiceMatching.match(prints: [1: voicePrint()], seconds: [1: seconds], store: try store()).isEmpty)
        }
    }
}
