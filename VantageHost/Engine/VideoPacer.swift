import CoreVideo
import Foundation
import VantageCore

/// What the pacer drives: `VideoEncoder` on a real or synthetic host, a recorder in tests.
nonisolated protocol VideoEncoding: AnyObject, Sendable {
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64, forceKeyframe: Bool)
    func setBitrate(kbps: Int)
    func setExpectedFrameRate(_ fps: Int)
}

extension VideoEncoder: VideoEncoding {}

/// From a captured frame to wire frames, for one stream: one encode in flight and the latest
/// frame wins, a static frame is skipped unless a keyframe is due, a keyframe request on a still
/// screen re-encodes the last frame at once (the protocol's rule, as the Windows host does), the
/// adaptive controller's frame rate and bitrate reach the encoder (and the capture, through the
/// caller) only when they change, `videoConfig` goes out before the IDR that needs it, and the
/// encoder's answer to every frame, encoded or dropped, keeps the in-flight count honest: a
/// drop forces the next keyframe, and an encode silent for over a second is written off.
///
/// Owned by `HostSession`, which hands it frames, keyframe requests, input and feedback, and
/// reports the encoder's outcomes back. Pure apart from the encoder it drives and the messages
/// it sends, so a fake encoder checks it.
nonisolated struct VideoPacer {
    /// A frame that changed no more of the screen than this is static.
    static let idleDirtyRatio = 0.0001
    /// Longer than this with no word from the encoder means the frame is lost, whatever it says later.
    static let encodeLimit: Duration = .seconds(1)

    private let encoder: any VideoEncoding
    private let send: @Sendable (Message) -> Void
    private(set) var adaptive: AdaptiveController
    /// The newest captured frame, kept so a keyframe can be made of a still screen.
    private var latest: CVPixelBuffer?
    private var latestPTSNanos: UInt64 = 0
    /// `latest` arrived while an encode was in flight and hasn't been encoded yet.
    private var pendingEncode = false
    private var encodesInFlight = 0
    private var encodeStartedAt: ContinuousClock.Instant?
    private var needsKeyframe = true
    private(set) var framesSent: UInt64 = 0
    /// The frame rate the encoder was last told; it and the capture hear only changes.
    private var currentFPS: Int

    init(encoder: any VideoEncoding, adaptive: AdaptiveController, fps: Int, send: @escaping @Sendable (Message) -> Void) {
        self.encoder = encoder
        self.adaptive = adaptive
        self.currentFPS = fps
        self.send = send
    }

    /// The bitrate a stream of this many pixels at this rate starts at: ~0.08 bits per pixel per
    /// frame for crisp screen content, between 4 and 60 Mbit/s.
    static func startingBitrateKbps(pixels: Int, fps: Int) -> Int {
        let bits = Double(pixels) * Double(fps) * 0.08
        return Int(min(60_000, max(4_000, bits / 1000)))
    }

    var bitrateKbps: Int { adaptive.bitrateKbps }

    /// Pointer, scroll or key input: the frame rate stays up for a moment.
    mutating func noteInput() {
        adaptive.noteInput()
    }

    /// A captured frame. Returns the capture frame rate to switch to, when it changed.
    mutating func ingest(_ frame: CapturedFrame, now: ContinuousClock.Instant) -> Int? {
        let (_, fps) = adaptive.observe(dirtyRatio: frame.dirtyRatio)
        var frameRateChange: Int?
        if fps != currentFPS {
            currentFPS = fps
            encoder.setExpectedFrameRate(fps)
            frameRateChange = fps
        }
        latest = frame.pixelBuffer
        latestPTSNanos = frame.displayNanos
        pendingEncode = false
        // Idle suppression: skip encoding a static frame (but always honour a pending keyframe).
        if frame.dirtyRatio <= Self.idleDirtyRatio, !needsKeyframe, framesSent > 0 { return frameRateChange }
        // The encoder answers every frame, encoded or dropped; this is the net under that promise.
        if encodesInFlight > 0, let encodeStartedAt, now - encodeStartedAt > Self.encodeLimit {
            encodesInFlight = 0
            needsKeyframe = true
        }
        guard encodesInFlight < 1 else {
            pendingEncode = true // the latest frame wins once the encoder answers
            return frameRateChange
        }
        encodeLatest(now: now, reencoding: false)
        return frameRateChange
    }

    /// The encoder's word on a frame it was given.
    mutating func encoderReported(_ outcome: VideoEncoder.Outcome, now: ContinuousClock.Instant) {
        encodesInFlight = max(0, encodesInFlight - 1)
        switch outcome {
        case .encoded(let output):
            if let config = output.config { send(.videoConfig(config)) }
            send(.videoFrame(output.frame))
            framesSent &+= 1
        case .dropped:
            // The client's decoder has a hole now; the next frame fills it.
            needsKeyframe = true
        }
        if pendingEncode || (needsKeyframe && latest != nil) { encodeLatest(now: now, reencoding: !pendingEncode) }
    }

    /// The client needs an IDR (it has no format description, its renderer failed, its viewport
    /// changed). A still screen sends no new frames, so the last one is re-encoded now.
    mutating func requestKeyframe(now: ContinuousClock.Instant) {
        needsKeyframe = true
        if encodesInFlight == 0, latest != nil { encodeLatest(now: now, reencoding: true) }
    }

    /// Client feedback; a bitrate change reaches the encoder.
    mutating func apply(feedback: QualityFeedback) {
        if let bitrate = adaptive.apply(feedback: feedback) { encoder.setBitrate(kbps: bitrate) }
    }

    /// Encodes the newest frame, forcing an IDR when one is due. A re-encode of the same frame
    /// takes a fresh timestamp, so the encoder never sees two frames at one instant.
    private mutating func encodeLatest(now: ContinuousClock.Instant, reencoding: Bool) {
        guard let latest, encodesInFlight == 0 else { return }
        pendingEncode = false
        let force = needsKeyframe
        needsKeyframe = false
        encodesInFlight += 1
        encodeStartedAt = now
        encoder.encode(latest, ptsNanos: reencoding ? MonotonicClock.nanos() : latestPTSNanos, forceKeyframe: force)
    }
}
