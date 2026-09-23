import Foundation

/// A quiet, recognisable test signal: a two-note "ding-dong" chime every two seconds, never above
/// −18 dBFS, the first note leaning left and the second right. Pure and deterministic, so tests
/// can check what comes out the far end.
nonisolated struct ChimeSynth {
    static let peak: Float = 0.125_9 // −18 dBFS
    static let period = 2.0
    /// (start seconds into the period, frequency, left gain, right gain)
    static let notes: [(start: Double, frequency: Double, left: Float, right: Float)] = [
        (0.0, 783.99, 1.0, 0.7),  // G5
        (0.32, 659.25, 0.7, 1.0), // E5
    ]
    static let noteLength = 1.4

    private(set) var frame: Int = 0
    let sampleRate: Double

    init(sampleRate: Double = Double(AudioBlock.sampleRate)) {
        self.sampleRate = sampleRate
    }

    /// Renders `frames` interleaved stereo frames into `output` and advances.
    mutating func render(into output: UnsafeMutableBufferPointer<Float>, frames: Int) {
        let periodFrames = Int(Self.period * sampleRate)
        for index in 0..<frames {
            let t = Double((frame + index) % periodFrames) / sampleRate
            var left: Float = 0, right: Float = 0
            for note in Self.notes where t >= note.start && t < note.start + Self.noteLength {
                let value = Self.voice(time: t - note.start, frequency: note.frequency)
                left += value * note.left
                right += value * note.right
            }
            output[index * 2] = left
            output[index * 2 + 1] = right
        }
        frame += frames
    }

    /// Fundamental plus a softer octave, a 4 ms attack, an exponential decay, and a short fade at
    /// the end of the note so it never clicks.
    private static func voice(time: Double, frequency: Double) -> Float {
        let attack = min(1, time / 0.004)
        let release = min(1, (noteLength - time) / 0.05)
        let envelope = attack * exp(-time / 0.35) * release
        let tone = sin(2 * .pi * frequency * time) + 0.3 * sin(2 * .pi * 2 * frequency * time)
        // The second note starts while the first still rings (at 40 % in the louder channel), so
        // each voice sits a little under the peak and the overlap never crosses it.
        return Float(envelope * tone / 1.3 / 1.28) * peak
    }
}

/// Feeds `ChimeSynth` through the same repacketizer as real capture, paced by the wall clock so
/// the stream runs at exactly 48 kHz on average whatever the timer does. Used with
/// `--synthetic-capture`, so the whole audio path runs without Screen Recording.
nonisolated final class SyntheticAudioSource: AudioSource, @unchecked Sendable {
    private let queue = DispatchQueue(label: "vantage.synthetic.audio", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var synth = ChimeSynth()
    private var repacketizer = AudioRepacketizer()
    private var startNanos: UInt64 = 0
    private var produced = 0
    private var scratch = [Float](repeating: 0, count: AudioBlock.sampleRate / 10 * AudioBlock.channels)

    init() {}

    func start(onBlock: @escaping @Sendable (AudioBlock) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws {
        queue.sync {
            startNanos = MonotonicClock.nanos()
            produced = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick(onBlock) }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
            repacketizer.reset()
        }
    }

    private func tick(_ onBlock: @Sendable (AudioBlock) -> Void) {
        let elapsed = MonotonicClock.nanos() - startNanos
        let due = Int(elapsed * UInt64(AudioBlock.sampleRate) / 1_000_000_000)
        // After a long stall (debugger, sleep) skip ahead instead of bursting.
        if due - produced > AudioBlock.sampleRate / 10 { produced = due - AudioBlock.frames }
        while produced < due {
            let frames = min(due - produced, scratch.count / AudioBlock.channels)
            let chunkNanos = startNanos + UInt64(produced) * 1_000_000_000 / UInt64(AudioBlock.sampleRate)
            let blocks = scratch.withUnsafeMutableBufferPointer { buffer in
                synth.render(into: buffer, frames: frames)
                return repacketizer.append(interleaved: UnsafeBufferPointer(rebasing: buffer[0..<frames * AudioBlock.channels]),
                                           startNanos: chunkNanos)
            }
            produced += frames
            blocks.forEach(onBlock)
        }
    }
}
