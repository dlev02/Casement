import CoreGraphics

/// Which way three fingers moved across the trackpad (Trackpad mode, or the lower half of an
/// iPhone Duo set up like a laptop). Each stands for the shortcut a Mac's own trackpad sends
/// (`HostShortcut.forSwipe`).
nonisolated enum TrackpadSwipe: Sendable {
    case left, right, up, down
}

/// Turns one three-finger drag into at most one swipe.
///
/// A swipe counts once the fingers have travelled `deadZone` along one axis while that axis leads
/// the other by `dominance`, so a three-finger tap that slides a little, or a drag that wanders
/// diagonally, sends nothing. Once it has fired, the rest of the drag is ignored: lifting and
/// swiping again moves one more Space.
nonisolated struct TrackpadSwipeTracker {
    static let deadZone: CGFloat = 60
    static let dominance: CGFloat = 1.6

    private var hasFired = false

    /// The swipe this drag has become, the first time it qualifies; nil before and after.
    mutating func swipe(for translation: CGSize) -> TrackpadSwipe? {
        guard !hasFired else { return nil }
        let across = abs(translation.width), along = abs(translation.height)
        if across >= Self.deadZone, across >= along * Self.dominance {
            hasFired = true
            return translation.width < 0 ? .left : .right
        }
        if along >= Self.deadZone, along >= across * Self.dominance {
            hasFired = true
            return translation.height < 0 ? .up : .down
        }
        return nil
    }
}
