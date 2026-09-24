#if os(macOS)
import SwiftUI
import VantageCore

/// What the focused session window offers the menu bar. `RemoteSessionScreen` publishes one with
/// `.focusedSceneValue(\.sessionCommands, …)` and the Session, View and Mac menus
/// (`MacCommands`, which declares the key) read it with `@FocusedValue(\.sessionCommands)`: nil
/// when no session window is focused, so their items show disabled rather than disappearing.
///
/// A scene value rather than a plain focused value: during a session an AppKit view
/// (`RemoteInteractionNSView`) holds the keyboard focus, which SwiftUI's view focus doesn't see.
struct SessionCommands {
    let macName: String
    var isConnected: Bool

    /// "Send Keyboard Shortcuts to Mac": ⌘Q, ⌘W and the rest go to the remote Mac.
    var capturesShortcuts: Bool
    let toggleShortcutCapture: () -> Void
    /// Watch without sending the pointer or keys.
    var isViewOnly: Bool
    let toggleViewOnly: () -> Void

    var macAudioOn: Bool
    var macAudioAvailable: Bool
    let toggleMacAudio: () -> Void

    var canSendFiles: Bool
    let sendFile: () -> Void
    let showTransfers: () -> Void
    let sendClipboard: () -> Void
    let typePassword: () -> Void

    /// Spotlight, Mission Control, App Windows, Show Desktop, App Switcher (`MacShortcut`).
    let sendShortcut: (MacShortcut) -> Void
    /// Sleep Display, Lock Mac.
    let hostCommand: (HostCommand) -> Void
    let wake: () -> Void

    var isDictating: Bool
    let toggleDictation: () -> Void

    /// The control strip is hidden.
    var controlsHidden: Bool
    let toggleControls: () -> Void
    /// Sizes the window so the Mac's screen shows point for point (as far as the screen allows).
    let actualSize: () -> Void
    let toggleFullScreen: () -> Void

    let customizeControls: () -> Void
    let disconnect: () -> Void
}
#endif
