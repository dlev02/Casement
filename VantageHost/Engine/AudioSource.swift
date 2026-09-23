import Foundation

/// 10 ms of 48 kHz stereo audio, interleaved Float32 (L R L R …), ready for the Opus encoder.
nonisolated struct AudioBlock: Sendable {
    static let sampleRate = 48_000
    static let channels = 2
    /// 10 ms: Opus's packet size here, and the unit everything downstream counts in.
    static let frames = 480
    static let nanosPerBlock: UInt64 = 10_000_000

    /// `frames * channels` samples.
    var samples: [Float]
    /// Host capture time of the first frame (host monotonic clock, nanoseconds).
    var captureNanos: UInt64
}

/// A source of the Mac's audio: ScreenCaptureKit in normal operation, a synthetic chime for
/// headless testing. Delivers fixed 10 ms blocks on its own queue.
nonisolated protocol AudioSource: AnyObject, Sendable {
    /// Starts delivering blocks. `onStop` reports a user-facing reason if audio stops on its own.
    func start(onBlock: @escaping @Sendable (AudioBlock) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws
    func stop() async
}

/// Turns capture callbacks of any size into fixed 480-frame blocks.
///
/// ScreenCaptureKit doesn't document its audio buffer size, so nothing downstream may assume one.
/// Timestamps follow the samples: each block's time is the time of its first frame. When a
/// callback's timestamp jumps ahead of where the samples say it should be (capture paused while
/// the Mac was silent, or a hiccup), the partial block is finished with silence and a new
/// timeline starts at the new time, so the client can tell a pause from late packets. Small
/// timestamp jitter is ignored: the sample count is the clock.
nonisolated struct AudioRepacketizer {
    /// How far a callback's timestamp may disagree with the running sample clock before it counts
    /// as a new timeline.
    static let discontinuityNanos: UInt64 = 15_000_000

    private var pending: [Float] = []
    /// Time of `pending`'s first frame, or of the next frame when `pending` is empty.
    private var pendingStartNanos: UInt64?
    private var pendingFrames: Int { pending.count / AudioBlock.channels }

    init() {
        pending.reserveCapacity(AudioBlock.frames * AudioBlock.channels * 4)
    }

    /// Where the next frame would land on the current timeline.
    private var expectedNanos: UInt64? {
        pendingStartNanos.map { $0 + UInt64(pendingFrames) * 1_000_000_000 / UInt64(AudioBlock.sampleRate) }
    }

    /// Appends planar (one buffer per channel) or mono samples. A mono source is copied to both
    /// channels; channels past the second are ignored.
    mutating func append(planar channels: [UnsafeBufferPointer<Float>], startNanos: UInt64) -> [AudioBlock] {
        guard let first = channels.first, !first.isEmpty else { return [] }
        let frames = channels.map(\.count).min() ?? 0
        var blocks = beginChunk(at: startNanos)
        let left = first
        let right = channels.count > 1 ? channels[1] : first
        for index in 0..<frames {
            pending.append(left[index])
            pending.append(right[index])
        }
        blocks += drain()
        return blocks
    }

    /// Appends interleaved stereo samples.
    mutating func append(interleaved samples: UnsafeBufferPointer<Float>, startNanos: UInt64) -> [AudioBlock] {
        guard samples.count >= AudioBlock.channels else { return [] }
        var blocks = beginChunk(at: startNanos)
        pending.append(contentsOf: samples.prefix(samples.count - samples.count % AudioBlock.channels))
        blocks += drain()
        return blocks
    }

    /// Drops the partial block and the timeline (the next chunk starts a fresh one).
    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        pendingStartNanos = nil
    }

    private mutating func beginChunk(at startNanos: UInt64) -> [AudioBlock] {
        guard let expected = expectedNanos else {
            pendingStartNanos = startNanos
            return []
        }
        let drift = startNanos > expected ? startNanos - expected : expected - startNanos
        guard drift > Self.discontinuityNanos else { return [] }
        // New timeline: finish the partial block with silence so it isn't glued to later audio.
        var blocks: [AudioBlock] = []
        if !pending.isEmpty, let start = pendingStartNanos {
            pending += Array(repeating: 0, count: AudioBlock.frames * AudioBlock.channels - pending.count)
            blocks.append(AudioBlock(samples: pending, captureNanos: start))
        }
        pending.removeAll(keepingCapacity: true)
        pendingStartNanos = startNanos
        return blocks
    }

    private mutating func drain() -> [AudioBlock] {
        let blockSamples = AudioBlock.frames * AudioBlock.channels
        guard pending.count >= blockSamples, var start = pendingStartNanos else { return [] }
        var blocks: [AudioBlock] = []
        var offset = 0
        while pending.count - offset >= blockSamples {
            blocks.append(AudioBlock(samples: Array(pending[offset..<offset + blockSamples]), captureNanos: start))
            offset += blockSamples
            start += AudioBlock.nanosPerBlock
        }
        pending.removeFirst(offset)
        pendingStartNanos = start
        return blocks
    }
}
