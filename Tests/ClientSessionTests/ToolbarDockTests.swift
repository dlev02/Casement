import CoreGraphics
import Testing
@testable import VantageClientLogic

@MainActor struct ToolbarDockTests {
    @Test func swipesPreserveUnchangedAxisAndSupportAllCorners() {
        #expect(ToolbarDock.bottomLeft.moved(by: CGSize(width: 200, height: 0)) == .bottomRight)
        #expect(ToolbarDock.bottomRight.moved(by: CGSize(width: 0, height: -100)) == .topRight)
        #expect(ToolbarDock.topRight.moved(by: CGSize(width: -100, height: 120)) == .bottomLeft)
        #expect(ToolbarDock.bottomRight.moved(by: CGSize(width: -120, height: -120)) == .topLeft)
        #expect(ToolbarDock.topLeft.moved(by: CGSize(width: 10, height: 20)) == .topLeft)
    }
}
