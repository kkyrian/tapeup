import Foundation
import Testing

@testable import TapeUpCore

func voicePrint(_ x: Float = 1, _ y: Float = 0) -> [Float] {
    [x, y] + Array(repeating: 0, count: VoiceStore.dimensions - 2)
}

func voiceExample(_ stamp: String = "meeting", voice: Int = 1, seconds: Double = 100, print: [Float] = voicePrint())
    -> VoiceStore.Example
{
    .init(print: print, stamp: stamp, voice: voice, seconds: seconds)
}

struct VoiceStoreTests {
    @Test func missingStoreIsEmpty() {
        #expect(VoiceStore.load(from: URL(fileURLWithPath: "/nonexistent-\(UUID())")).count == 0)
    }

    @Test func unreadableStoreIsPreservedAndReplaced() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let bad = Data("not json".utf8)
        try bad.write(to: VoiceStore.url(in: fixture.root))
        let store = VoiceStore.load(from: fixture.root)
        #expect(store.count == 0)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
        let aside = try #require(files.first { $0.lastPathComponent.hasPrefix(".voices-unreadable-") })
        #expect(try Data(contentsOf: aside) == bad)
        try store.save(to: fixture.root)
        #expect(VoiceStore.load(from: fixture.root) == store)
    }

    @Test func capsPositiveAndNegativeExamplesByTalkAndReplacesIdentity() throws {
        var store = VoiceStore()
        for index in 0..<25 {
            try store.addExample(voiceExample("\(index)", seconds: Double(index + 31)), for: "Mei")
            try store.addNegative(voiceExample("\(index)", seconds: Double(index + 31)), for: "Ana")
        }
        #expect(store.people["Mei"]?.examples.count == 20)
        #expect(store.people["Mei"]?.examples.last?.seconds == 36)
        #expect(store.people["Ana"]?.negatives.count == 20)
        #expect(store.people["Ana"]?.negatives.last?.seconds == 36)
        try store.addExample(voiceExample("24", seconds: 90), for: "Mei")
        #expect(store.people["Mei"]?.examples.first?.seconds == 90)
        #expect(store.people["Mei"]?.examples.count == 20)
        try store.addExample(voiceExample("24", seconds: 90), for: "Sam")
        #expect(store.people["Mei"]?.examples.count == 19)
        store.removeExample(stamp: "24", voice: 1)
        #expect(store.people["Sam"]?.examples.isEmpty == true)
    }

    @Test func storeRoundTripRenameMergeAndForget() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        var store = VoiceStore()
        try store.addExample(voiceExample("a"), for: "Mei")
        try store.addExample(voiceExample("b"), for: "Ana")
        try store.addNegative(voiceExample("c"), for: "Mei")
        store.recordFeedback(for: "Mei", stamp: "d", voice: 1, similarity: 0.7, confirmed: true)
        store.renamePerson("Mei", to: "José Ortiz")
        store.mergePersons("Ana", into: "José Ortiz")
        try store.save(to: fixture.root)
        #expect(VoiceStore.load(from: fixture.root) == store)
        #expect(store.count == 1)
        #expect(store.people["José Ortiz"]?.examples.count == 2)
        #expect(store.people["José Ortiz"]?.negatives.count == 1)
        #expect(store.people["José Ortiz"]?.feedback.count == 1)
        store.forgetPerson("José Ortiz")
        #expect(store.count == 0)
        try store.addExample(voiceExample(), for: "Ana")
        store.forgetAll()
        #expect(store.people.isEmpty)
    }

    @Test func malformedPrintsAndDurationsCannotTeach() {
        var store = VoiceStore()
        for print in [[Float](), [1], voicePrint(.nan), voicePrint(.infinity), voicePrint(0)] {
            #expect(throws: VoiceStore.StoreError.self) { try store.addExample(voiceExample(print: print), for: "Mei") }
        }
        for seconds in [Double.nan, .infinity, 0, -1] {
            #expect(throws: VoiceStore.StoreError.self) {
                try store.addNegative(voiceExample(seconds: seconds), for: "Mei")
            }
        }
        #expect(store.count == 0)
    }

    @Test func savingDoesNotOverwriteUnreadableOriginal() throws {
        let fixture = try VoiceFixture()
        defer { fixture.remove() }
        let bad = Data("broken".utf8)
        try bad.write(to: VoiceStore.url(in: fixture.root))
        #expect(throws: (any Error).self) { try VoiceStore().save(to: fixture.root) }
        #expect(try Data(contentsOf: VoiceStore.url(in: fixture.root)) == bad)
    }

    @Test func feedbackIsBoundedAndReplacesSameDecision() {
        var store = VoiceStore()
        for index in 0..<30 {
            store.recordFeedback(for: "Mei", stamp: "\(index)", voice: 1, similarity: 0.8, confirmed: true)
        }
        store.recordFeedback(for: "Mei", stamp: "29", voice: 1, similarity: 0.9, confirmed: false)
        #expect(store.people["Mei"]?.feedback.count == 20)
        #expect(store.people["Mei"]?.feedback.last?.confirmed == false)
    }
}
