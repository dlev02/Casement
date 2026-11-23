import VantageCore

/// What a mouse's middle, back or forward button does in a session (Settings → Controls →
/// Mouse): its own click, or one of the host shortcuts, sent once when the button goes down.
///
/// Shortcuts are slots rather than chords, so each resolves for the computer at hand
/// (`HostShortcut.forItem`): Mission Control is Task View on a PC, and so on.
nonisolated enum MouseButtonAction: String, CaseIterable, Identifiable, Sendable {
    /// The button's own click (and drags with it held): middle click, back or forward.
    case click
    case missionControl
    case applicationWindows
    case showDesktop
    case appSwitcher
    /// The Windows key. A Mac has no Start, so there the button keeps its own click.
    case start

    var id: String { rawValue }

    /// The setting's name for `button`'s own click, or the shortcut's.
    func label(for button: PointerButton) -> String {
        switch self {
        case .click:
            switch button {
            case .back: "Back"
            case .forward: "Forward"
            default: "Middle Click"
            }
        case .missionControl: HostShortcut.missionControl.label
        case .applicationWindows: HostShortcut.applicationWindows.label
        case .showDesktop: HostShortcut.showDesktop.label
        case .appSwitcher: HostShortcut.appSwitcher.label
        case .start: HostShortcut.start.label
        }
    }

    func symbol(for button: PointerButton) -> String {
        switch self {
        case .click:
            switch button {
            case .back: "chevron.backward"
            case .forward: "chevron.forward"
            default: "computermouse"
            }
        case .missionControl: HostShortcut.missionControl.symbol
        case .applicationWindows: HostShortcut.applicationWindows.symbol
        case .showDesktop: HostShortcut.showDesktop.symbol
        case .appSwitcher: HostShortcut.appSwitcher.symbol
        case .start: HostShortcut.start.symbol
        }
    }

    /// The buttons a person can set: the ones the platform delivers to apps.
    static let remappableButtons: [PointerButton] = [.middle, .back, .forward]

    /// `vantage.mouseMiddleButton`, `vantage.mouseBackButton`, `vantage.mouseForwardButton`.
    static func defaultsKey(for button: PointerButton) -> String {
        switch button {
        case .back: "vantage.mouseBackButton"
        case .forward: "vantage.mouseForwardButton"
        default: "vantage.mouseMiddleButton"
        }
    }
}

/// What pressing a mouse button sends. Pure, so the table can be checked without a mouse.
nonisolated enum MouseButtonMapping {
    enum Press: Equatable, Sendable {
        /// The button itself: down now, up when it's let go.
        case button(PointerButton)
        /// A shortcut, tapped once on the press; the release sends nothing.
        case shortcut(HostShortcut)
    }

    static func press(_ button: PointerButton, action: MouseButtonAction, on platform: HostPlatform?) -> Press {
        // Left and right are never remapped: they're how anything gets clicked.
        guard MouseButtonAction.remappableButtons.contains(button) else { return .button(button) }
        let shortcut: HostShortcut? = switch action {
        case .click: nil
        case .missionControl: HostShortcut.forItem(.missionControl, on: platform)
        case .applicationWindows: HostShortcut.forItem(.applicationWindows, on: platform)
        case .showDesktop: HostShortcut.forItem(.showDesktop, on: platform)
        case .appSwitcher: platform == .windows ? HostShortcut.switchApps : HostShortcut.appSwitcher
        case .start: HostShortcut.forItem(.startMenu, on: platform)
        }
        return shortcut.map(Press.shortcut) ?? .button(button)
    }
}
