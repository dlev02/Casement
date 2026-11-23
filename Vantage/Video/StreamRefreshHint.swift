#if !os(visionOS)
import Foundation
import QuartzCore

/// Keeps a ProMotion screen refreshing at the stream's rate while frames are arriving, so a
/// 120 fps picture is shown at 120 Hz: a sample-buffer layer on its own doesn't ask the panel
/// for more than the system thinks its content needs. Once frames stop for half a second it
/// asks for little, so a still remote screen lets the panel slow down and save battery.
///
/// The link holds this object until `stop`, which the view calls when it leaves its window.
final class StreamRefreshHint: NSObject {
    private let video: VideoStreamController
    private var link: CADisplayLink?
    private var isFast = false

    init(video: VideoStreamController) {
        self.video = video
    }

    /// Starts the hint with a link from `makeLink` (UIKit's `CADisplayLink(target:selector:)`,
    /// AppKit's `NSView.displayLink(target:selector:)`); does nothing on a 60 Hz screen.
    func start(makeLink: (Any, Selector) -> CADisplayLink) {
        stop()
        guard DisplayFrameRate.current() > 60 else { return }
        let link = makeLink(self, #selector(tick(_:)))
        link.preferredFrameRateRange = Self.slow
        isFast = false
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private static let slow = CAFrameRateRange(minimum: 10, maximum: 60, preferred: 30)

    @objc private func tick(_ link: CADisplayLink) {
        let idle = DispatchTime.now().uptimeNanoseconds &- video.lastFrameUptimeNanos
        let active = idle < 500_000_000
        guard active != isFast else { return }
        isFast = active
        let fps = Float(DisplayFrameRate.current())
        link.preferredFrameRateRange = active && fps > 60 ? CAFrameRateRange(minimum: 80, maximum: fps, preferred: fps) : Self.slow
    }
}
#endif
