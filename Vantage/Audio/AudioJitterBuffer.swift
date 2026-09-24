import Foundation
import Synchronization

/// The Mac-audio jitter buffer: a lock-free single-producer, single-consumer ring of interleaved
/// stereo Float32 frames with an adaptive playout target.
///
/// - The **producer** (the player's decode queue) calls `push`.
/// - The **consumer** (the audio render thread) calls `render`. It never locks, allocates, or
///   waits: the two sides share only atomics.
/// - Anyone may call `reset()` and read `stats`.
///
/// Playback starts once the buffer holds the target (40–80 ms), not at the first packet. When it
/// runs dry the output fades to silence and it waits for the target again. A dry spell caused by
/// late packets (the next packet continues the host's timeline) raises the target by 10 ms; one
/// caused by the Mac going quiet (the host's timeline jumps) doesn't. After 10 s without a late
/// underrun the target comes down 4 ms. The Mac's and iPad's sample clocks drift apart by tens of
/// ppm, so when the smoothed depth leaves target ± 15 ms, one render block is stretched or
/// squeezed by a single frame (linear interpolation, inaudible); a burst far above the target
/// (packets that queued behind a video keyframe) is cut back to the target with a crossfade.
/// Found before playback starts, such a backlog is left out instead: nothing is playing yet to
/// crossfade from, and the fade-in starts from silence either way.
nonisolated final class AudioJitterBuffer: @unchecked Sendable {
    struct Stats: Sendable, Equatable {
        /// Frames buffered at the last render.
        var depthFrames = 0
        /// The depth smoothed over the last hundred or so renders: the latency the listener has,
        /// and what the drift correction steers by. `depthFrames` moves a packet at a time.
        var smoothedDepthFrames = 0
        var targetFrames = 0
        /// Dry spells caused by late packets.
        var underruns = 0
        /// Dry spells because the host's audio paused (silence), which don't count against the network.
        var idleGaps = 0
        /// Render blocks squeezed (one frame dropped) or stretched (one frame repeated) for drift.
        var drops = 0
        var duplicates = 0
        /// Bursts cut back to the target while playing.
        var skips = 0
        /// Starts that found far more than the target buffered and began at the target.
        var startTrims = 0
        /// Packets dropped because the ring was full.
        var overflows = 0
        var framesPushed = 0
        var framesPlayed = 0
        var isPlaying = false

        func milliseconds(_ frames: Int, sampleRate: Double = 48_000) -> Double { Double(frames) / sampleRate * 1000 }
    }

    let sampleRate: Double
    let minTarget: Int
    let maxTarget: Int
    let initialTarget: Int
    let growStep: Int
    let shrinkStep: Int
    let shrinkAfterFrames: Int
    let band: Int
    let skipAbove: Int
    let fadeFrames: Int

    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total frames written / read. The producer owns `written`, the consumer `read`.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// Set by the consumer when it runs dry; the producer answers from the next packet's time.
    private let underrunCheck = Atomic<Bool>(false)
    private let lateUnderruns = Atomic<Int>(0)
    private let idleGaps = Atomic<Int>(0)
    private let resetGeneration = Atomic<Int>(0)
    // Mirrors of consumer state for `stats`.
    private let depthMirror = Atomic<Int>(0)
    private let smoothedDepthMirror = Atomic<Int>(0)
    private let targetMirror = Atomic<Int>(0)
    private let playingMirror = Atomic<Bool>(false)
    private let drops = Atomic<Int>(0)
    private let duplicates = Atomic<Int>(0)
    private let skips = Atomic<Int>(0)
    private let startTrims = Atomic<Int>(0)
    private let overflows = Atomic<Int>(0)
    private let framesPlayed = Atomic<Int>(0)

    // Producer-only.
    private var lastEndNanos: UInt64?

    // Consumer-only.
    private var playing = false
    private var target: Int
    private var smoothedDepth = 0.0
    private var seenLateUnderruns = 0
    private var seenReset = 0
    private var framesSinceUnderrun = 0
    private var fadeInRemaining = 0
    private let scratch: UnsafeMutablePointer<Float>
    private let crossfade: UnsafeMutablePointer<Float>
    private static let chunk = 1_024

    init(sampleRate: Double = 48_000, minTargetMs: Double = 40, maxTargetMs: Double = 80, initialTargetMs: Double = 50) {
        func frames(_ ms: Double) -> Int { Int(ms * sampleRate / 1000) }
        self.sampleRate = sampleRate
        minTarget = frames(minTargetMs)
        maxTarget = frames(maxTargetMs)
        initialTarget = frames(initialTargetMs)
        growStep = frames(10)
        shrinkStep = frames(4)
        shrinkAfterFrames = frames(10_000)
        band = frames(15)
        skipAbove = frames(90)
        fadeFrames = frames(5)
        target = initialTarget
        var size = 1
        while size < Int(sampleRate) { size <<= 1 } // ~1.4 s at 48 kHz
        capacity = size
        mask = size - 1
        storage = .allocate(capacity: size * 2)
        storage.initialize(repeating: 0, count: size * 2)
        scratch = .allocate(capacity: (Self.chunk + 2) * 2)
        crossfade = .allocate(capacity: (Self.chunk + 2) * 2)
        targetMirror.store(target, ordering: .relaxed)
    }

    deinit {
        storage.deallocate()
        scratch.deallocate()
        crossfade.deallocate()
    }

    var stats: Stats {
        Stats(depthFrames: depthMirror.load(ordering: .relaxed), smoothedDepthFrames: smoothedDepthMirror.load(ordering: .relaxed),
              targetFrames: targetMirror.load(ordering: .relaxed),
              underruns: lateUnderruns.load(ordering: .relaxed), idleGaps: idleGaps.load(ordering: .relaxed),
              drops: drops.load(ordering: .relaxed), duplicates: duplicates.load(ordering: .relaxed),
              skips: skips.load(ordering: .relaxed), startTrims: startTrims.load(ordering: .relaxed),
              overflows: overflows.load(ordering: .relaxed),
              framesPushed: written.load(ordering: .relaxed), framesPlayed: framesPlayed.load(ordering: .relaxed),
              isPlaying: playingMirror.load(ordering: .relaxed))
    }

    /// Empties the buffer and goes back to the initial target (a new route, or after a pause).
    /// Takes effect at the next render.
    func reset() {
        resetGeneration.add(1, ordering: .releasing)
    }

    // MARK: Producer

    /// Adds one decoded packet. `captureNanos` is the host time of its first frame; mono input is
    /// copied to both channels.
    func push(_ samples: UnsafeBufferPointer<Float>, channels: Int, captureNanos: UInt64) {
        guard channels == 1 || channels == 2 else { return }
        let frames = samples.count / channels
        guard frames > 0 else { return }
        // Was the consumer's last dry spell the network's fault? Only if this packet carries on
        // where the previous one ended; a jump means the host's capture paused.
        let contiguous = lastEndNanos.map { end in
            let gap = captureNanos > end ? captureNanos - end : end - captureNanos
            return gap < 30_000_000
        } ?? false
        if underrunCheck.exchange(false, ordering: .acquiringAndReleasing) {
            if contiguous { lateUnderruns.add(1, ordering: .releasing) } else { idleGaps.add(1, ordering: .relaxed) }
        }
        lastEndNanos = captureNanos + UInt64(Double(frames) / sampleRate * 1e9)

        let writeAt = written.load(ordering: .relaxed)
        let used = writeAt - read.load(ordering: .acquiring)
        guard capacity - used >= frames else {
            overflows.add(1, ordering: .relaxed)
            return
        }
        for index in 0..<frames {
            let slot = ((writeAt + index) & mask) * 2
            if channels == 2 {
                storage[slot] = samples[index * 2]
                storage[slot + 1] = samples[index * 2 + 1]
            } else {
                storage[slot] = samples[index]
                storage[slot + 1] = samples[index]
            }
        }
        written.store(writeAt + frames, ordering: .releasing)
    }

    // MARK: Consumer (render thread)

    /// Fills `frames` frames of planar output. Real-time safe.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        var offset = 0
        while offset < frames {
            let count = min(Self.chunk, frames - offset)
            renderChunk(left: left + offset, right: right + offset, frames: count)
            offset += count
        }
    }

    private func renderChunk(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames n: Int) {
        let generation = resetGeneration.load(ordering: .acquiring)
        if generation != seenReset {
            seenReset = generation
            read.store(written.load(ordering: .acquiring), ordering: .releasing)
            underrunCheck.store(false, ordering: .relaxed)
            playing = false
            target = initialTarget
            framesSinceUnderrun = 0
        }
        let late = lateUnderruns.load(ordering: .acquiring)
        if late != seenLateUnderruns {
            target = min(maxTarget, target + growStep * (late - seenLateUnderruns))
            seenLateUnderruns = late
            framesSinceUnderrun = 0
        }
        var readAt = read.load(ordering: .relaxed)
        var available = written.load(ordering: .acquiring) - readAt

        if !playing {
            guard available >= max(target, n) else {
                silence(left, right, n)
                publish(depth: available)
                return
            }
            playing = true
            fadeInRemaining = fadeFrames
            if available - n > target + skipAbove {
                // A backlog before anything has played (late packets after a dry spell, all at
                // once): start `target` behind the newest audio rather than that far behind.
                // Unlike a skip, nothing audible is cut: the fade-in starts from silence.
                readAt += available - n - target
                available = target + n
                startTrims.add(1, ordering: .relaxed)
            }
            smoothedDepth = Double(available - n)
        }

        if available < n + fadeFrames {
            // Running dry. Stopping one fade early guarantees there are at least `fadeFrames`
            // left to fade over (a render only ever takes `n`), so the output ramps to zero
            // instead of stepping. What's left stays buffered and plays, fading in, on resume.
            let fade = min(available, n)
            copy(from: readAt, frames: fade, into: scratch)
            for index in 0..<n {
                if index < fade {
                    let gain = Float(fade - index) / Float(max(fade, 1))
                    left[index] = scratch[index * 2] * gain
                    right[index] = scratch[index * 2 + 1] * gain
                } else {
                    left[index] = 0
                    right[index] = 0
                }
            }
            readAt += fade
            read.store(readAt, ordering: .releasing)
            framesPlayed.add(fade, ordering: .relaxed)
            playing = false
            underrunCheck.store(true, ordering: .releasing)
            publish(depth: available - fade)
            return
        }

        if available - n > target + skipAbove, available >= 2 * n + target {
            // A burst far above the target: jump to `target` frames of latency with a crossfade.
            copy(from: readAt, frames: n, into: crossfade)
            let skipTo = written.load(ordering: .relaxed) - target - n
            copy(from: skipTo, frames: n, into: scratch)
            for index in 0..<n {
                let w = Float(index) / Float(n)
                left[index] = crossfade[index * 2] * (1 - w) + scratch[index * 2] * w
                right[index] = crossfade[index * 2 + 1] * (1 - w) + scratch[index * 2 + 1] * w
            }
            readAt = skipTo + n
            skips.add(1, ordering: .relaxed)
            smoothedDepth = Double(target)
        } else {
            // What stays buffered after this block: the latency the listener actually has.
            smoothedDepth += (Double(available - n) - smoothedDepth) * 0.01
            var consume = n
            if smoothedDepth > Double(target + band), available >= n + 1, n > 1 {
                consume = n + 1
                drops.add(1, ordering: .relaxed)
            } else if smoothedDepth < Double(target - band), n > 2 {
                consume = n - 1
                duplicates.add(1, ordering: .relaxed)
            }
            copy(from: readAt, frames: consume, into: scratch)
            if consume == n {
                for index in 0..<n {
                    left[index] = scratch[index * 2]
                    right[index] = scratch[index * 2 + 1]
                }
            } else {
                // Spread the one-frame difference over the block.
                let step = Double(consume - 1) / Double(n - 1)
                for index in 0..<n {
                    let position = Double(index) * step
                    let base = min(Int(position), consume - 2)
                    let fraction = Float(position - Double(base))
                    left[index] = scratch[base * 2] + (scratch[(base + 1) * 2] - scratch[base * 2]) * fraction
                    right[index] = scratch[base * 2 + 1] + (scratch[(base + 1) * 2 + 1] - scratch[base * 2 + 1]) * fraction
                }
            }
            readAt += consume
        }

        if fadeInRemaining > 0 {
            let count = min(fadeInRemaining, n)
            for index in 0..<count {
                let gain = Float(fadeFrames - fadeInRemaining + index + 1) / Float(fadeFrames)
                left[index] *= gain
                right[index] *= gain
            }
            fadeInRemaining -= count
        }

        read.store(readAt, ordering: .releasing)
        framesPlayed.add(n, ordering: .relaxed)
        framesSinceUnderrun += n
        if framesSinceUnderrun >= shrinkAfterFrames {
            framesSinceUnderrun = 0
            target = max(minTarget, target - shrinkStep)
        }
        publish(depth: written.load(ordering: .relaxed) - readAt)
    }

    private func copy(from start: Int, frames: Int, into destination: UnsafeMutablePointer<Float>) {
        for index in 0..<frames {
            let slot = ((start + index) & mask) * 2
            destination[index * 2] = storage[slot]
            destination[index * 2 + 1] = storage[slot + 1]
        }
    }

    private func silence(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ n: Int) {
        left.update(repeating: 0, count: n)
        right.update(repeating: 0, count: n)
    }

    private func publish(depth: Int) {
        depthMirror.store(depth, ordering: .relaxed)
        smoothedDepthMirror.store(playing ? Int(smoothedDepth) : depth, ordering: .relaxed)
        targetMirror.store(target, ordering: .relaxed)
        playingMirror.store(playing, ordering: .relaxed)
    }
}
