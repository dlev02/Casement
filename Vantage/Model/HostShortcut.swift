import VantageCore

/// A keyboard shortcut Vantage can send to the host as one tap: the system defaults for the
/// host's platform. A computer with remapped shortcuts will do whatever it was remapped to.
///
/// **Mac**: the arrow and function-key shortcuts carry Fn because that's how macOS stores them
/// (Mission Control is ⌃↑ with Fn, the way a real arrow key arrives); without it they match
/// nothing. Current hosts add Fn to those keys themselves; sending it here also covers older
/// hosts. ⌘Space opens whatever the Mac has on it: Spotlight, or a launcher like Raycast.
///
/// **PC**: the same controls stand for Windows' nearest equivalents (Search, Task View, Switch
/// Apps, Show Desktop), plus Start and Task Manager, which a Mac has no use for. Key codes are
/// macOS virtual key codes, the wire's format; the Windows host maps ⌘ to the Windows key, ⌥ to
/// Alt and ⌃ to Ctrl literally. Shortcuts always go out as written here, never through the
/// "⌘ acts as Ctrl" swap (`KeyRemap`), which is for the keyboard.
nonisolated struct HostShortcut: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let symbol: String
    let keyCode: UInt16
    let modifiers: KeyModifiers
    /// What it sends, for the controls editor ("⌃ ↑", "Win Tab").
    let chord: String

    // MARK: Mac

    static let spotlight = HostShortcut(id: "spotlight", label: "Spotlight", symbol: "magnifyingglass",
                                        keyCode: 0x31, modifiers: .command, chord: "⌘ Space")
    static let missionControl = HostShortcut(id: "missionControl", label: "Mission Control", symbol: "rectangle.3.group",
                                             keyCode: 0x7E, modifiers: [.control, .function], chord: "⌃ ↑")
    static let applicationWindows = HostShortcut(id: "appWindows", label: "Application Windows", symbol: "rectangle.on.rectangle",
                                                 keyCode: 0x7D, modifiers: [.control, .function], chord: "⌃ ↓")
    static let showDesktop = HostShortcut(id: "showDesktop", label: "Show Desktop", symbol: "menubar.dock.rectangle",
                                          keyCode: 0x67, modifiers: .function, chord: "F11")

    /// ⌘Tab tapped: back to the app used before. The Mac client offers it because its own ⌘Tab
    /// never reaches a session (macOS keeps it), unless a full-screen session is capturing keys.
    static let appSwitcher = HostShortcut(id: "appSwitcher", label: "App Switcher", symbol: "square.stack",
                                          keyCode: 0x30, modifiers: .command, chord: "⌘ Tab")

    static let menuOrder: [HostShortcut] = [spotlight, missionControl, applicationWindows, showDesktop]

    // MARK: PC

    /// The Windows key on its own (⌘ down and up, no chord).
    static let start = HostShortcut(id: "start", label: "Start", symbol: "square.grid.2x2",
                                    keyCode: 0x37, modifiers: [], chord: "Windows key")
    static let search = HostShortcut(id: "spotlight", label: "Search", symbol: "magnifyingglass",
                                     keyCode: 0x01, modifiers: .command, chord: "Win S")
    static let taskView = HostShortcut(id: "missionControl", label: "Task View", symbol: "rectangle.3.group",
                                       keyCode: 0x30, modifiers: .command, chord: "Win Tab")
    static let switchApps = HostShortcut(id: "appWindows", label: "Switch Apps", symbol: "rectangle.on.rectangle",
                                         keyCode: 0x30, modifiers: .option, chord: "Alt Tab")
    static let pcShowDesktop = HostShortcut(id: "showDesktop", label: "Show Desktop", symbol: "menubar.dock.rectangle",
                                            keyCode: 0x02, modifiers: .command, chord: "Win D")
    static let taskManager = HostShortcut(id: "taskManager", label: "Task Manager", symbol: "chart.xyaxis.line",
                                          keyCode: 0x35, modifiers: [.control, .shift], chord: "Ctrl Shift Esc")

    static let pcMenuOrder: [HostShortcut] = [start, search, taskView, switchApps, pcShowDesktop, taskManager]

    // MARK: Lookup

    /// The shortcut a strip control sends to this host; nil for controls that aren't shortcuts,
    /// and for Start and Task Manager on a Mac.
    static func forItem(_ item: StripItem, on platform: HostPlatform?) -> HostShortcut? {
        let pc = platform == .windows
        switch item {
        case .spotlight: return pc ? search : spotlight
        case .missionControl: return pc ? taskView : missionControl
        case .applicationWindows: return pc ? switchApps : applicationWindows
        case .showDesktop: return pc ? pcShowDesktop : showDesktop
        case .startMenu: return pc ? start : nil
        case .taskManager: return pc ? taskManager : nil
        default: return nil
        }
    }

    /// The session menu's shortcuts for a host. The Mac client adds the App Switcher for a Mac
    /// (a PC's Switch Apps is already there).
    static func sessionMenu(for platform: HostPlatform?) -> [HostShortcut] {
        if platform == .windows { return pcMenuOrder }
        #if os(macOS)
        return menuOrder + [appSwitcher]
        #else
        return menuOrder
        #endif
    }

    /// The session menu's shortcuts for a Mac.
    static var sessionMenu: [HostShortcut] { sessionMenu(for: .macOS) }
}

/// The name the Mac-only code and tests have always used.
typealias MacShortcut = HostShortcut
