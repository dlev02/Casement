import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VantageCore
import os

/// Captures a single display with ScreenCaptureKit and delivers `.complete` frames with a
/// dirty-area ratio so the pipeline can gate encoding and choose text/motion mode.
nonisolated final class ScreenCapture: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    typealias Frame = CapturedFrame

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "capture")
    private let sampleQueue = DispatchQueue(label: "vantage.capture", qos: .userInteractive)
    private var stream: SCStream?
    private let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    private var fps: Int
    private var onFrame: (@Sendable (Frame) -> Void)?
    private var onStop: (@Sendable ((any Error)?) -> Void)?
    /// Apps left out of the picture (the Vantage client when it runs on this Mac).
    private let excludedBundleIDs: [String]

    init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, fps: Int, excludingBundleIDs: [String] = []) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.excludedBundleIDs = excludingBundleIDs
    }

    static func preflightPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start(onFrame: @escaping @Sendable (Frame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) async throws {
        self.onFrame = onFrame
        self.onStop = onStop
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            log.error("display \(self.displayID) isn't shareable (listed: \(content.displays.map(\.displayID), privacy: .public))")
            throw CaptureError.displayNotFound
        }
        let excluded = content.applications.filter { excludedBundleIDs.contains($0.bundleIdentifier) }
        let filter = excluded.isEmpty
            ? SCContentFilter(display: display, excludingWindows: [])
            : SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = makeConfiguration()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        log.info("capture started for display \(self.displayID) at \(self.pixelWidth)x\(self.pixelHeight)@\(self.fps)")
    }

    func updateFPS(_ fps: Int) {
        self.fps = fps
        guard let stream else { return }
        let config = makeConfiguration()
        Task { try? await stream.updateConfiguration(config) }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // '420v'
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.preservesAspectRatio = true
        config.capturesAudio = false
        config.scalesToFit = false
        if #available(macOS 14.0, *) {
            config.capturesShadowsOnly = false
        }
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachment = attachments.first,
              let rawStatus = attachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        guard status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let displayNanos = (attachment[.displayTime] as? UInt64) ?? MonotonicClock.nanos()
        let dirtyRatio = Self.dirtyRatio(attachment, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        onFrame?(Frame(pixelBuffer: pixelBuffer, displayNanos: displayNanos, dirtyRatio: dirtyRatio))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("stream stopped: \(error.localizedDescription)")
        onStop?(error)
    }

    private static func dirtyRatio(_ attachment: [SCStreamFrameInfo: Any], pixelWidth: Int, pixelHeight: Int) -> Double {
        let total = Double(pixelWidth * pixelHeight)
        guard total > 0 else { return 1 }
        let rects = rects(attachment[.dirtyRects])
        guard !rects.isEmpty else { return 0 }
        let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        return min(1, area / total)
    }

    private static func rects(_ any: Any?) -> [CGRect] {
        guard let array = any as? [Any] else { return [] }
        return array.compactMap { element in
            if let value = element as? NSValue { return value.rectValue }
            if let dict = element as? NSDictionary { return CGRect(dictionaryRepresentation: dict) }
            return nil
        }
    }
}

enum CaptureError: Error {
    case displayNotFound
}
