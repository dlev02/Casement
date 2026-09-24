#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VantageCore

/// The Mac's main window: saved Macs in a sidebar, the selected one's details and actions beside
/// it. Each Mac connects in a window of its own (`SessionWindow`), so this list stays put while
/// sessions come and go. There is only ever one of these (`Window`, not `WindowGroup`), so ⌘N can
/// mean Add Mac… rather than a second copy of the list.
struct MacRootView: View {
    static let sceneID = "main"

    @Environment(DeviceStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MacSpotlight.appLockKey) private var requireBiometrics = false
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true
    @SceneStorage("vantage.mac.selection") private var selectionID: String?
    @State private var availability = HostAvailabilityStore()
    private let actions = DeviceActions.shared
    private let transfers = FileTransferCenter.shared
    #if DEBUG
    @State private var debugScreen: DebugScreen?
    #endif

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
        .focusedSceneValue(\.selectedMac, selectedDevice)
        .deviceActionPresentations(actions)
        .task {
            // Runs before the window root's onAppear hands the router its openWindow.
            MacWindowRouter.shared.attach(openWindow)
            if let host = ClientOptions.takeAutoConnectHost(), let device = store.devices.first(where: { $0.host == host }) {
                selectionID = device.id.uuidString
                MacWindowRouter.shared.connect(to: device)
            }
            #if DEBUG
            if ClientOptions.autoConnectHost == nil, let bytes = ClientOptions.takeSendTestFileBytes(),
               let device = store.devices.first {
                transfers.link(for: device).files.queueTestFile(bytes: bytes)
            }
            if ClientOptions.openScreen == .settings {
                openSettings()
            } else {
                debugScreen = ClientOptions.openScreen
            }
            #endif
            if ClientOptions.openTailscaleDevices { actions.showTailscaleDevices = true }
            if selectedDevice == nil { selectionID = store.sortedDevices.first?.id.uuidString }
        }
        .task(id: availabilityKey) {
            guard availabilityKey != "paused" else { return }
            await availability.monitor(store.devices)
        }
        .onChange(of: requireBiometrics) { _, _ in store.refreshSpotlight() }
        #if DEBUG
        .sheet(item: $debugScreen) { screen in
            NavigationStack { DebugScreenView(screen: screen) }
                .frame(minWidth: 480, minHeight: 520)
                .macGroupedForm()
        }
        #endif
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selection) {
            ForEach(store.sortedDevices) { device in
                MacSidebarRow(device: device, availability: status(of: device),
                              files: transfers.files(for: device.id),
                              onShowTransfers: { actions.transfersDevice = device })
                    .tag(device.id)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let device = device(ids.first) {
                Button("Connect") { MacWindowRouter.shared.connect(to: device) }
                Divider()
                DeviceMenu(device: device, actions: actions)
            }
        } primaryAction: { ids in
            // Double-click or Return.
            if let device = device(ids.first) { MacWindowRouter.shared.connect(to: device) }
        }
        .overlay {
            if !store.devices.isEmpty && store.sortedDevices.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TailscaleBanner().padding(.bottom, 10)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    DeviceSortPicker()
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort the list")
            }
            ToolbarItem {
                AddDeviceMenu(actions: actions)
                    .help("Add a Mac")
            }
        }
        .accessibilityIdentifier("devices.sidebar")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if store.devices.isEmpty {
            DeviceListEmptyState(actions: actions)
        } else if let device = selectedDevice {
            MacDeviceDetail(device: device, availability: status(of: device),
                            files: transfers.files(for: device.id), actions: actions)
                .id(device.id)
        } else {
            ContentUnavailableView("Select a Mac", systemImage: "macbook",
                                   description: Text("Choose a Mac in the sidebar to connect to it, send it files, or change its settings."))
        }
    }

    // MARK: State

    private var selection: Binding<UUID?> {
        Binding(get: { selectionID.flatMap(UUID.init(uuidString:)) },
                set: { selectionID = $0?.uuidString })
    }

    private var selectedDevice: SavedDevice? { device(selection.wrappedValue) }

    private func device(_ id: UUID?) -> SavedDevice? {
        id.flatMap { id in store.devices.first { $0.id == id } }
    }

    /// Checks run while the device list is open and they're on (Settings › Connection).
    private var availabilityKey: String {
        guard availabilityChecks else { return "paused" }
        return store.devices.map { "\($0.id):\($0.host):\($0.port)" }.joined(separator: "|")
    }

    /// Nothing at all while checks are off, rather than a "Checking…" that never ends.
    private func status(of device: SavedDevice) -> HostAvailability? {
        availabilityChecks ? availability.statuses[device.id] ?? .checking : nil
    }
}

