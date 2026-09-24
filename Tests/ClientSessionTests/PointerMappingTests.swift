import CoreGraphics
import Testing
import VantageCore
@testable import VantageClientLogic

/// Absolute pointing (mouse, trackpad pointer, Pencil, Direct Touch): every edge of the Mac must be
/// reachable, because macOS only reveals a hidden Dock or menu bar, or fires a hot corner, on the
/// outermost row or column; everywhere else the mapping stays exact.
struct PointerMappingTests {
    /// Drew's setup: an 11-inch iPad Pro in landscape showing a Mac display of the same size.
    let sameSize = PointerMapping(displaySize: CGSize(width: 1210, height: 834), viewSize: CGSize(width: 1210, height: 834))

    @Test func sameSizeKeepsEveryInteriorPointExact() throws {
        for point in [CGPoint(x: 605, y: 417), CGPoint(x: 100.25, y: 200.5), CGPoint(x: 1205, y: 829)] {
            #expect(try #require(sameSize.displayPoint(forViewPoint: point)) == point)
        }
    }

    /// The iPad's pointer stops at the last point of the screen (and a Pencil short of it), which
    /// used to land a row or column inside the Mac's edge.
    @Test(arguments: [
        (CGPoint(x: 605, y: 833), CGPoint(x: 605, y: 833)),       // pointer at the bottom
        (CGPoint(x: 605, y: 832.2), CGPoint(x: 605, y: 833)),     // Pencil a little short
        (CGPoint(x: 605, y: 0.5), CGPoint(x: 605, y: 0)),         // menu bar
        (CGPoint(x: 1.5, y: 417), CGPoint(x: 0, y: 417)),         // Dock on the left
        (CGPoint(x: 1209, y: 417), CGPoint(x: 1209, y: 417)),     // Dock on the right
        (CGPoint(x: 1209, y: 833), CGPoint(x: 1209, y: 833)),     // bottom-right hot corner
        (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)),               // top-left hot corner
        (CGPoint(x: 605, y: 900), CGPoint(x: 605, y: 833)),       // past the view (a drag)
        (CGPoint(x: -40, y: -40), CGPoint(x: 0, y: 0)),
    ])
    func sameSizeReachesEveryEdge(view: CGPoint, mac: CGPoint) throws {
        #expect(try #require(sameSize.displayPoint(forViewPoint: view)) == mac)
    }

    /// iPadOS takes the pointer while it's pushed along the top or bottom edge, so a slide
    /// toward a hot corner often ends a little short; near a corner, an edge position finishes
    /// the trip. Off the edge, corners are ordinary.
    @Test(arguments: [
        (CGPoint(x: 1195, y: 833), CGPoint(x: 1209, y: 833)),     // bottom edge, 15 short of the corner
        (CGPoint(x: 10, y: 0.5), CGPoint(x: 0, y: 0)),            // top edge near the Apple menu corner
        (CGPoint(x: 1209, y: 12), CGPoint(x: 1209, y: 0)),        // right edge near the top
        (CGPoint(x: 1190, y: 833), CGPoint(x: 1190, y: 833)),     // 20 short: stays put
        (CGPoint(x: 1200, y: 820), CGPoint(x: 1200, y: 820)),     // near the corner but off the edges
    ])
    func edgePositionsNearACornerLandInIt(view: CGPoint, mac: CGPoint) throws {
        #expect(try #require(sameSize.displayPoint(forViewPoint: view)) == mac)
    }

    /// A 16:10 Mac on a 4:3-ish iPad: black bars above and below, and more Mac points than iPad
    /// points across, so the iPad's last column used to map to 1918.4 of 1920.
    @Test func widerMacLetterboxedTopAndBottom() throws {
        let mapping = PointerMapping(displaySize: CGSize(width: 1920, height: 1200), viewSize: CGSize(width: 1210, height: 834))
        let rect = mapping.videoRect
        #expect(rect.minX == 0 && rect.width == 1210)
        #expect(abs(rect.minY - 38.875) < 0.001)

        #expect(try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 1209, y: 417))).x == 1919)
        #expect(try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 605, y: 833))).y == 1199)  // in the bottom bar
        #expect(try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 605, y: 20))).y == 0)      // in the top bar
        #expect(try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 605, y: rect.maxY - 1))).y == 1199)
        let centre = try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 605, y: 417)))
        #expect(abs(centre.x - 960) < 0.001 && abs(centre.y - 600) < 0.001)
    }

    /// Turning the iPad to portrait moves the bars; every edge still lands on the Mac's edge and
    /// the middle stays the middle.
    @Test(arguments: [CGSize(width: 1376, height: 1032), CGSize(width: 1032, height: 1376)])
    func rotationKeepsEdgesAndCentre(viewSize: CGSize) throws {
        let mapping = PointerMapping(displaySize: CGSize(width: 1512, height: 982), viewSize: viewSize)
        let rect = mapping.videoRect
        let corners = [(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: 0, y: 0)),
                       (CGPoint(x: rect.maxX - 1, y: rect.minY + 1), CGPoint(x: 1511, y: 0)),
                       (CGPoint(x: rect.minX + 1, y: rect.maxY - 1), CGPoint(x: 0, y: 981)),
                       (CGPoint(x: viewSize.width - 1, y: viewSize.height - 1), CGPoint(x: 1511, y: 981))]
        for (view, mac) in corners {
            #expect(try #require(mapping.displayPoint(forViewPoint: view)) == mac)
        }
        let centre = try #require(mapping.displayPoint(forViewPoint: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)))
        #expect(abs(centre.x - 756) < 0.001 && abs(centre.y - 491) < 0.001)
    }

    /// A Mac display smaller than the iPad is scaled up: the edge snap is in iPad points, and
    /// nothing maps past the last row or column.
    @Test func smallerMacScaledUp() throws {
        let mapping = PointerMapping(displaySize: CGSize(width: 800, height: 600), viewSize: CGSize(width: 1376, height: 1032))
        #expect(mapping.videoRect == CGRect(x: 0, y: 0, width: 1376, height: 1032))
        #expect(try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 1375, y: 1031))) == CGPoint(x: 799, y: 599))
        // 1372 is 4 iPad points in, outside the snap: 1372 / 1376 × 800 = 797.67, still inside.
        let near = try #require(mapping.displayPoint(forViewPoint: CGPoint(x: 1372, y: 516)))
        #expect(abs(near.x - 797.674) < 0.01)
    }

    /// The snap only covers the outermost `edgeSnap` points; just past it the mapping is linear.
    @Test func snapStopsAtItsMargin() throws {
        let snap = PointerMapping.edgeSnap
        #expect(try #require(sameSize.displayPoint(forViewPoint: CGPoint(x: snap, y: 417))).x == 0)
        #expect(try #require(sameSize.displayPoint(forViewPoint: CGPoint(x: snap + 0.5, y: 417))).x == snap + 0.5)
        #expect(try #require(sameSize.displayPoint(forViewPoint: CGPoint(x: 1210 - snap - 0.5, y: 417))).x == 1210 - snap - 0.5)
    }

    @Test func nothingBeforeTheViewHasASize() {
        #expect(PointerMapping(displaySize: CGSize(width: 1210, height: 834), viewSize: .zero)
            .displayPoint(forViewPoint: CGPoint(x: 10, y: 10)) == nil)
    }

    /// The display size arrives after the view's first layout. The picture's rect used to be
    /// stored at layout time, so the mapping kept the default display's shape until the iPad rotated.
    @Test @MainActor func displaySizeArrivingAfterLayoutIsUsed() throws {
        let input = InputController()
        var sent: [PointerEvent] = []
        input.send = { if case .pointerEvent(let event) = $0 { sent.append(event) } }
        input.viewSize = CGSize(width: 1032, height: 1376)             // layout first (portrait)
        input.displayPointSize = CGSize(width: 1032, height: 1324)     // then the stream's display
        input.moveAbsolute(viewPoint: CGPoint(x: 516, y: 1375), action: .move)
        input.moveAbsolute(viewPoint: CGPoint(x: 516, y: 688), action: .move)
        #expect(sent.map(\.y) == [1323, 662])
    }
}
