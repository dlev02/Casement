import CoreGraphics
import VantageCore

/// Where a point in the session view lands on the Mac, for everything that points absolutely: a
/// mouse or trackpad pointer, the Pencil, and fingers in Direct Touch.
///
/// The Mac's picture is aspect-fit in the view, so it may be letterboxed. Anything past the
/// picture's edge lands on the Mac's edge, and so does anything within `edgeSnap` of it: the
/// iPad's pointer stops a point short of the screen's edge, and macOS only reveals a hidden Dock
/// or menu bar, or fires a hot corner, on the outermost row or column. Without the snap the
/// scaled position stopped a row or two short.
nonisolated struct PointerMapping: Equatable, Sendable {
    /// The Mac display, in points.
    var displaySize: CGSize
    /// The session view the picture is fitted into, in points.
    var viewSize: CGSize

    /// View points from the picture's edge within which a position counts as on the edge.
    static let edgeSnap: CGFloat = 2
    /// Along an edge, view points from a corner within which a position counts as in the corner.
    /// A hot corner is a single point, and iPadOS takes the pointer when it's pushed along the
    /// top or bottom edge, so a slide along the edge often stops just short of the corner.
    static let cornerSnap: CGFloat = 16

    /// Where the picture is drawn in the view.
    var videoRect: CGRect { Geometry.aspectFit(displaySize, in: viewSize) }

    /// The Mac display point for `viewPoint`, or nil before the view has a size.
    func displayPoint(forViewPoint viewPoint: CGPoint) -> CGPoint? {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0, displaySize.width > 0, displaySize.height > 0 else { return nil }
        let dx = viewPoint.x - rect.minX, dy = viewPoint.y - rect.minY
        let onSide = dx <= Self.edgeSnap || dx >= rect.width - Self.edgeSnap
        let onTopOrBottom = dy <= Self.edgeSnap || dy >= rect.height - Self.edgeSnap
        return CGPoint(x: Self.map(dx, across: rect.width, onto: displaySize.width,
                                   snap: onTopOrBottom ? Self.cornerSnap : Self.edgeSnap),
                       y: Self.map(dy, across: rect.height, onto: displaySize.height,
                                   snap: onSide ? Self.cornerSnap : Self.edgeSnap))
    }

    /// View points per display point: how much the picture is scaled to fit the view.
    var pictureScale: CGFloat {
        guard displaySize.width > 0 else { return 1 }
        return videoRect.width / displaySize.width
    }

    /// Where a display point is drawn in the view (the inverse of `displayPoint`, without the
    /// edge snapping), for the pointer this device draws itself.
    func viewPoint(forDisplayPoint point: CGPoint) -> CGPoint {
        let rect = videoRect, scale = pictureScale
        return CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
    }

    /// One axis: `offset` into a picture `length` view points long, onto a display `extent`
    /// points long whose last row or column starts at `extent - 1`.
    private static func map(_ offset: CGFloat, across length: CGFloat, onto extent: CGFloat, snap: CGFloat) -> CGFloat {
        let last = max(0, extent - 1)
        if offset <= snap { return 0 }
        if offset >= length - snap { return last }
        return min(max(offset / length * extent, 0), last)
    }
}