/// A Mac in the sidebar: its name, whether it's reachable, and the files moving with it. Files
/// dropped on it go to that Mac without opening its screen.
private struct MacSidebarRow: View {
    let device: SavedDevice
    let availability: HostAvailability?
    let files: FileTransferController?
    let onShowTransfers: () -> Void
    @State private var isDropTargeted = false

    var body: some View {
        // A Label, so the sidebar tints the symbol like Finder's and turns it white on a selected
        // row, where the tinted tile would vanish into the accent fill.
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                if isDropTargeted {
                    Label("Drop to send", systemImage: StripItem.sendFile.symbol)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Drop to send to \(device.name)")
                } else if let files, files.hasActiveTransfers {
                    DeviceTransferBadge(files: files, macName: device.name, onOpen: onShowTransfers)
                } else if let availability {
                    AvailabilityLabel(status: availability)
                }
            }
        } icon: {
            Image(systemName: osSymbol(device.os))
        }
        .padding(.vertical, 3)
        .animation(.easeOut(duration: isDropTargeted ? 0.2 : 0.15), value: isDropTargeted)
        .onDrop(of: [.item], delegate: FileDropDelegate(isEnabled: true, isTargeted: $isDropTargeted,
                                                        files: { FileTransferCenter.shared.link(for: device).files }))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("devices.row.\(device.host)")
    }
}

