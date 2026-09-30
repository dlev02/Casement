import SwiftUI
import VantageCore

#if !os(macOS) // the Mac's windows start at `MacRootView`
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    #if os(visionOS)
    // Sessions open in windows of their own, so the list and every session share one store and lock.
    @State private var store = DeviceStore.shared
    @State private var reachability = TailscaleReachability()
    @State private var lock = AppLock.shared
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var store = DeviceStore()
    @State private var reachability = TailscaleReachability()
    @State private var lock = AppLock()
    #endif
    @State private var tailscaleAccount = TailscaleAccount()
    @State private var selectedDevice: SavedDevice?
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    /// The app lock also decides whether Macs are listed in Spotlight.
    @AppStorage(MacSpotlight.appLockKey) private var requireBiometrics = false
    private let pending = PendingConnection.shared
    private let sharedFiles = SharedFileInbox.shared
    #if DEBUG
    @State private var debugScreen: DebugScreen?
    #endif

    var body: some View {
        ZStack {
            #if os(visionOS)
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else {
                deviceList
            }
            #else
            // The list stays alive underneath the lock so an open sheet, and anything typed
            // into it, survives a trip to another app (copying a Tailscale secret from Safari
            // on iPhone). `LockCurtain` hides it, sheets included, until Face ID clears.
            deviceList
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            }
            #endif
        }
        #if os(iOS)
        .background(LockCurtain(lock: lock, appearance: appearance))
        #endif
        .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
        #if os(visionOS)
        .onChange(of: selectedDevice) { _, device in
            guard let device else { return }
            openWindow(id: SessionWindow.sceneID, value: device.id)
            selectedDevice = nil
        }
        #else
        .fullScreenCover(item: $selectedDevice) { device in
            Group {
                if lock.isLocked {
                    LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
                } else {
                    RemoteSessionScreen(device: device).environment(store)
                }
            }
            .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
        }
        #endif
        #if DEBUG
        .sheet(item: $debugScreen) { screen in
            NavigationStack { DebugScreenView(screen: screen) }
                .environment(store)
                .environment(reachability)
                .environment(tailscaleAccount)
        }
        #endif
        .task {
            reachability.start()
            lock.authenticate()
            // Files finishing (or failing) with any Mac, in a session or from the device list.
            FileTransferCenter.shared.onFeedback = { Haptics.play($0) }
            #if os(iOS)
            TransferBackgroundActivity.shared.start()
            #endif
            #if DEBUG
            debugScreen = ClientOptions.openScreen
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                reachability.refresh()
                lock.authenticate()
                // Files cut off while the app was away pick up where they stopped.
                #if os(iOS)
                TransferBackgroundActivity.shared.appDidBecomeActive()
                #else
                FileTransferCenter.shared.retryAll()
                #endif
            case .background:
                #if os(visionOS)
                break // `VantageApp` locks once every window has gone, not when the list closes
                #else
                lock.lockIfNeeded()
                TransferBackgroundActivity.shared.appDidEnterBackground()
                #endif
            default: break
            }
        }
        .onOpenURL { url in
            if url.isFileURL {
                sharedFiles.accept(url)
                openSessionForSharedFiles()
            } else if let id = DeviceCatalog.macID(from: url) {
                pending.requestedMacID = id
            }
        }
        // `initial: true` catches a request that arrived before this view existed — a cold
        // launch from Siri, a shortcut, or the Control Center control sets the slot first.
        .onChange(of: pending.requestedMacID, initial: true) { _, id in openRequestedConnection(id) }
        .onChange(of: lock.isLocked) { _, locked in
            if !locked {
                openRequestedConnection(pending.requestedMacID)
                openSessionForSharedFiles()
            }
        }
        .onChange(of: requireBiometrics) { _, _ in store.refreshSpotlight() }
    }

    private var deviceList: some View {
        DeviceListScreen(selectedDevice: $selectedDevice)
            .environment(store)
            .environment(reachability)
            .environment(tailscaleAccount)
    }

    /// Siri, Shortcuts, Spotlight, controls, and widgets all land here. If the app is locked the
    /// request waits until Face ID clears it, so a Home Screen tap can't skip the lock.
    private func openRequestedConnection(_ id: UUID?) {
        guard let id, !lock.isLocked else { return }
        // Handled either way from here: a Mac that no longer exists (a stale widget or link) is
        // dropped rather than left to fire later, and a session that's already open stays put.
        pending.requestedMacID = nil
        guard let device = store.devices.first(where: { $0.id == id }), selectedDevice?.id != id else { return }
        selectedDevice = device
    }

    /// A file opened in Vantage from another app goes to the Mac in the open session, or else
    /// straight to the Mac used most recently without opening its screen (its row in the list
    /// shows it moving). A Mac too old for that is opened as before. Waits for Face ID like any
    /// other request.
    private func openSessionForSharedFiles() {
        guard !sharedFiles.pending.isEmpty, !lock.isLocked else { return }
        #if os(iOS)
        guard selectedDevice == nil else { return } // the open session takes them
        #endif
        let recent = store.devices.max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }
        guard let device = recent else { return }
        let link = FileTransferCenter.shared.link(for: device)
        guard link.canSendWithoutScreen else {
            selectedDevice = device
            return
        }
        for copy in sharedFiles.take() { link.files.sendOutboxCopy(copy) }
    }

}

