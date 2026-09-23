import CoreGraphics
import Foundation

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .automatic: "Automatic"; case .light: "Light"; case .dark: "Dark" }
    }
}

/// How characters typed on the software keyboard reach the Mac.
enum SoftwareKeyboardMode: String, CaseIterable, Identifiable {
    /// Send the text itself. Layout-independent; supports accents, emoji, and dictation.
    case unicode
    /// Send real key presses using the Mac's US layout. Some apps, games, terminals, and
    /// virtual machines only respond to these, and they combine with ⌘/⌥/⌃ from the controls.
    case keystrokes
    var id: String { rawValue }
    var label: String { self == .unicode ? "Unicode Text" : "Keystrokes" }
}

enum ToolbarDock: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }
    var label: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
    var symbol: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        }
    }

    init(top: Bool, leading: Bool) {
        self = top ? (leading ? .topLeft : .topRight) : (leading ? .bottomLeft : .bottomRight)
    }
}

/// The geometry of dragging the control strip between corners: how far it may go while the
/// finger holds it, and which corner a release lands in.
struct ToolbarPlacement {
    /// Where the strip may sit, in the same space as `frame`.
    var area: CGRect
    /// The strip's resting frame in its current corner.
    var frame: CGRect

    /// The strip follows the finger anywhere inside the area, with a rubber-band past the edges
    /// instead of a hard stop.
    func constrained(_ translation: CGSize) -> CGSize {
        CGSize(width: Self.rubberBand(translation.width, min: area.minX - frame.minX, max: area.maxX - frame.maxX),
               height: Self.rubberBand(translation.height, min: area.minY - frame.minY, max: area.maxY - frame.maxY))
    }

    /// The corner whose quadrant the strip's centre is thrown into. A throw that runs mostly
    /// along one axis only moves along that axis, so a sideways flick that drifts a little
    /// down doesn't also swap top for bottom; the other axis goes by where the finger actually
    /// left the strip.
    func corner(translation: CGSize, predicted: CGSize) -> ToolbarDock {
        var projected = predicted
        let angle = atan2(abs(predicted.height), abs(predicted.width)) * 180 / .pi
        if angle < 25 { projected.height = translation.height }
        if angle > 65 { projected.width = translation.width }
        let centre = CGPoint(x: frame.midX + projected.width, y: frame.midY + projected.height)
        return ToolbarDock(top: centre.y < area.midY, leading: centre.x < area.midX)
    }

    /// iOS scroll-view style resistance: the further past the edge, the less it gives.
    static func rubberBand(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat, dimension: CGFloat = 120) -> CGFloat {
        guard lower <= upper else { return value }
        func resist(_ excess: CGFloat) -> CGFloat { (1 - 1 / (excess * 0.55 / dimension + 1)) * dimension }
        if value < lower { return lower - resist(lower - value) }
        if value > upper { return upper + resist(value - upper) }
        return value
    }
}

/// What an Apple Pencil squeeze or double-tap does during a session.
///
/// The Pencil is always an absolute pointer — it points at the thing you want — so these are the
/// actions you otherwise have to reach the control strip for.
enum PencilAction: String, CaseIterable, Identifiable, Sendable {
    case none
    case rightClick
    case middleClick
    case collapseControls
    case hideControls
    case showKeyboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Nothing"
        case .rightClick: "Secondary Click"
        case .middleClick: "Middle Click"
        case .collapseControls: "Collapse Controls"
        case .hideControls: "Hide Controls"
        case .showKeyboard: "Show Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .none: "nosign"
        case .rightClick: "contextualmenu.and.pointer.arrow"
        case .middleClick: "pointer.arrow.click"
        case .collapseControls: "rectangle.compress.vertical"
        case .hideControls: "eye.slash"
        case .showKeyboard: "keyboard"
        }
    }
}