/// The selected Mac: Connect front and centre, then what else you can do with it, then what
/// Vantage remembers about it.
private struct MacDeviceDetail: View {
    let device: SavedDevice
    let availability: HostAvailability?
    let files: FileTransferController?
    let actions: DeviceActions
    @Environment(DeviceStore.self) private var store

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                LabeledContent("Address", value: address)
                    .textSelection(.enabled)
                LabeledContent("Last Connected", value: device.lastConnected.map(lastConnectedText) ?? "Never")
                if device.connectionCount > 0 {
                    LabeledContent("Connections", value: device.connectionCount.formatted())
                }
            } header: {
                Text("Connection")
            }

            Section {
                Toggle("Play Mac Audio", isOn: Binding(get: { device.playMacAudio ?? false },
                                                      set: { store.setPlayMacAudio($0, for: device.id) }))
                LabeledContent("Video", value: (device.preferredCodec ?? .hevc) == .hevc ? "HEVC" : "H.264")
                LabeledContent("Virtual Display", value: device.useVirtualDisplay == true ? "On" : "Off")
                LabeledContent("Controls", value: device.controlStrip == nil ? "Default" : "Custom")
                LabeledContent("Mac Sign-In", value: DeviceSecrets.password(for: device) == nil ? "Not Saved" : "Saved")
            } header: {
                Text("Session")
            } footer: {
                Text("Play Mac Audio brings \(device.name)'s sound to this Mac while you're connected. Change the rest with Edit.")
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                DeviceIconTile(os: device.os, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(1)
                    Text(device.host)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let availability { AvailabilityLabel(status: availability) }
                }
            }
            HStack(spacing: 10) {
                Button {
                    MacWindowRouter.shared.connect(to: device)
                } label: {
                    Label("Connect", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("devices.connect")

                Button { actions.sendFiles(to: device) } label: {
                    Label("Send Files…", systemImage: StripItem.sendFile.symbol)
                }
                if files?.hasTransfers == true {
                    Button { actions.transfersDevice = device } label: {
                        Label("Transfers", systemImage: "arrow.up.arrow.down")
                    }
                }
                Button { actions.editingDevice = device } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                if ScreenSharingPassword.canLogIn(device) {
                    Button { actions.deviceToLogIn = device } label: {
                        Label("Log In with Screen Sharing", systemImage: "key")
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .labelStyle(.titleAndIcon)
            if let files, files.hasActiveTransfers {
                DeviceTransferBadge(files: files, macName: device.name) { actions.transfersDevice = device }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var address: String {
        device.port == VantageProtocol.defaultPort ? device.host : "\(device.host):\(device.port)"
    }
}

// MARK: - Windows

/// Opens session windows from anywhere: the list, the menu bar, and requests from Siri,
/// Shortcuts, Spotlight, or a `vantage://` link, which wait until Vantage is unlocked. Holds
/// on to an `openWindow` from the first window that appeared, so a request still opens its
/// session when no window is open to watch for it.
@MainActor
final class MacWindowRouter {
    static let shared = MacWindowRouter()
    private var openWindow: OpenWindowAction?
    /// Session windows open right now; files opened in Vantage go straight to a Mac without one.
    private(set) var openSessions = 0

    func attach(_ action: OpenWindowAction) {
        openWindow = action
    }

    func connect(to device: SavedDevice) {
        openWindow?(id: SessionWindow.sceneID, value: device.id)
    }

    func showDeviceList() {
        openWindow?(id: MacRootView.sceneID)
    }

    /// The Mac Siri, Shortcuts, Spotlight, or a link asked for, once Vantage is unlocked. A Mac
    /// that no longer exists is dropped rather than left to fire later.
    func openPendingConnection() {
        let pending = PendingConnection.shared
        guard let id = pending.requestedMacID, !AppLock.shared.isLocked, let openWindow else { return }
        pending.requestedMacID = nil
        guard DeviceStore.shared.devices.contains(where: { $0.id == id }) else { return }
        openWindow(id: SessionWindow.sceneID, value: id)
    }

    /// A file opened in Vantage from Finder or another app goes to an open session (the session
    /// takes it from the inbox), or else straight to the Mac used most recently without opening
    /// its screen. A Mac too old for that is opened instead. Waits for Touch ID like any request.
    func sendSharedFiles() {
        let inbox = SharedFileInbox.shared
        guard !inbox.pending.isEmpty, !AppLock.shared.isLocked, openSessions == 0 else { return }
        let store = DeviceStore.shared
        guard let device = store.devices.max(by: { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }) else { return }
        let link = FileTransferCenter.shared.link(for: device)
        guard link.canSendWithoutScreen else {
            connect(to: device)
            return
        }
        for copy in inbox.take() { link.files.sendOutboxCopy(copy) }
    }

    func sessionWindowOpened() { openSessions += 1 }
    func sessionWindowClosed() { openSessions = max(0, openSessions - 1) }
}

extension View {
    /// What every Mac window's root needs: the shared store and Tailscale state, the lock over
    /// the window, the chosen appearance, and a watch on pending connections and opened files.
    func macWindowRoot() -> some View {
        modifier(MacWindowRoot())
    }
}

private struct MacWindowRoot: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    private let pending = PendingConnection.shared
    private let lock = AppLock.shared

    func body(content: Content) -> some View {
        content
            .appLockCurtain()
            .environment(DeviceStore.shared)
            .environment(MacApp.reachability)
            .environment(MacApp.tailscaleAccount)
            .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
            .onAppear {
                MacWindowRouter.shared.attach(openWindow)
                lock.authenticate()
            }
            // `initial: true` catches a request that arrived before this window existed.
            .onChange(of: pending.requestedMacID, initial: true) { _, _ in MacWindowRouter.shared.openPendingConnection() }
            .onChange(of: lock.isLocked) { _, locked in
                guard !locked else { return }
                MacWindowRouter.shared.openPendingConnection()
                MacWindowRouter.shared.sendSharedFiles()
            }
            .onOpenURL { url in
                if url.isFileURL {
                    SharedFileInbox.shared.accept(url)
                    MacWindowRouter.shared.sendSharedFiles()
                } else if let id = DeviceCatalog.macID(from: url) {
                    pending.requestedMacID = id
                }
            }
    }
}

/// App-wide state the Mac's windows share. Settings and each session are scenes of their own,
/// so they can't inherit it from the device list the way iOS screens do.
@MainActor
enum MacApp {
    static let reachability: TailscaleReachability = {
        let reachability = TailscaleReachability()
        reachability.start()
        return reachability
    }()
    static let tailscaleAccount = TailscaleAccount()
}

/// Vantage Help in a window of its own (Help › Vantage Help, ⌘?).
struct MacHelpWindow: View {
    static let sceneID = "help"

    var body: some View {
        NavigationStack { HelpScreen() }
            .frame(minWidth: 460, idealWidth: 560, minHeight: 420, idealHeight: 640)
            .macWindowRoot()
    }
}

/// App-level behaviour SwiftUI has no scene modifier for.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the device list shouldn't quit Vantage: sessions live in their own windows, and
    /// files keep moving with a Mac after its window closes. Quit with ⌘Q (from the device list;
    /// a session sends ⌘Q to the Mac it controls) or the Dock.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with every window closed brings the device list back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MacWindowRouter.shared.showDeviceList() }
        return true
    }

    /// Keeps idle sleep and App Nap away from files and sessions in flight.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MacTransferActivity.shared.start()
    }

    /// Siri and Shortcuts bring Vantage forward with a Mac to open, even with no window open to
    /// notice. Files cut off while Vantage was away pick up where they stopped.
    func applicationDidBecomeActive(_ notification: Notification) {
        MacWindowRouter.shared.openPendingConnection()
        MacApp.reachability.refresh()
        FileTransferCenter.shared.retryAll()
    }
}
#endif
