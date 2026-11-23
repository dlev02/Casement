import CoreGraphics
import Testing
@testable import VantageClientLogic

@Suite struct TopEdgeRevealTests {
    /// Full screen's way out shows only after the pointer rests at the very top, nearly still,
    /// for the dwell; running along the edge (the remote's menu bar, a PC window's close button)
    /// never shows it, nor does resting just below the edge; once shown it stays within reach of
    /// the top and goes further down.
    @Test func showsOnlyAfterARestAtTheTop() {
        var along = TopEdgeReveal()
        var shownAlong = false
        for step in 0..<20 { // a step every 0.1 s along the top edge
            shownAlong = along.pointerMoved(to: CGPoint(x: 100 + CGFloat(step) * 30, y: 0), at: Double(step) * 0.1) || shownAlong
        }
        let shownAfterwards = along.check(at: 2.3) // under the dwell since the last step
        #expect(!shownAlong && !shownAfterwards)

        var rest = TopEdgeReveal()
        let start = rest.pointerMoved(to: CGPoint(x: 700, y: 0), at: 10)
        let trembled = rest.pointerMoved(to: CGPoint(x: 703, y: 1), at: 10.2) // inside the still radius
        let early = rest.check(at: 10.45)
        let shown = rest.check(at: 10.5)
        #expect(!start && !trembled && !early && shown)
        let onThePill = rest.pointerMoved(to: CGPoint(x: 720, y: 50), at: 11)
        let movedAway = rest.pointerMoved(to: CGPoint(x: 720, y: 200), at: 11.5)
        #expect(onThePill && !movedAway)

        var below = TopEdgeReveal()
        below.pointerMoved(to: CGPoint(x: 700, y: 5), at: 20)
        let shownBelow = below.check(at: 21)
        #expect(!shownBelow && below.restEnds == nil)
    }
}
