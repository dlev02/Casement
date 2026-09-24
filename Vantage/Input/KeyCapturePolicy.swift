import VantageCore

/// Which keys a Mac session window keeps for Vantage and which it sends to the remote Mac.
///
/// With "Send keyboard shortcuts to the Mac" on (the default), everything goes to the remote Mac,
/// ⌘Q and ⌘W included, except chords holding all of ⌃⌥⌘: that's how you talk to Vantage itself
/// (its menu shortcuts use it). With the setting off, the shortcuts that act on this Mac's app and
/// windows stay here too: quit, close, hide, minimize, settings, next window, full screen.
///
/// Keys macOS keeps before any app sees them (⌘Tab, ⌘Space, Mission Control, screenshots, media
/// keys) never reach the policy; full-screen sessions turn ⌘Tab off while capturing.
///
/// Decided on the keys as pressed here, before "Swap ⌘ and ⌃".
nonisolated enum KeyCapturePolicy {
    enum Route: Equatable, Sendable {
        /// Leave the key to Vantage (menus, window management).
        case local
        /// Send it to the remote Mac.
        case forward
    }

    /// Hold all three and the key is Vantage's, whatever the setting.
    static let vantageChord: KeyModifiers = [.control, .option, .command]

    /// What stays on this Mac while shortcuts aren't sent: (key code, exact modifiers).
    static let localShortcuts: [(keyCode: UInt16, modifiers: KeyModifiers)] = [
        (0x0C, .command),                 // ⌘Q quit
        (0x0D, .command),                 // ⌘W close window
        (0x04, .command),                 // ⌘H hide
        (0x04, [.option, .command]),      // ⌥⌘H hide others
        (0x2E, .command),                 // ⌘M minimize
        (0x2B, .command),                 // ⌘, settings
        (0x32, .command),                 // ⌘` next window
        (0x32, [.shift, .command]),       // ⇧⌘` previous window
        (0x03, [.control, .command]),     // ⌃⌘F full screen
    ]

    /// Where a key press goes. `modifiers` are the keys held here (Caps Lock and Fn don't count).
    static func route(keyCode: UInt16, modifiers: KeyModifiers, capturesShortcuts: Bool) -> Route {
        let chord = modifiers.intersection([.shift, .control, .option, .command])
        if chord.isSuperset(of: vantageChord) { return .local }
        if capturesShortcuts { return .forward }
        return localShortcuts.contains { $0.keyCode == keyCode && $0.modifiers == chord } ? .local : .forward
    }
}
