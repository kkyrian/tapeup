import Testing

@testable import TapeUpCore

struct HeadphonesTests {
    @Test func appleBluetoothModelsCountAsHeadphones() {
        #expect(CoreAudioSystem.isAppleBluetooth(modelUID: "2027 4c"))
        #expect(CoreAudioSystem.isAppleBluetooth(modelUID: "200E 4C"))
    }

    @Test func otherModelsDoNot() {
        #expect(!CoreAudioSystem.isAppleBluetooth(modelUID: nil))
        #expect(!CoreAudioSystem.isAppleBluetooth(modelUID: ""))
        #expect(!CoreAudioSystem.isAppleBluetooth(modelUID: "Speaker"))
        #expect(!CoreAudioSystem.isAppleBluetooth(modelUID: "0a3c 54c"))
        #expect(!CoreAudioSystem.isAppleBluetooth(modelUID: "4c 0057"))
    }
}
