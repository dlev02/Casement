import CoreVideo
import Foundation
import Synchronization
import Testing
import VantageCore
@testable import VantageHostSession

/// The video pacer on a fake encoder: the rules that decide whether the picture keeps moving.
struct VideoPacerTests {
    private let t0 = ContinuousClock.now

    /// Records what it was asked to encode; the test answers for it.
    private final class FakeEncoder: VideoEncoding, @unchecked Sendable {
        private let lock = NSLock()
        private var _encodes: [(forceKeyframe: Bool, ptsNanos: UInt64)] = []
        private var _bitrates: [Int] = []
        private var _frameRates: [Int] = []
        var encodes: [(forceKeyframe: Bool, ptsNanos: UInt64)] { lock.withLock { _encodes } }
        var bitrates: [Int] { lock.withLock { _bitrates } }
        var frameRates: [Int] { lock.withLock { _frameRates } }

        func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: UInt64, forceKeyframe: Bool) { lock.withLock { _encodes.append((forceKeyframe, ptsNanos)) } }
        func setBitrate(kbps: Int) { lock.withLock { _bitrates.append(kbps) } }
        func setExpectedFrameRate(_ fps: Int) { lock.withLock { _frameRates.append(fps) } }
    }

    private final class Wire: Sendable {
        private let messages = Mutex<[Message]>([])
        func append(_ message: Message) { messages.withLock { $0.append(message) } }
        var kinds: [MessageKind] { messages.withLock { $0.map(\.kind) } }
    }

    private static func pixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        return buffer!
    }

    private func frame(dirty: Double = 0.2, at nanos: UInt64 = 1) -> CapturedFrame {
        CapturedFrame(pixelBuffer: Self.pixelBuffer(), displayNanos: nanos, dirtyRatio: dirty)
    }

    private func encoded(sequence: UInt64, keyframe: Bool, config: Bool = false) -> VideoEncoder.Outcome {
        let frame = VideoFrame(sequence: sequence, captureNanos: 1, isKeyframe: keyframe, width: 16, height: 16, data: Data([0]))
        let config = config ? VideoConfig(codec: .h264, width: 16, height: 16, parameterSets: [Data([1])], nalLengthSize: 4, fps: 60) : nil
        return .encoded(VideoEncoder.Output(frame: frame, config: config))
    }

    private func pacer(_ encoder: FakeEncoder, _ wire: Wire, fps: Int = 60) -> VideoPacer {
        VideoPacer(encoder: encoder, adaptive: AdaptiveController(startBitrateKbps: 20_000), fps: fps) { wire.append($0) }
    }

    @Test func oneEncodeInFlightTheLatestFrameWinsAndConfigGoesOutBeforeTheIDR() {
        let encoder = FakeEncoder(), wire = Wire()
        var pacer = pacer(encoder, wire)
        _ = pacer.ingest(frame(at: 1), now: t0)
        #expect(encoder.encodes.map(\.forceKeyframe) == [true]) // the stream opens with an IDR
        // Two more frames while the first is in flight: only the newest waits.
        _ = pacer.ingest(frame(at: 2), now: t0)
        _ = pacer.ingest(frame(at: 3), now: t0)
        #expect(encoder.encodes.count == 1)
        pacer.encoderReported(encoded(sequence: 0, keyframe: true, config: true), now: t0)
        #expect(wire.kinds == [.videoConfig, .videoFrame])
        #expect(encoder.encodes.count == 2)
        #expect(encoder.encodes[1].forceKeyframe == false && encoder.encodes[1].ptsNanos == 3)
        #expect(pacer.framesSent == 1)
    }

    @Test func aDroppedFrameNeverFreezesThePictureAndForcesTheNextKeyframe() {
        let encoder = FakeEncoder(), wire = Wire()
        var pacer = pacer(encoder, wire)
        _ = pacer.ingest(frame(at: 1), now: t0)
        pacer.encoderReported(encoded(sequence: 0, keyframe: true), now: t0)
        _ = pacer.ingest(frame(at: 2), now: t0)
        // VideoToolbox dropped it: nothing went out, but the count came back down, the next frame
        // encodes at once rather than waiting as "pending" for ever, and it is an IDR.
        pacer.encoderReported(.dropped("frame dropped by the encoder"), now: t0)
        #expect(wire.kinds == [.videoFrame])
        _ = pacer.ingest(frame(at: 3), now: t0)
        #expect(encoder.encodes.count == 3)
        #expect(encoder.encodes[2].forceKeyframe == true)
    }

    @Test func anEncoderSilentForOverASecondIsWrittenOff() {
        let encoder = FakeEncoder(), wire = Wire()
        var pacer = pacer(encoder, wire)
        _ = pacer.ingest(frame(at: 1), now: t0)
        pacer.encoderReported(encoded(sequence: 0, keyframe: true), now: t0)
        _ = pacer.ingest(frame(at: 2), now: t0 + .milliseconds(100)) // in flight, and the encoder says nothing
        _ = pacer.ingest(frame(at: 3), now: t0 + .milliseconds(900))
        #expect(encoder.encodes.count == 2) // still waiting, within the limit
        _ = pacer.ingest(frame(at: 4), now: t0 + .milliseconds(1200))
        #expect(encoder.encodes.count == 3) // written off: this one goes straight in, as an IDR
        #expect(encoder.encodes[2].forceKeyframe == true)
    }

    @Test func aStillScreenIsNotEncodedButAKeyframeRequestReencodesItAtOnce() {
        let encoder = FakeEncoder(), wire = Wire()
        var pacer = pacer(encoder, wire)
        _ = pacer.ingest(frame(dirty: 0.3, at: 1), now: t0)
        pacer.encoderReported(encoded(sequence: 0, keyframe: true), now: t0)
        _ = pacer.ingest(frame(dirty: 0, at: 2), now: t0)
        _ = pacer.ingest(frame(dirty: 0, at: 3), now: t0)
        #expect(encoder.encodes.count == 1) // nothing changed, nothing sent
        pacer.requestKeyframe(now: t0 + .seconds(1))
        #expect(encoder.encodes.count == 2) // the last frame, now, as an IDR, not at the next change
        #expect(encoder.encodes[1].forceKeyframe == true && encoder.encodes[1].ptsNanos != 3)
        // Asked for while an encode is in flight, it goes out as soon as the encoder answers.
        pacer.requestKeyframe(now: t0 + .seconds(1))
        #expect(encoder.encodes.count == 2)
        pacer.encoderReported(encoded(sequence: 1, keyframe: true), now: t0 + .seconds(1))
        #expect(encoder.encodes.count == 3 && encoder.encodes[2].forceKeyframe == true)
    }

    @Test func frameRateAndBitrateReachTheEncoderOnlyWhenTheyChange() {
        let encoder = FakeEncoder(), wire = Wire()
        var pacer = pacer(encoder, wire, fps: 60)
        // Static-ish frames settle the controller into text mode (30 fps) once; the capture hears it once.
        var changes: [Int] = []
        for index in 0..<40 {
            if let fps = pacer.ingest(frame(dirty: 0.001, at: UInt64(index + 1)), now: t0 + .seconds(5)) { changes.append(fps) }
            pacer.encoderReported(encoded(sequence: UInt64(index), keyframe: index == 0), now: t0 + .seconds(5))
        }
        #expect(changes == [30])
        #expect(encoder.frameRates == [30])
        // Loss feedback lowers the bitrate once per report; a clean one soon after changes nothing.
        pacer.apply(feedback: QualityFeedback(rttMillis: 20, decodeMillis: 2, framesReceived: 100, framesDropped: 5, queueDepth: 0, bytesReceived: 1, windowSeconds: 1))
        #expect(encoder.bitrates == [14_000])
        pacer.apply(feedback: QualityFeedback(rttMillis: 20, decodeMillis: 2, framesReceived: 100, framesDropped: 0, queueDepth: 0, bytesReceived: 1, windowSeconds: 1))
        #expect(encoder.bitrates == [14_000])
        #expect(pacer.bitrateKbps == 14_000)
    }

    @Test func theStartingBitrateFollowsThePixelsAndTheRate() {
        #expect(VideoPacer.startingBitrateKbps(pixels: 2420 * 1668, fps: 60) == 19_375)
        #expect(VideoPacer.startingBitrateKbps(pixels: 640 * 480, fps: 30) == 4_000) // the floor
        #expect(VideoPacer.startingBitrateKbps(pixels: 5120 * 2880, fps: 60) == 60_000) // the ceiling
    }
}
