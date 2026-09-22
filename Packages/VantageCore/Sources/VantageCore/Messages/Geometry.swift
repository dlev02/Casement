import CoreGraphics
import Foundation

/// Maps between a client's normalized viewport touch coordinates and a host display's
/// coordinate spaces. Kept in the shared core so host and client agree exactly.
public enum Geometry {
    /// Converts a normalized point (0...1, origin top-left) to display points on the host,
    /// given the streamed display's global frame (as reported by `SCDisplay.frame`, in points).
    public static func displayPoint(normalized u: Double, _ v: Double, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + u.clamped(0, 1) * frame.width,
                y: frame.minY + v.clamped(0, 1) * frame.height)
    }

    /// Converts a point expressed in the streamed display's local point space (origin top-left,
    /// 0...pointWidth) to the host's global display point space.
    public static func globalPoint(localX x: Double, _ y: Double, displayFrame frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + x, y: frame.minY + y)
    }

    /// The largest rect of `aspect` (w:h) that fits inside `bounds`, centered.
    public static func aspectFit(_ aspect: CGSize, in bounds: CGSize) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / aspect.width, bounds.height / aspect.height)
        let size = CGSize(width: aspect.width * scale, height: aspect.height * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
}

extension Comparable {
    public func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
