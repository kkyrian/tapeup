/// One mono track placed on the recording's shared clock.
///
/// Capture callbacks arrive with host timestamps. Placing each chunk at the
/// frame its timestamp names, rather than appending blindly, means a device
/// reconnect leaves silence of the right length and later audio stays aligned
/// with the other track.
public struct TrackTimeline: Sendable {
    /// Chunks that start within this many frames of the expected position are
    /// treated as contiguous, absorbing timestamp jitter and slow clock drift.
    public let toleranceFrames: Int64

    /// Frames already handed to the writer.
    public private(set) var writtenUpTo: Int64 = 0
    /// Samples from `writtenUpTo` onward, zero-filled where gaps occurred.
    private var pending: [Float] = []

    public private(set) var insertedSilenceFrames: Int64 = 0
    public private(set) var droppedFrames: Int64 = 0
    public private(set) var corrections: Int = 0

    /// A chunk that claims to start further ahead than this is trusted no
    /// more than one without a timestamp. The writer zero-fills real gaps as
    /// time passes, so a genuine gap never gets this far ahead of `end`.
    public let maxGapFrames: Int64

    public private(set) var untrustedTimestamps: Int = 0

    public init(toleranceFrames: Int64, maxGapFrames: Int64 = .max) {
        self.toleranceFrames = toleranceFrames
        self.maxGapFrames = maxGapFrames
    }

    /// Starts the track at `frame` instead of zero, before anything is placed,
    /// so a recording begins with its first sound rather than with the time
    /// the devices took to start.
    public mutating func begin(at frame: Int64) {
        guard pending.isEmpty, writtenUpTo == 0 else { return }
        writtenUpTo = frame
    }

    /// The frame after the last sample placed so far.
    public var end: Int64 { writtenUpTo + Int64(pending.count) }

    /// Places a chunk at `startFrame`, or straight after the previous chunk
    /// when there is no usable timestamp.
    public mutating func append(startFrame: Int64?, samples: [Float]) {
        guard !samples.isEmpty else { return }
        guard let startFrame, startFrame - end <= maxGapFrames else {
            if startFrame != nil { untrustedTimestamps += 1 }
            pending.append(contentsOf: samples)
            return
        }
        let offset = startFrame - end
        if abs(offset) <= toleranceFrames {
            pending.append(contentsOf: samples)
        } else if offset > 0 {
            pending.append(contentsOf: repeatElement(0, count: Int(offset)))
            pending.append(contentsOf: samples)
            insertedSilenceFrames += offset
            corrections += 1
        } else {
            let overlap = -offset
            corrections += 1
            if overlap >= Int64(samples.count) {
                droppedFrames += Int64(samples.count)
                return
            }
            pending.append(contentsOf: samples[Int(overlap)...])
            droppedFrames += overlap
        }
    }

    /// Hands over every frame before `frame`, zero-filling what never arrived.
    public mutating func take(upTo frame: Int64) -> [Float] {
        let count = Int(frame - writtenUpTo)
        guard count > 0 else { return [] }
        var out: [Float]
        if pending.count >= count {
            out = Array(pending[..<count])
            pending.removeFirst(count)
        } else {
            out = pending
            out.append(contentsOf: repeatElement(0, count: count - pending.count))
            pending.removeAll(keepingCapacity: true)
        }
        writtenUpTo = frame
        return out
    }
}
