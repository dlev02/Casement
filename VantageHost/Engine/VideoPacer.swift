import CoreVideo
import Foundation
import VantageCore

/// What the pacer drives: `VideoEncoder` on a real or synthetic host (`HostEnvironment.makeVideoEncoder`),
/// a recorder or a wrapper that loses an answer in tests. Every encode carries the pacer's number
/// for it, and the encoder's answer carries it back.
nonisolated protocol VideoEncoding: AnyObject, Sendable {
    /// Starts the encoder; every `encode` is answered through `onOutcome` until `stop`.
    func start(onOutcome: @escaping @Sendable (VideoEncoder.Outcome) -> Void) throws
    func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64, forceKeyframe: Bool, encodeID: UInt64)
    func setBitrate(kbps: Int)
    /// The QP ceiling from the next frame on.
    func setMaxQP(_ maxQP: Int)
    func setExpectedFrameRate(_ fps: Int)
    func stop()
}

extension VideoEncoder: VideoEncoding {}

/// From a captured frame to wire frames, for one stream: up to `maxInFlight` encodes in flight
/// (two on a real host: Apple's encoder takes ~11 ms a frame, so one at a time tops out under
/// 100 fps, while two overlap to well over 120) and the latest frame wins, a static frame is skipped unless a keyframe is due, a keyframe request on a still
/// screen re-encodes the last frame at once (the protocol's rule, as the Windows host does), the
/// adaptive controller's frame rate and bitrate reach the encoder (and the capture, through the
/// caller) only when they change, `videoConfig` goes out before the first IDR and before any IDR
/// whose parameter sets differ from the ones the device was last sent (the encoder puts them on
/// every keyframe, so a written-off encode can't take the only copy), and the encoder's answer to
/// every frame, encoded or dropped, keeps the in-flight count honest: a drop forces the next
/// keyframe (a rate-control skip only re-sends the change), and an encode silent for over a
/// second is written off.
///
/// The mode's QP ceiling reaches the encoder before the frame it applies to. Once the screen has
/// been still for `sharpenDelay` after an encode, the last frame is encoded once more under the
/// quality's idle ceiling (`AdaptiveController.Limits.idleMaxQP`): motion leaves text soft at the
/// motion ceiling, and a still screen sends nothing else to fix it. Every other encode puts the
/// deadline back, so a screen that keeps changing never pays for it; the owner calls
/// `sharpenIfDue` at `sharpenDeadline`.
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
    /// How long the screen stays still after an encode before the sharper re-encode.
    static let sharpenDelay: Duration = .milliseconds(300)

    private let encoder: any VideoEncoding
    private let send: @Sendable (Message) -> Void
    private(set) var adaptive: AdaptiveController
    /// The newest captured frame, kept so a keyframe can be made of a still screen.
    private var latest: CVPixelBuffer?
    private var latestPTSNanos: UInt64 = 0
    /// A changed frame arrived while an encode was in flight and its change hasn't been encoded yet.
    private var pendingEncode = false
    private var lastEncodeID: UInt64 = 0
    /// The encodes awaiting the encoder's answer, oldest first (it answers in order): when each is
    /// written off if still unanswered, and whether it was a forced keyframe or the sharper
    /// re-encode of a still screen. A keyframe and a sharper re-encode only start with nothing
    /// else in flight; only ordinary changed frames overlap.
    private var inFlight: [(encodeID: UInt64, deadline: ContinuousClock.Instant, forced: Bool, sharpening: Bool)] = []
    /// How many encodes may overlap.
    let maxInFlight: Int
    /// An encode older than one still in flight was dropped or written off: the encodes after it
    /// may refer to a frame the device never got, so their pictures are discarded too, up to and
    /// including this id, and the keyframe that follows repairs the stream.
    private var discardThrough: UInt64 = 0
    /// The QP ceiling the encoder was last given (it starts with the adaptive controller's).
    private var encoderMaxQP: Int
    /// When the still screen gets its sharper re-encode; nil when it has had it or never will.
    private var sharpenAt: ContinuousClock.Instant?
    private var needsKeyframe = true
    /// The parameter sets in the last `videoConfig` sent: what the device's decoder is set up for.
    private var sentParameterSets: [Data]?
    private(set) var framesSent: UInt64 = 0
    /// The frame rate the encoder was last told; it and the capture hear only changes.
    private var currentFPS: Int

    init(encoder: any VideoEncoding, adaptive: AdaptiveController, fps: Int, maxInFlight: Int = 1,
         send: @escaping @Sendable (Message) -> Void) {
        self.encoder = encoder
        self.maxInFlight = max(1, maxInFlight)
        self.adaptive = adaptive
        self.currentFPS = fps
        self.encoderMaxQP = adaptive.maxQP
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
    var outstanding: (encodeID: UInt64, deadline: ContinuousClock.Instant)? { inFlight.first.map { ($0.encodeID, $0.deadline) } }

    /// When to call `sharpenIfDue`; nil while an encode is in flight (its answer takes over) or
    /// when nothing is owed.
    var sharpenDeadline: ContinuousClock.Instant? { inFlight.isEmpty ? sharpenAt : nil }

    /// Whether another encode may start now: always with nothing in flight; beside others only
    /// for an ordinary changed frame (no keyframe owed) while there's room.
    private var canStartEncode: Bool {
        inFlight.isEmpty || (inFlight.count < maxInFlight && !needsKeyframe)
    }

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
        guard canStartEncode else {
            pendingEncode = true // the latest frame wins once the encoder answers
            return frameRateChange
        }
        encodeLatest(now: now, reencoding: false)
        return frameRateChange
    }

    /// The encoder's word on a frame it was given. Only the encode in flight is listened to: an
    /// answer from one already written off is dropped, its accounting and picture alike.
    mutating func encoderReported(_ outcome: VideoEncoder.Outcome, now: ContinuousClock.Instant) {
        guard let index = inFlight.firstIndex(where: { $0.encodeID == outcome.encodeID }) else { return }
        // Answers come in order; any older one still listed never will, so it counts as dropped.
        if index > 0 { markLost(through: inFlight[index - 1].encodeID) }
        let finished = inFlight[index]
        inFlight.removeFirst(index + 1)
        var resend = false
        switch outcome {
        case .encoded where finished.encodeID <= discardThrough:
            // It may refer to a frame the device never got; the keyframe owed replaces it.
            needsKeyframe = true
        case .encoded(let output, _):
            if let config = output.config, config.parameterSets != sentParameterSets {
                send(.videoConfig(config))
                sentParameterSets = config.parameterSets
            }
            send(.videoFrame(output.frame))
            framesSent &+= 1
        case .skipped:
            // Rate control left it out; the device still has every frame the encoder refers to.
            // A keyframe asked for is still owed, and a change is sent again (the screen may stay
            // still now). A skipped sharper re-encode changed nothing the device lacks.
            if finished.forced { needsKeyframe = true }
            resend = !finished.sharpening
        case .dropped:
            // The client's decoder has a hole now; the next frame fills it.
            markLost(through: finished.encodeID)
        }
        if pendingEncode || resend || (needsKeyframe && latest != nil) {
            encodeLatest(now: now, reencoding: !pendingEncode)
        } else if inFlight.isEmpty, let sharpenAt, now >= sharpenAt {
            encodeLatest(now: now, reencoding: true, sharpening: true)
        }
    }

    /// `outstanding`'s deadline passed for that encode. When it is still the one in flight and its
    /// limit has really run out, it is written off and the latest frame re-encoded as a keyframe;
    /// a timeout for an encode that has since been answered or replaced does nothing.
    mutating func encodeTimedOut(_ encodeID: UInt64, now: ContinuousClock.Instant) {
        guard inFlight.first?.encodeID == encodeID else { return }
        guard writeOffIfStalled(now: now) else { return }
        if latest != nil { encodeLatest(now: now, reencoding: true) }
    }

    /// The client needs an IDR (it has no format description, its renderer failed, its viewport
    /// changed). A still screen sends no new frames, so the last one is re-encoded now.
    mutating func requestKeyframe(now: ContinuousClock.Instant) {
        needsKeyframe = true
        writeOffIfStalled(now: now)
        if inFlight.isEmpty, latest != nil { encodeLatest(now: now, reencoding: true) }
    }

    /// Client feedback, and whether video has been piling up unsent since the last; a bitrate
    /// change reaches the encoder.
    mutating func apply(feedback: QualityFeedback, backlogged: Bool = false) {
        if let bitrate = adaptive.apply(feedback: feedback, backlogged: backlogged) { encoder.setBitrate(kbps: bitrate) }
    }

    /// The device picked another quality: its limits apply from the next frame, and a still
    /// screen gets that quality's sharper re-encode. Returns the capture frame rate to switch to,
    /// when it changed.
    mutating func setQuality(_ preset: QualityPreset, now: ContinuousClock.Instant) -> Int? {
        if let bitrate = adaptive.setPreset(preset) { encoder.setBitrate(kbps: bitrate) }
        if adaptive.limits.idleMaxQP == nil {
            sharpenAt = nil
        } else if framesSent > 0 {
            sharpenAt = now + Self.sharpenDelay
        }
        let fps = adaptive.fps()
        guard fps != currentFPS else { return nil }
        currentFPS = fps
        encoder.setExpectedFrameRate(fps)
        return fps
    }

    /// `sharpenDeadline` came: with the screen still since, nothing waiting and no keyframe due,
    /// the last frame is encoded once more under the idle ceiling. A P-frame, so it only carries
    /// the detail the earlier frames left out. Returns the ceiling it used when it did.
    @discardableResult
    mutating func sharpenIfDue(now: ContinuousClock.Instant) -> Int? {
        guard let sharpenAt, now >= sharpenAt, inFlight.isEmpty else { return nil }
        guard latest != nil else {
            self.sharpenAt = nil
            return nil
        }
        // A change or a keyframe still owed goes first, as an ordinary encode (which sets the
        // deadline again), so a due deadline never sits waiting on something that isn't coming.
        encodeLatest(now: now, reencoding: !pendingEncode, sharpening: !pendingEncode && !needsKeyframe)
        return inFlight.last?.sharpening == true ? encoderMaxQP : nil
    }

    /// The encoder answers every frame, encoded or dropped; this is the net under that promise:
    /// an encode past its deadline is given up on, and the next frame is an IDR.
    @discardableResult
    private mutating func writeOffIfStalled(now: ContinuousClock.Instant) -> Bool {
        guard let oldest = inFlight.first, now >= oldest.deadline else { return false }
        // Everything behind it goes too: its answers would refer to the frame given up on.
        markLost(through: inFlight.last!.encodeID)
        inFlight.removeAll()
        return true
    }

    /// The device won't get the encode with this id (or an earlier one): a keyframe is owed, and
    /// every encode up to `id` that still answers has its picture discarded.
    private mutating func markLost(through id: UInt64) {
        needsKeyframe = true
        discardThrough = max(discardThrough, inFlight.last?.encodeID ?? id, id)
    }

    /// Encodes the newest frame, forcing an IDR when one is due, under the mode's QP ceiling (or
    /// the idle one for the sharper re-encode, which is never a keyframe). Every other encode
    /// sets the sharper re-encode's deadline back. A re-encode of the same frame takes a fresh
    /// timestamp, so the encoder never sees two frames at one instant.
    private mutating func encodeLatest(now: ContinuousClock.Instant, reencoding: Bool, sharpening: Bool = false) {
        guard let latest, canStartEncode, !sharpening || inFlight.isEmpty else { return }
        pendingEncode = false
        let force = needsKeyframe
        needsKeyframe = false
        let sharpens = sharpening && !force && adaptive.limits.idleMaxQP != nil
        let ceiling = sharpens ? adaptive.limits.idleMaxQP ?? adaptive.maxQP : adaptive.maxQP
        if ceiling != encoderMaxQP {
            encoder.setMaxQP(ceiling)
            encoderMaxQP = ceiling
        }
        sharpenAt = sharpens || adaptive.limits.idleMaxQP == nil ? nil : now + Self.sharpenDelay
        lastEncodeID &+= 1
        inFlight.append((lastEncodeID, now + Self.encodeLimit, force, sharpens))
        encoder.encode(latest, ptsNanos: reencoding ? MonotonicClock.nanos() : latestPTSNanos, forceKeyframe: force, encodeID: lastEncodeID)
    }
}
