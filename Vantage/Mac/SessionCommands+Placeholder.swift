#if os(macOS)
import VantageCore

// TEMPORARY: a copy of the contract `Vantage/Mac/SessionCommands.swift` defines, so the menu bar
// compiles before the session side lands. Delete this file when merging that one.

/// What the key session window offers the menu bar.
struct SessionCommands {
    let macName: String; var isConnected: Bool
    var capturesShortcuts: Bool; let toggleShortcutCapture: () -> Void
    var isViewOnly: Bool; let toggleViewOnly: () -> Void
    var macAudioOn: Bool; var macAudioAvailable: Bool; let toggleMacAudio: () -> Void
    var canSendFiles: Bool; let sendFile: () -> Void; let showTransfers: () -> Void
    let sendClipboard: () -> Void; let typePassword: () -> Void
    let sendShortcut: (MacShortcut) -> Void; let hostCommand: (HostCommand) -> Void; let wake: () -> Void
    var isDictating: Bool; let toggleDictation: () -> Void
    var controlsHidden: Bool; let toggleControls: () -> Void
    let actualSize: () -> Void; let toggleFullScreen: () -> Void
    let customizeControls: () -> Void; let disconnect: () -> Void
}
#endif
