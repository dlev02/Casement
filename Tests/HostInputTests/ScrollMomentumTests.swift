import CoreGraphics
import Testing
import VantageCore
@testable import VantageHostInput

/// The glide the host posts after an iPad flick.
@Suite struct ScrollMomentumTests {
    private func glide(_ vx: Double, _ vy: Double) -> [ScrollMomentum.Frame] {
        guard var momentum = ScrollMomentum(velocityX: vx, velocityY: vy) else { return [] }
        var frames: [ScrollMomentum.Frame] = []
        while let frame = momentum.next() { frames.append(frame) }
        return frames
    }

    /// Began, then changes, then one end with nothing in it, like a trackpad's momentum.
    @Test func flickGlidesThenEnds() throws {
        let frames = glide(0, 1000)
        #expect(frames.first?.phase == .began)
        #expect(frames.last == ScrollMomentum.Frame(deltaX: 0, deltaY: 0, phase: .ended))
        #expect(frames.dropFirst().dropLast().allSatisfy { $0.phase == .changed && $0.deltaY != 0 })
        #expect(frames.allSatisfy { $0.deltaX == 0 && $0.deltaY >= 0 && $0.deltaY == $0.deltaY.rounded() })
        // UIScrollView's normal deceleration carries 1000 pt/s about 500 pt.
        let distance = frames.reduce(0) { $0 + $1.deltaY }
        #expect(distance > 450 && distance < 510, "glided \(distance)")
        #expect(Double(frames.count) * ScrollMomentum.frameInterval <= ScrollMomentum.maximumDuration + 0.05)
        // It slows down.
        let first = try #require(frames.first?.deltaY), middle = frames[frames.count / 2].deltaY
        #expect(first > middle)
    }

    @Test func glideKeepsTheFlicksDirection() {
        let frames = glide(-600, 300)
        #expect(frames.allSatisfy { $0.deltaX <= 0 && $0.deltaY >= 0 })
        let dx = frames.reduce(0) { $0 + $1.deltaX }, dy = frames.reduce(0) { $0 + $1.deltaY }
        #expect(abs(dx / dy + 2) < 0.1)
    }

    @Test func slowLiftDoesNotGlide() {
        #expect(ScrollMomentum(velocityX: 20, velocityY: 30) == nil)
        #expect(ScrollMomentum(velocityX: 0, velocityY: 0) == nil)
    }

    /// The next scroll or a click stops the glide with its end; cancelling twice sends nothing more.
    @Test func cancelEndsTheGlideOnce() throws {
        var momentum = try #require(ScrollMomentum(velocityX: 0, velocityY: 2000))
        #expect(momentum.next()?.phase == .began)
        #expect(momentum.cancel() == ScrollMomentum.Frame(deltaX: 0, deltaY: 0, phase: .ended))
        #expect(momentum.cancel() == nil)
        #expect(momentum.next() == nil)
    }
}
