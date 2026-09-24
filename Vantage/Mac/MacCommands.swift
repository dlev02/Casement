#if os(macOS)
import SwiftUI
import VantageCore

extension FocusedValues {
    /// The session in the key window; `RemoteSessionScreen` publishes it with `focusedSceneValue`.
    @Entry var sessionCommands: SessionCommands?
    /// The Mac selected in the device list window.
    @Entry var selectedMac: SavedDevice?
}

/// The menu bar. It follows the key window: the device list's selection, or the session in front.
/// Everything the toolbars and the session controls do is here too, with a shortcut where it's
/// used often. Session shortcuts hold ⌃⌥⌘, the one chord a session always leaves to Vantage, so
/// they work while every other shortcut goes to the Mac being controlled. Items that don't apply
/// right now are dimmed, never hidden.
struct MacCommands: Commands {
    @FocusedValue(\.sessionCommands) private var session
    @FocusedValue(\.selectedMac) private var selectedMac
    @Environment(\.openWindow) private var openWindow
    private let actions = DeviceActions.shared
    private let store = DeviceStore.shared

    /// ⌃⌥⌘: stays with Vantage even while shortcuts go to the Mac.
    static let vantageChord: EventModifiers = [.control, .option, .command]

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(replacing: .newItem) {
            Button("Add Mac…") { showDeviceList { actions.showAddDevice = true } }
                .keyboardShortcut("n")
            Button("Add from Tailscale…") { showDeviceList { actions.showTailscaleDevices = true } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(selectedMac.map { "Connect to \($0.name)" } ?? "Connect") {
                if let selectedMac { MacWindowRouter.shared.connect(to: selectedMac) }
            }
            .keyboardShortcut("o")
            .disabled(selectedMac == nil)
            Button("Send Files…") { if let selectedMac { actions.sendFiles(to: selectedMac) } }
                .disabled(selectedMac == nil)
        }

        CommandMenu("Session") { sessionMenu }

        CommandGroup(after: .toolbar) {
            Divider()
            Button(session?.controlsHidden == true ? "Show Controls" : "Hide Controls") { session?.toggleControls() }
                .keyboardShortcut("c", modifiers: Self.vantageChord)
                .disabled(session == nil)
            Button("Actual Size") { session?.actualSize() }
                .keyboardShortcut("0", modifiers: Self.vantageChord)
                .disabled(session == nil)
            Button("Full Screen") { session?.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: Self.vantageChord)
                .disabled(session == nil)
            Divider()
            Picker("Sort Macs By", selection: Binding(get: { store.sort }, set: { store.sort = $0 })) {
                ForEach(DeviceSort.allCases) { sort in Text(sort.label).tag(sort) }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Vantage Help") { openWindow(id: MacHelpWindow.sceneID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    @ViewBuilder private var sessionMenu: some View {
        let connected = session?.isConnected == true
        let canType = connected && session?.isViewOnly != true

        Toggle("Send Keyboard Shortcuts to Mac", isOn: toggle(\.capturesShortcuts) { $0.toggleShortcutCapture() })
            .keyboardShortcut("k", modifiers: Self.vantageChord)
            .disabled(session == nil)
        Toggle("View Only", isOn: toggle(\.isViewOnly) { $0.toggleViewOnly() })
            .disabled(session == nil)
        Divider()
        Toggle("Mac Audio", isOn: toggle(\.macAudioOn) { $0.toggleMacAudio() })
            .keyboardShortcut("a", modifiers: Self.vantageChord)
            .disabled(session?.macAudioAvailable != true)
        Button(session?.isDictating == true ? "Stop Dictating" : "Dictate") { session?.toggleDictation() }
            .keyboardShortcut("d", modifiers: Self.vantageChord)
            .disabled(!canType)
        Divider()
        Button("Send File…") { session?.sendFile() }
            .keyboardShortcut("u", modifiers: Self.vantageChord)
            .disabled(session?.canSendFiles != true)
        Button("Transfers…") { session?.showTransfers() }
            .keyboardShortcut("t", modifiers: Self.vantageChord)
            .disabled(session == nil)
        Button("Send Clipboard") { session?.sendClipboard() }
            .keyboardShortcut("v", modifiers: Self.vantageChord)
            .disabled(!canType)
        Button("Type Password") { session?.typePassword() }
            .keyboardShortcut("p", modifiers: Self.vantageChord)
            .disabled(!canType)
        Menu("Mac") {
            ForEach(MacShortcut.sessionMenu) { shortcut in
                Button(shortcut.label) { session?.sendShortcut(shortcut) }
            }
            .disabled(!canType)
            Divider()
            Button("Sleep Display") { session?.hostCommand(.sleepDisplay) }
                .disabled(!connected)
            Button("Lock Screen") { session?.hostCommand(.lockScreen) }
                .disabled(!connected)
            Button("Wake Display") { session?.wake() }
                .disabled(!connected)
        }
        .disabled(session == nil)
        Divider()
        Button("Customize Controls…") { session?.customizeControls() }
            .disabled(session == nil)
        Divider()
        Button("Disconnect") { session?.disconnect() }
            .keyboardShortcut("w", modifiers: Self.vantageChord)
            .disabled(session == nil)
    }

    /// A menu checkbox for one of the session's switches.
    private func toggle(_ value: KeyPath<SessionCommands, Bool>, _ flip: @escaping (SessionCommands) -> Void) -> Binding<Bool> {
        let session = session
        return Binding(get: { session?[keyPath: value] ?? false },
                       set: { _ in if let session { flip(session) } })
    }

    /// Brings the device list forward (it may be closed, or behind a session) before a sheet opens on it.
    private func showDeviceList(then present: () -> Void) {
        openWindow(id: MacRootView.sceneID)
        present()
    }
}
#endif
