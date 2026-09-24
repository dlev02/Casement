import VantageCore

/// Turns this Mac's scroll events (an `NSEvent`'s scrolling deltas, precision and phases, as raw
/// values) into the wire's scroll events, so the remote Mac scrolls exactly as this one would.
///
/// **Sign.** The host posts continuous deltas negated and line deltas as they come
/// (`InputInjector.injectScroll`, the iPad's convention). So continuous deltas go over as
/// `-scrollingDelta` and lines as `+scrollingDelta`, and the event the host posts carries the
/// same values as the one this Mac delivered, already turned around for this Mac's natural
/// scrolling setting. The remote Mac's own setting doesn't apply to posted events.
///
/// **Trackpad and Magic Mouse** (precise deltas): gesture and momentum phases pass straight
/// through (the host posts them as they are, momentum included, so nothing is synthesized for a
/// Mac client). `NSEventPhase` bits are not the wire's values (docs/research/input.md A.4):
/// may-begin and stationary have no wire value and are dropped, as is an end or cancel for a
/// gesture that never began (fingers rested and lifted).
///
/// **Wheels** (line deltas): whole lines only, with the fraction carried to the next notch so a
/// slow or accelerated wheel adds up the same; a change of direction starts from zero.
nonisolated struct ScrollTranslator: Sendable {
    /// One local scroll event, from `NSEvent`.
    struct Input: Equatable, Sendable {
        var deltaX: Double
        var deltaY: Double
        /// `hasPreciseScrollingDeltas`: points from a trackpad or Magic Mouse, else wheel lines.
        var isPrecise: Bool
        /// `NSEvent.phase.rawValue`.
        var phase: UInt = 0
        /// `NSEvent.momentumPhase.rawValue`.
        var momentumPhase: UInt = 0
    }

    /// One wire scroll event.
    struct Output: Equatable, Sendable {
        var deltaX: Double
        var deltaY: Double
        var phase: ScrollPhase
        var momentum: MomentumPhase
        var isContinuous: Bool
    }

    // `NSEvent.Phase` bits.
    static let phaseBegan: UInt = 0x1
    static let phaseStationary: UInt = 0x2
    static let phaseChanged: UInt = 0x4
    static let phaseEnded: UInt = 0x8
    static let phaseCancelled: UInt = 0x10
    static let phaseMayBegin: UInt = 0x20

    private var gestureActive = false
    private var momentumActive = false
    private var lineRemainder = (x: 0.0, y: 0.0)

    mutating func translate(_ input: Input) -> Output? {
        input.isPrecise ? continuous(input) : lines(input)
    }

    private mutating func continuous(_ input: Input) -> Output? {
        var output = Output(deltaX: -input.deltaX, deltaY: -input.deltaY, phase: .none, momentum: .none, isContinuous: true)
        if input.phase != 0 {
            switch input.phase {
            case Self.phaseBegan:
                gestureActive = true
                momentumActive = false
                output.phase = .began
            case Self.phaseChanged:
                guard gestureActive else { return nil }
                output.phase = .changed
            case Self.phaseEnded, Self.phaseCancelled:
                guard gestureActive else { return nil }
                gestureActive = false
                output.phase = input.phase == Self.phaseEnded ? .ended : .cancelled
            default:
                return nil // may-begin, stationary
            }
        } else if input.momentumPhase != 0 {
            switch input.momentumPhase {
            case Self.phaseBegan:
                momentumActive = true
                output.momentum = .began
            case Self.phaseChanged:
                guard momentumActive else { return nil }
                output.momentum = .changed
            case Self.phaseEnded, Self.phaseCancelled:
                guard momentumActive else { return nil }
                momentumActive = false
                output.momentum = .ended
            default:
                return nil
            }
        } else if input.deltaX == 0 && input.deltaY == 0 {
            return nil // a phaseless event with nothing in it
        }
        return output
    }

    private mutating func lines(_ input: Input) -> Output? {
        let x = carry(input.deltaX, into: &lineRemainder.x)
        let y = carry(input.deltaY, into: &lineRemainder.y)
        guard x != 0 || y != 0 else { return nil }
        return Output(deltaX: x, deltaY: y, phase: .none, momentum: .none, isContinuous: false)
    }

    /// Adds `delta` to `remainder` and takes out the whole lines.
    private func carry(_ delta: Double, into remainder: inout Double) -> Double {
        guard delta != 0 else { return 0 }
        if remainder != 0, (remainder < 0) != (delta < 0) { remainder = 0 }
        remainder += delta
        let whole = remainder.rounded(.towardZero)
        remainder -= whole
        return whole
    }
}
