import CoreGraphics
import Foundation

/// When a full-screen Mac session shows its own way out: the pointer resting against the very top
/// of the screen, nearly still, for a moment.
///
/// While a full-screen session captures the keyboard, the Mac's menu bar is hidden outright
/// (`KeyboardCapture`), so the pointer reaches the remote computer's menu bar, and AppKit, which
/// only brings a full-screen toolbar down with the menu bar, never shows the toolbar. Running the
/// pointer along the top edge to use the remote's menus, or to hit a maximised PC window's close
/// button, keeps moving, so it never counts; only a rest does. Once shown, the pill stays while
/// the pointer is within its reach of the top, and goes when the pointer moves further down.
///
/// Pure: times and positions in, shown or not out. `y` is measured down from the top of the
/// screen, in points.
nonisolated struct TopEdgeReveal: Equatable, Sendable {
    /// How long the pointer must rest at the top.
    static let dwell: TimeInterval = 0.5
    /// How close to the top counts as "at the top": the screen's own top row, near enough.
    static let edgeBand: CGFloat = 2
    /// How far the pointer may drift while resting and still count as still.
    static let stillRadius: CGFloat = 6
    /// Once shown, the pill stays while the pointer is this close to the top (it hangs about
    /// 12 pt down and is about 44 pt tall, so this covers it with a margin).
    static let reach: CGFloat = 84

    private(set) var isShown = false
    /// Where and when the current rest began, while the pointer is at the top and not shown yet.
    private var rest: (point: CGPoint, time: TimeInterval)?

    /// The pointer moved to `point` at `time`. Returns whether the pill shows.
    @discardableResult
    mutating func pointerMoved(to point: CGPoint, at time: TimeInterval) -> Bool {
        if isShown {
            if point.y > Self.reach { hide() }
            return isShown
        }
        guard point.y <= Self.edgeBand else {
            rest = nil
            return false
        }
        if let rest, hypot(point.x - rest.point.x, point.y - rest.point.y) <= Self.stillRadius {
            return check(at: time)
        }
        rest = (point, time) // moving along the edge starts the rest over
        return false
    }

    /// Time passed with no move (the caller checks once the dwell could have run out). Returns
    /// whether the pill shows.
    @discardableResult
    mutating func check(at time: TimeInterval) -> Bool {
        if !isShown, let rest, time - rest.time >= Self.dwell {
            isShown = true
            self.rest = nil
        }
        return isShown
    }

    /// When the pending rest would run out, if one is pending.
    var restEnds: TimeInterval? { rest.map { $0.time + Self.dwell } }

    /// Full screen ended, capture stopped, or the pointer left the window.
    mutating func hide() {
        isShown = false
        rest = nil
    }

    static func == (a: TopEdgeReveal, b: TopEdgeReveal) -> Bool {
        a.isShown == b.isShown && a.rest?.point == b.rest?.point && a.rest?.time == b.rest?.time
    }
}
