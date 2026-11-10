import CoreVideo
import Foundation
import VantageCore

/// What the pacer drives: `VideoEncoder` on a real or synthetic host, a recorder in tests. Every
/// encode carries the pacer's number for it, and the encoder's answer carries it back.
nonisolated protocol VideoEncoding: AnyObject, Sendable {
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64, forceKeyframe: Bool, encodeID: UInt64)
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
/// Every encode gets a number, and the encoder's answer carries it back, so an answer from an
/// encode already written off is recognised and dropped: it never frees the slot of the encode
/// that replaced it, and its stale picture never goes out. The write-off doesn't wait for the
/// next changed frame: `outstanding` names the encode in flight and its deadline, the owner
/// calls `encodeTimedOut` then, and a timeout queued behind the answer that finished its encode
/// finds a newer encode (or none) in flight and does nothing. A changed frame waiting behind an
/// encode keeps waiting through unchanged frames that follow it: they refresh the picture that
/// will be encoded, not the need to encode it.
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
    /// A changed frame arrived while an encode was in flight and its change hasn't been encoded yet.
    private var pendingEncode = false
    private var lastEncodeID: UInt64 = 0
    /// The encode awaiting the encoder's answer, and when it is written off if still unanswered.
    private var inFlight: (encodeID: UInt64, deadline: ContinuousClock.Instant)?
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

    /// The encode in flight and the moment to call `encodeTimedOut` for it; nil when the encoder
    /// owes nothing.
    var outstanding: (encodeID: UInt64, deadline: ContinuousClock.Instant)? { inFlight }

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
        // The safety net comes first: a still screen must not hide a stalled encode.
        writeOffIfStalled(now: now)
        // Idle suppression: skip encoding a static frame (but always honour a pending keyframe).
        // A change still waiting behind an encode stays pending; this frame only refreshes the picture.
        if frame.dirtyRatio <= Self.idleDirtyRatio, !needsKeyframe, framesSent > 0 { return frameRateChange }
        guard inFlight == nil else {
            pendingEncode = true // the latest frame wins once the encoder answers
            return frameRateChange
        }
        encodeLatest(now: now, reencoding: false)
        return frameRateChange
    }

    /// The encoder's word on a frame it was given. Only the encode in flight is listened to: an
    /// answer from one already written off is dropped, its accounting and picture alike.
    mutating func encoderReported(_ outcome: VideoEncoder.Outcome, now: ContinuousClock.Instant) {
        guard inFlight?.encodeID == outcome.encodeID else { return }
        inFlight = nil
        switch outcome {
        case .encoded(let output, _):
            if let config = output.config { send(.videoConfig(config)) }
            send(.videoFrame(output.frame))
            framesSent &+= 1
        case .dropped:
            // The client's decoder has a hole now; the next frame fills it.
            needsKeyframe = true
        }
        if pendingEncode || (needsKeyframe && latest != nil) { encodeLatest(now: now, reencoding: !pendingEncode) }
    }

    /// `outstanding`'s deadline passed for that encode. When it is still the one in flight and its
    /// limit has really run out, it is written off and the latest frame re-encoded as a keyframe;
    /// a timeout for an encode that has since been answered or replaced does nothing.
    mutating func encodeTimedOut(_ encodeID: UInt64, now: ContinuousClock.Instant) {
        guard inFlight?.encodeID == encodeID else { return }
        guard writeOffIfStalled(now: now) else { return }
        if latest != nil { encodeLatest(now: now, reencoding: true) }
    }

    /// The client needs an IDR (it has no format description, its renderer failed, its viewport
    /// changed). A still screen sends no new frames, so the last one is re-encoded now.
    mutating func requestKeyframe(now: ContinuousClock.Instant) {
        needsKeyframe = true
        writeOffIfStalled(now: now)
        if inFlight == nil, latest != nil { encodeLatest(now: now, reencoding: true) }
    }

    /// Client feedback; a bitrate change reaches the encoder.
    mutating func apply(feedback: QualityFeedback) {
        if let bitrate = adaptive.apply(feedback: feedback) { encoder.setBitrate(kbps: bitrate) }
    }

    /// The encoder answers every frame, encoded or dropped; this is the net under that promise:
    /// an encode past its deadline is given up on, and the next frame is an IDR.
    @discardableResult
    private mutating func writeOffIfStalled(now: ContinuousClock.Instant) -> Bool {
        guard let inFlight, now >= inFlight.deadline else { return false }
        self.inFlight = nil
        needsKeyframe = true
        return true
    }

    /// Encodes the newest frame, forcing an IDR when one is due. A re-encode of the same frame
    /// takes a fresh timestamp, so the encoder never sees two frames at one instant.
    private mutating func encodeLatest(now: ContinuousClock.Instant, reencoding: Bool) {
        guard let latest, inFlight == nil else { return }
        pendingEncode = false
        let force = needsKeyframe
        needsKeyframe = false
        lastEncodeID &+= 1
        inFlight = (lastEncodeID, now + Self.encodeLimit)
        encoder.encode(latest, ptsNanos: reencoding ? MonotonicClock.nanos() : latestPTSNanos, forceKeyframe: force, encodeID: lastEncodeID)
    }
}
