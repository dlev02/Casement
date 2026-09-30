import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// Captures the Mac's sound output with its own ScreenCaptureKit stream.
///
/// Separate from the video stream on purpose: `HostSession` rebuilds video capture on display
/// switches and viewport changes, and audio shouldn't drop out each time. Audio follows the
/// filter's applications, not its pixels, so a main-display filter hears every app. The video
/// half is a 2×2 picture once a second, received by a no-op `.screen` output (without one, SCK
/// logs "stream output NOT found" for every frame). Vantage Host's own sounds are excluded, and so
/// is the Vantage client when it runs on this Mac (connected to itself, its speakers would play
/// the Mac's sound back into the capture: an echo that feeds on itself). Rides on the Screen
/// Recording grant; there is no separate audio prompt.
nonisolated final class AudioCapture: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "audio")
    private let audioQueue = DispatchQueue(label: "vantage.audio.capture", qos: .userInteractive)
    private let screenQueue = DispatchQueue(label: "vantage.audio.capture.screen", qos: .utility)
    // Confined to `audioQueue` once started.
    private var repacketizer = AudioRepacketizer()
    private var onBlock: (@Sendable (AudioBlock) -> Void)?
    private var onStop: (@Sendable (String) -> Void)?
    private var loggedFormat = false
    private var stream: SCStream?

    /// The Vantage client app, left out of the capture if it runs here.
    static let clientBundleID = "com.benjaminlevinson.vantage"

    override init() {}

    func start(onBlock: @escaping @Sendable (AudioBlock) -> Void, onStop: @escaping @Sendable (String) -> Void) async throws {
        audioQueue.sync {
            self.onBlock = onBlock
            self.onStop = onStop
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CaptureError.displayNotFound
        }
        let client = content.applications.filter { $0.bundleIdentifier == Self.clientBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: client, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = AudioBlock.sampleRate
        config.channelCount = AudioBlock.channels
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("audio capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        audioQueue.sync {
            onBlock = nil
            onStop = nil
            repacketizer.reset()
        }
    }

    /// A user-facing explanation for a start failure or a stop.
    static func message(for error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, let code = SCStreamError.Code(rawValue: nsError.code) {
            switch code {
            case .failedToStartAudioCapture:
                return "The Mac couldn't start capturing its sound. Try again, or restart Porthole Host."
            case .userDeclined, .noCaptureSource:
                return "Porthole Host needs Screen Recording permission to send the Mac's sound."
            default:
                break
            }
        }
        return "The Mac stopped sending its sound (\(nsError.localizedDescription))."
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let onBlock else { return } // `.screen` is only there to keep SCK quiet
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32
        let isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        if !loggedFormat {
            loggedFormat = true
            log.info("audio capture format: \(Int(description.mSampleRate), privacy: .public) Hz, \(description.mChannelsPerFrame, privacy: .public) ch, \(isFloat ? "float" : "other", privacy: .public), \(isInterleaved ? "interleaved" : "planar", privacy: .public), \(sampleBuffer.numSamples, privacy: .public) frames per callback")
        }
        guard isFloat, Int(description.mSampleRate) == AudioBlock.sampleRate else { return }
        let pts = sampleBuffer.presentationTimeStamp
        let startNanos = pts.isValid ? UInt64(max(0, pts.convertScale(1_000_000_000, method: .default).value)) : MonotonicClock.nanos()
        var blocks: [AudioBlock] = []
        try? sampleBuffer.withAudioBufferList { list, _ in
            let frames = sampleBuffer.numSamples
            if isInterleaved, let buffer = list.first, let data = buffer.mData {
                let channels = Int(buffer.mNumberChannels)
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames * channels)
                if channels == 2 {
                    blocks = repacketizer.append(interleaved: samples, startNanos: startNanos)
                } else if channels == 1 {
                    blocks = repacketizer.append(planar: [samples], startNanos: startNanos)
                }
            } else {
                let planes = list.compactMap { buffer -> UnsafeBufferPointer<Float>? in
                    guard let data = buffer.mData else { return nil }
                    return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: frames)
                }
                blocks = repacketizer.append(planar: planes, startNanos: startNanos)
            }
        }
        blocks.forEach(onBlock)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("audio capture stopped: \(error.localizedDescription, privacy: .public)")
        let reason = Self.message(for: error)
        audioQueue.async { self.onStop?(reason) }
    }
}
