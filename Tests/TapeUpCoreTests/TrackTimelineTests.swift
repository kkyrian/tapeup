import Testing

@testable import TapeUpCore

struct TrackTimelineTests {
    @Test func contiguousChunksAppendInOrder() {
        var track = TrackTimeline(toleranceFrames: 2)
        track.append(startFrame: 0, samples: [1, 2])
        track.append(startFrame: 2, samples: [3])
        #expect(track.take(upTo: 3) == [1, 2, 3])
        #expect(track.corrections == 0)
    }

    @Test func jitterWithinToleranceStaysContiguous() {
        var track = TrackTimeline(toleranceFrames: 2)
        track.append(startFrame: 0, samples: [1, 2])
        track.append(startFrame: 4, samples: [3])
        #expect(track.take(upTo: 3) == [1, 2, 3])
    }

    @Test func gapBecomesSilenceOfTheRightLength() {
        var track = TrackTimeline(toleranceFrames: 1)
        track.append(startFrame: 0, samples: [1])
        track.append(startFrame: 5, samples: [2])
        #expect(track.take(upTo: 6) == [1, 0, 0, 0, 0, 2])
        #expect(track.insertedSilenceFrames == 4)
    }

    @Test func lateStartIsPaddedFromZero() {
        var track = TrackTimeline(toleranceFrames: 0)
        track.append(startFrame: 3, samples: [9])
        #expect(track.take(upTo: 4) == [0, 0, 0, 9])
    }

    @Test func overlapDropsTheRepeatedFrames() {
        var track = TrackTimeline(toleranceFrames: 0)
        track.append(startFrame: 0, samples: [1, 2, 3, 4])
        track.append(startFrame: 2, samples: [5, 6, 7])
        #expect(track.take(upTo: 5) == [1, 2, 3, 4, 7])
        #expect(track.droppedFrames == 2)
    }

    @Test func dataBeforeTheWrittenPointIsDropped() {
        var track = TrackTimeline(toleranceFrames: 0)
        track.append(startFrame: 0, samples: [1, 2])
        _ = track.take(upTo: 4)
        track.append(startFrame: 1, samples: [7, 8])
        #expect(track.droppedFrames == 2)
        #expect(track.end == 4)
    }

    @Test func takeZeroFillsWhatNeverArrived() {
        var track = TrackTimeline(toleranceFrames: 0)
        #expect(track.take(upTo: 3) == [0, 0, 0])
        track.append(startFrame: 3, samples: [1])
        #expect(track.take(upTo: 4) == [1])
    }

    @Test func takeBackwardsReturnsNothing() {
        var track = TrackTimeline(toleranceFrames: 0)
        _ = track.take(upTo: 5)
        #expect(track.take(upTo: 2).isEmpty)
        #expect(track.writtenUpTo == 5)
    }

    @Test func missingTimestampContinuesThePreviousChunk() {
        var track = TrackTimeline(toleranceFrames: 1)
        track.append(startFrame: 0, samples: [1])
        track.append(startFrame: nil, samples: [2])
        #expect(track.take(upTo: 2) == [1, 2])
        #expect(track.untrustedTimestamps == 0)
    }

    @Test func timestampBeyondTheGapCapIsNotTrusted() {
        var track = TrackTimeline(toleranceFrames: 1, maxGapFrames: 10)
        track.append(startFrame: 0, samples: [1])
        track.append(startFrame: 1_000_000, samples: [2])
        #expect(track.take(upTo: 2) == [1, 2])
        #expect(track.untrustedTimestamps == 1)
        #expect(track.insertedSilenceFrames == 0)
    }

    @Test func gapWithinTheCapIsStillSilence() {
        var track = TrackTimeline(toleranceFrames: 1, maxGapFrames: 10)
        track.append(startFrame: 0, samples: [1])
        track.append(startFrame: 10, samples: [2])
        #expect(track.insertedSilenceFrames == 9)
        #expect(track.untrustedTimestamps == 0)
    }
}
