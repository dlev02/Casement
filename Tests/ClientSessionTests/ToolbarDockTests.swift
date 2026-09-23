import CoreGraphics
import Testing
@testable import VantageClientLogic

/// An 11-inch iPad in landscape with the strip expanded (700 × 52) in a corner.
@MainActor struct ToolbarDockTests {
    let area = CGRect(x: 12, y: 44, width: 1186, height: 778)

    func placement(_ dock: ToolbarDock) -> ToolbarPlacement {
        let size = CGSize(width: 700, height: 52)
        let x = dock.isLeading ? area.minX : area.maxX - size.width
        let y = dock.isTop ? area.minY : area.maxY - size.height
        return ToolbarPlacement(area: area, frame: CGRect(origin: CGPoint(x: x, y: y), size: size))
    }

    @Test func sidewaysFlickThatDriftsDownStaysOnTop() {
        let corner = placement(.topLeft).corner(translation: CGSize(width: 250, height: 60),
                                                predicted: CGSize(width: 900, height: 300))
        #expect(corner == .topRight)
    }

    @Test func smallNudgeStaysInItsCorner() {
        #expect(placement(.bottomLeft).corner(translation: CGSize(width: 10, height: -10),
                                              predicted: CGSize(width: 20, height: -20)) == .bottomLeft)
    }

    @Test func diagonalThrowCrossesBothAxes() {
        #expect(placement(.bottomRight).corner(translation: CGSize(width: -150, height: -120),
                                               predicted: CGSize(width: -700, height: -600)) == .topLeft)
    }

    @Test func slowDragPastTheMiddleLandsWhereItWasLeft() {
        let move = CGSize(width: 400, height: -500)
        #expect(placement(.bottomLeft).corner(translation: move, predicted: move) == .topRight)
    }

    @Test func verticalFlickOnlyMovesVertically() {
        #expect(placement(.bottomRight).corner(translation: CGSize(width: -30, height: -100),
                                               predicted: CGSize(width: -120, height: -800)) == .topRight)
    }

    @Test func stripFollowsTheFingerAcrossTheWholeScreen() {
        let bottomLeft = placement(.bottomLeft)
        // The old limit was half the screen; the strip now reaches the far side.
        #expect(bottomLeft.constrained(CGSize(width: 480, height: -700)) == CGSize(width: 480, height: -700))
        // Past the edge it resists instead of stopping dead.
        let past = bottomLeft.constrained(CGSize(width: 900, height: 0)).width
        #expect(past > 486 && past < 486 + 120)
        #expect(bottomLeft.constrained(CGSize(width: 0, height: 200)).height < 60)
    }
}
