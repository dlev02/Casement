import CoreVideo
import Foundation

/// One captured frame handed to the encoder.
nonisolated struct CapturedFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer
    var displayNanos: UInt64
    /// Fraction of the frame area that changed since the previous frame (0...1).
    var dirtyRatio: Double
}

/// A source of display frames for the encoder. Implemented by ScreenCaptureKit capture (normal
/// operation) and a synthetic test pattern (headless end-to-end testing without
/// screen-recording permission).
nonisolated protocol FrameSource: AnyObject, Sendable {
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }

    func start(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) async throws
    func updateFPS(_ fps: Int)
    /// The windows to leave out of the picture changed (the curtain came or went).
    func refreshFilter() async
    func stop() async
}

enum CaptureError: Error {
    /// Nothing to capture: the display is gone, or asleep (ScreenCaptureKit then lists none).
    case displayNotFound
    /// The stream reported itself stopped before `start` returned.
    case stoppedWhileStarting
}
