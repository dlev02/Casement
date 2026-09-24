import Foundation
import VantageCore

/// The glide after a flick, for clients that end a scroll with the finger's velocity instead of a
/// momentum stream of their own (the iPad sends `ended` + momentum `began` + velocity in one
/// event; `UIPanGestureRecognizer` has no deceleration).
///
/// A Mac trackpad follows `ended` with momentum events: phase 0 and momentum began (1), continue
/// (2)…, end (3), with decaying deltas (docs/research/input.md A.4). Posting momentum `began` and
/// never `end`, as the host used to, left apps mid-momentum, and Safari (which doesn't invent its
/// own) stopped dead. This decays the velocity like `UIScrollView`'s normal deceleration (0.998
/// per millisecond), one frame every 1/60 s, in whole pixels with the fraction carried, and ends
/// with a zero-delta `end` once the speed drops under `stopSpeed` or after `maximumDuration`.
///
/// Deltas and velocity are in the client's units and sign; the injector applies the host's sign.
nonisolated struct ScrollMomentum: Sendable {
    struct Frame: Equatable, Sendable {
        var deltaX: Double
        var deltaY: Double
        var phase: MomentumPhase
    }

    static let frameInterval: Double = 1.0 / 60
    /// Velocity kept per millisecond (`UIScrollView.DecelerationRate.normal`).
    static let decelerationPerMillisecond: Double = 0.998
    /// Slower flicks just stop, like a trackpad let go without a flick.
    static let minimumSpeed: Double = 60
    /// Points per second under which the glide ends.
    static let stopSpeed: Double = 10
    static let maximumDuration: Double = 3

    private var velocity: (x: Double, y: Double)
    private var remainder = (x: 0.0, y: 0.0)
    private var elapsed = 0.0
    private var started = false
    private(set) var isFinished = false

    /// Nil when the flick is too slow to glide.
    init?(velocityX: Double, velocityY: Double) {
        guard (velocityX * velocityX + velocityY * velocityY).squareRoot() >= Self.minimumSpeed else { return nil }
        velocity = (velocityX, velocityY)
    }

    /// The next frame to post: `began` first, then `changed` (never with nothing in it), then one
    /// `ended`; nil after that.
    mutating func next() -> Frame? {
        guard !isFinished else { return nil }
        let decay = pow(Self.decelerationPerMillisecond, Self.frameInterval * 1000)
        while true {
            let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            if started && (speed < Self.stopSpeed || elapsed >= Self.maximumDuration) {
                return finish()
            }
            elapsed += Self.frameInterval
            let dx = take(velocity.x * Self.frameInterval, into: &remainder.x)
            let dy = take(velocity.y * Self.frameInterval, into: &remainder.y)
            velocity = (velocity.x * decay, velocity.y * decay)
            if !started {
                started = true
                return Frame(deltaX: dx, deltaY: dy, phase: .began)
            }
            if dx != 0 || dy != 0 { return Frame(deltaX: dx, deltaY: dy, phase: .changed) }
        }
    }

    /// Stops the glide early (the next scroll, a click): the `ended` frame if one is still owed.
    mutating func cancel() -> Frame? {
        guard started, !isFinished else {
            isFinished = true
            return nil
        }
        return finish()
    }

    private mutating func finish() -> Frame {
        isFinished = true
        return Frame(deltaX: 0, deltaY: 0, phase: .ended)
    }

    /// Adds `delta` to `remainder` and takes out the whole pixels.
    private func take(_ delta: Double, into remainder: inout Double) -> Double {
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole
    }
}
