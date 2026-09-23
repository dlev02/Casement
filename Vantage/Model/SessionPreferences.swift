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

    func moved(by translation: CGSize) -> Self {
        let top = abs(translation.height) > 50 ? translation.height < 0 : isTop
        let left = abs(translation.width) > 50 ? translation.width < 0 : isLeading
        return top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
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
