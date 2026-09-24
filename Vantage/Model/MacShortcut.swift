import VantageCore

/// A macOS keyboard shortcut Vantage can send as one tap. These are the system defaults; a Mac
/// with remapped shortcuts in System Settings → Keyboard will do whatever it was remapped to.
///
/// The arrow and function-key shortcuts carry Fn because that's how macOS stores them (Mission
/// Control is ⌃↑ with Fn, the way a real arrow key arrives); without it they match nothing.
/// Current hosts add Fn to those keys themselves; sending it here also covers older hosts.
/// ⌘Space opens whatever the Mac has on it: Spotlight, or a launcher like Raycast.
nonisolated struct MacShortcut: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let symbol: String
    let keyCode: UInt16
    let modifiers: KeyModifiers

    static let spotlight = MacShortcut(id: "spotlight", label: "Spotlight", symbol: "magnifyingglass",
                                       keyCode: 0x31, modifiers: .command)
    static let missionControl = MacShortcut(id: "missionControl", label: "Mission Control", symbol: "rectangle.3.group",
                                            keyCode: 0x7E, modifiers: [.control, .function])
    static let applicationWindows = MacShortcut(id: "appWindows", label: "Application Windows", symbol: "rectangle.on.rectangle",
                                                keyCode: 0x7D, modifiers: [.control, .function])
    static let showDesktop = MacShortcut(id: "showDesktop", label: "Show Desktop", symbol: "menubar.dock.rectangle",
                                         keyCode: 0x67, modifiers: .function)

    static let menuOrder: [MacShortcut] = [spotlight, missionControl, applicationWindows, showDesktop]
}
