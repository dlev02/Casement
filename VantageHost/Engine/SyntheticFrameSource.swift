import CoreText
import CoreGraphics
import CoreVideo
import Foundation

/// Renders a desktop-like test pattern with a moving element and a live clock so the whole
/// encode → transport → decode → display path can be exercised without screen-recording access.
/// Enabled with the `--synthetic-capture` launch argument.
nonisolated final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    private var fps: Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "vantage.synthetic", qos: .userInteractive)
    private var pool: CVPixelBufferPool?
    private var tick = 0

    /// Streamed instead of the test pattern when set (`--synthetic-image`).
    private let picture: CGImage?

    init(pixelWidth: Int, pixelHeight: Int, fps: Int, picture: CGImage? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.picture = picture
    }

    func start(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) async throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: pixelWidth,
            kCVPixelBufferHeightKey: pixelHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        self.pool = pool
        scheduleTimer(onFrame: onFrame)
    }

    func updateFPS(_ fps: Int) {
        queue.async {
            guard fps != self.fps else { return }
            self.fps = fps
            self.timer?.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)))
        }
    }

    func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func scheduleTimer(onFrame: @escaping @Sendable (CapturedFrame) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(max(1, fps)))
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = self.render() else { return }
            onFrame(CapturedFrame(pixelBuffer: buffer, displayNanos: MonotonicClock.nanos(), dirtyRatio: 0.05))
        }
        timer.resume()
        self.timer = timer
    }

    private func render() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        tick += 1
        let w = CGFloat(pixelWidth), h = CGFloat(pixelHeight)
        if let picture {
            context.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buffer
        }

        // Wallpaper gradient.
        let colors = [CGColor(red: 0.10, green: 0.16, blue: 0.32, alpha: 1), CGColor(red: 0.45, green: 0.20, blue: 0.55, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        // Menu bar.
        context.setFillColor(CGColor(gray: 0.12, alpha: 0.85))
        context.fill(CGRect(x: 0, y: h - 48, width: w, height: 48))
        // A "window" with text-like lines to exercise sharpness.
        let window = CGRect(x: w * 0.12, y: h * 0.18, width: w * 0.62, height: h * 0.6)
        context.setFillColor(CGColor(gray: 0.97, alpha: 1))
        context.fill(window)
        context.setFillColor(CGColor(gray: 0.25, alpha: 1))
        var y = window.maxY - 60
        var row = 0
        while y > window.minY + 30 {
            let lineWidth = window.width * (0.35 + CGFloat((row * 37) % 50) / 100)
            context.fill(CGRect(x: window.minX + 32, y: y, width: lineWidth, height: 4))
            y -= 22; row += 1
        }
        // Moving element.
        let t = Double(tick) / Double(max(1, fps))
        let cx = w * 0.5 + CGFloat(sin(t * 1.3)) * w * 0.3
        let cy = h * 0.5 + CGFloat(cos(t * 0.9)) * h * 0.25
        context.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: cx - 40, y: cy - 40, width: 80, height: 80))
        // Clock text.
        let text = "VANTAGE SYNTHETIC \(String(format: "%.1f", t))s"
        // Draw with a frame-local Core Text line. AppKit's string drawing can share mutable
        // typography state across sessions and crashed when two synthetic clients rendered.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: CTFontCreateWithName("Menlo-Bold" as CFString, 36, nil),
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
        ]
        if let attributed = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attributes as CFDictionary) {
            context.textPosition = CGPoint(x: 40, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return buffer
    }
}