#Preview {
    ContentView()
}
#endif

#if DEBUG
/// Opens one screen straight from a launch argument so screenshots don't depend on driving
/// the UI. Never compiled into a release build.
struct DebugScreenView: View {
    let screen: DebugScreen
    @Environment(DeviceStore.self) private var store

    var body: some View {
        switch screen {
        case .settings: SettingsScreen()
        case .controls: ControlSettings()
        case .security: SecuritySettings()
        case .help: HelpScreen()
        case .about: AboutScreen()
        case .tailscale: TailscaleAccountScreen()
        case .tailscaleOAuth: TailscaleOAuthSetup()
        case .tailscaleToken: TailscaleTokenSetup()
        case .addDevice: AddDeviceSheet()
        case .widgets: WidgetGalleryScreen()
        case .transfers: TransfersFixtureScreen()
        case .controlStrip: ControlStripEditor()
        case .controlStripMac: MacControlStripEditor(deviceID: store.devices.first?.id ?? UUID())
        case .controlStripPC: MacControlStripEditor(deviceID: firstPC?.id ?? UUID())
        case .editPC: AddDeviceSheet(existing: firstPC)
        }
    }

    private var firstPC: SavedDevice? { store.devices.first { $0.platform == .windows } }
}
#endif

#if os(visionOS) || os(macOS)
/// visionOS and the Mac open each Mac in a window of its own, which the session shapes to the Mac's display.
struct SessionWindow: View {
    static let sceneID = "session"
    let deviceID: UUID?
    #if os(visionOS) // the Mac's window root handles both
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    #endif
    private let store = DeviceStore.shared
    private let lock = AppLock.shared

    var body: some View {
        #if os(macOS)
        // The lock covers the session instead of replacing it: swapping the view out would
        // disconnect it, and the Mac locks whenever its screen does.
        content
            .frame(minWidth: 480, minHeight: 300)
            .macWindowRoot()
            .onAppear { MacWindowRouter.shared.sessionWindowOpened() }
            .onDisappear { MacWindowRouter.shared.sessionWindowClosed() }
        #else
        Group {
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else {
                content
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lock.authenticate() }
        }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let device = store.devices.first(where: { $0.id == deviceID }) {
            RemoteSessionScreen(device: device).environment(store)
        } else {
            ContentUnavailableView("Mac Not Found", systemImage: "display.trianglebadge.exclamationmark",
                                   description: Text("This Mac is no longer in your device list."))
        }
    }
}
#endif

#if os(iOS)
/// Covers the whole scene — sheets and full-screen covers included — while the app is locked.
///
/// Swapping the root view for the lock screen would dismiss every presented sheet and discard
/// what was typed into it, so instead the views stay put and a window above them all hides
/// them. The system keyboard sits above every app window, so locking also ends editing.
private struct LockCurtain: UIViewRepresentable {
    let lock: AppLock
    let appearance: AppAppearance

    func makeUIView(context: Context) -> SceneProbe {
        let probe = SceneProbe()
        probe.onScene = { scene in context.coordinator.attach(to: scene) }
        return probe
    }

    func updateUIView(_ uiView: SceneProbe, context: Context) {
        context.coordinator.update(locked: lock.isLocked, appearance: appearance)
    }

    func makeCoordinator() -> Coordinator { Coordinator(lock: lock) }

    @MainActor final class Coordinator {
        private let lock: AppLock
        private var window: UIWindow?
        private var isLocked = false
        private var appearance = AppAppearance.automatic

        init(lock: AppLock) { self.lock = lock }

        func attach(to scene: UIWindowScene) {
            guard window?.windowScene !== scene else { return }
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: LockCurtainContent(lock: lock))
            self.window = window
            apply()
        }

        func update(locked: Bool, appearance: AppAppearance) {
            isLocked = locked
            self.appearance = appearance
            apply()
        }

        private func apply() {
            guard let window else { return }
            window.overrideUserInterfaceStyle = switch appearance {
            case .automatic: .unspecified
            case .light: .light
            case .dark: .dark
            }
            if isLocked {
                // The keyboard would otherwise float over the lock screen. Typed text stays in
                // its field; only the focus goes.
                for other in window.windowScene?.windows ?? [] where other !== window { other.endEditing(true) }
                window.makeKeyAndVisible()
            } else if !window.isHidden {
                window.isHidden = true
                window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
            }
        }
    }

    /// Reports the window scene once the representable lands in a window.
    final class SceneProbe: UIView {
        var onScene: ((UIWindowScene) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { onScene?(scene) }
        }
    }
}

private struct LockCurtainContent: View {
    let lock: AppLock
    var body: some View {
        LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
    }
}
#endif
