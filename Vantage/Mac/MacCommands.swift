#if os(macOS)
import AppKit
import SwiftUI
import VantageCore

extension FocusedValues {
    /// The screen session in the key window; `RemoteSessionLayout` publishes its model with
    /// `focusedSceneValue`. A scene value rather than a plain focused value: during a session an
    /// AppKit view (`RemoteInteractionNSView`) holds the keyboard focus, which SwiftUI's view
    /// focus doesn't see. Nil when no session window is focused, so the menus' items show
    /// disabled rather than disappearing.
    @Entry var screenSession: ScreenSessionModel?
    /// That window's shape (Actual Size, Full Screen).
    @Entry var sessionWindowShape: SessionWindowShape?
    /// The Mac selected in the device list window.
    @Entry var selectedMac: SavedDevice?
}

/// The menu bar. It follows the key window: the device list's selection, or the session in front.
/// Everything the toolbars and the session controls do is here too, with a shortcut where it's
/// used often. Session shortcuts hold ⌃⌥⌘, the one chord a session always leaves to Vantage, so
/// they work while every other shortcut goes to the Mac being controlled. Items that don't apply
/// right now are dimmed, never hidden.
struct MacCommands: Commands {
    @FocusedValue(\.screenSession) private var session
    @FocusedValue(\.sessionWindowShape) private var windowShape
    @FocusedValue(\.selectedMac) private var selectedMac
    @Environment(\.openWindow) private var openWindow
    private let actions = DeviceActions.shared
    private let store = DeviceStore.shared

    /// ⌃⌥⌘: stays with Vantage even while shortcuts go to the Mac.
    static let vantageChord: EventModifiers = [.control, .option, .command]

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About Casement") { openWindow(id: MacAboutWindow.sceneID) }
        }

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

        CommandMenu("Session") { SessionMenuItems(session: session) }

        CommandGroup(after: .toolbar) {
            Divider()
            SessionViewItems(session: session, windowShape: windowShape)
            Divider()
            Picker("Sort Macs By", selection: Binding(get: { store.sort }, set: { store.sort = $0 })) {
                ForEach(DeviceSort.allCases) { sort in Text(sort.label).tag(sort) }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Casement Help") { openWindow(id: MacHelpWindow.sceneID) }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    /// Brings the device list forward (it may be closed, or behind a session) before a sheet opens on it.
    private func showDeviceList(then present: () -> Void) {
        openWindow(id: MacRootView.sceneID)
        present()
    }
}

/// The Session menu's items, reading the focused screen session (a view of its own, so the
/// items follow the model's state while the window stays focused).
private struct SessionMenuItems: View {
    let session: ScreenSessionModel?

    var body: some View {
        let connected = session?.isConnected == true
        let canType = connected && session?.isViewOnly != true

        Toggle("Send Keyboard Shortcuts to \(hostName)", isOn: toggle(\.capturesShortcuts) { $0.capturesShortcuts.toggle() })
            .keyboardShortcut("k", modifiers: MacCommands.vantageChord)
            .disabled(session == nil)
        Toggle("View Only", isOn: toggle(\.isViewOnly) { $0.isViewOnly.toggle() })
            .disabled(session == nil)
        Divider()
        Toggle("\(hostName) Audio", isOn: toggle(\.isMacAudioOn) { $0.toggleMacAudio() })
            .keyboardShortcut("a", modifiers: MacCommands.vantageChord)
            .disabled(session?.isMacAudioAvailable != true)
        Toggle("Curtain", isOn: toggle(\.isCurtainOn) { $0.toggleCurtain() })
            .keyboardShortcut("b", modifiers: MacCommands.vantageChord)
            .disabled(session?.isCurtainAvailable != true)
        Button(session?.dictation.isListening == true ? "Stop Dictating" : "Dictate") { session?.dictationPressed(.toggle) }
            .keyboardShortcut("d", modifiers: MacCommands.vantageChord)
            .disabled(!canType)
        Divider()
        Button("Send File…") { session?.isPickingFiles = true }
            .keyboardShortcut("u", modifiers: MacCommands.vantageChord)
            .disabled(session?.canSendFiles != true)
        Button("Transfers…") { session?.isShowingTransfers = true }
            .keyboardShortcut("t", modifiers: MacCommands.vantageChord)
            .disabled(session == nil)
        Button("Send Clipboard") { session?.sendClipboard() }
            .keyboardShortcut("v", modifiers: MacCommands.vantageChord)
            .disabled(!canType)
        Button("Type Password") { session?.typePassword() }
            .keyboardShortcut("p", modifiers: MacCommands.vantageChord)
            .disabled(!canType || session?.host.isWindows != false) // a PC has no saved password to type
        Menu(hostName) {
            ForEach(session.map { HostShortcut.sessionMenu(for: $0.hostPlatform) } ?? HostShortcut.sessionMenu) { shortcut in
                Button(shortcut.label) { session?.sendShortcut(shortcut) }
            }
            .disabled(!canType)
            Divider()
            Button("Sleep Display") { session?.sendHostCommand(.sleepDisplay) }
                .disabled(!connected)
            Button("Lock Screen") { session?.sendHostCommand(.lockScreen) }
                .disabled(!connected)
            Button("Wake Display") { session?.wakeDisplay() }
                .disabled(!connected)
        }
        .disabled(session == nil)
        Divider()
        Button("Customize Control Strip…") { session?.isEditingControls = true }
            .disabled(session == nil)
        Divider()
        Button("Disconnect") { session?.disconnect() }
            .keyboardShortcut("w", modifiers: MacCommands.vantageChord)
            .disabled(session == nil)
    }

    /// "Mac" or "PC" for the focused session (a Mac when there's none).
    private var hostName: String { (session?.host ?? .mac).name }

    /// A menu checkbox for one of the session's switches.
    private func toggle(_ value: KeyPath<ScreenSessionModel, Bool>, _ flip: @escaping (ScreenSessionModel) -> Void) -> Binding<Bool> {
        let session = session
        return Binding(get: { session?[keyPath: value] ?? false },
                       set: { _ in if let session { flip(session) } })
    }
}

/// The View menu's session items: the control strip, and the window's size.
private struct SessionViewItems: View {
    let session: ScreenSessionModel?
    let windowShape: SessionWindowShape?

    var body: some View {
        Button(session?.areControlsHidden == true ? "Show Control Strip" : "Hide Control Strip") {
            withAnimation(.smooth(duration: 0.3)) { session?.areControlsHidden.toggle() }
        }
        .keyboardShortcut("c", modifiers: MacCommands.vantageChord)
        .disabled(session == nil)
        Button("Actual Size") { windowShape?.actualSize() }
            .keyboardShortcut("0", modifiers: MacCommands.vantageChord)
            .disabled(windowShape == nil)
        // In place of AppKit's own item (see `VantageApp.init`), so there's one, and its
        // ⌃⌥⌘F still works while a session sends ⌃⌘F to the Mac.
        Button(windowShape?.isFullScreen == true ? "Exit Full Screen" : "Enter Full Screen") {
            if let windowShape { windowShape.toggleFullScreen() } else { NSApp.keyWindow?.toggleFullScreen(nil) }
        }
        .keyboardShortcut("f", modifiers: MacCommands.vantageChord)
    }
}
#endif
