import CoreGraphics
import Foundation

enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .automatic: "Automatic"; case .light: "Light"; case .dark: "Dark" }
    }
}

enum ToolbarDock: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeading: Bool { self == .topLeft || self == .bottomLeft }
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        }
    }

    func moved(by translation: CGSize) -> Self {
        let top = abs(translation.height) > 50 ? translation.height < 0 : isTop
        let left = abs(translation.width) > 50 ? translation.width < 0 : isLeading
        return top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
    }
}
