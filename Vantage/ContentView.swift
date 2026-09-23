import SwiftUI
import VantageCore

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
    #if DEBUG
    @State private var debugScreen: DebugScreen?
    #endif

    var body: some View {
        ZStack {
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else {
                DeviceListScreen(selectedDevice: $selectedDevice)
                    .environment(store)
                    .environment(reachability)
                    .environment(tailscaleAccount)
            }
        }
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
            NavigationStack { debugView(screen) }
                .environment(store)
                .environment(reachability)
                .environment(tailscaleAccount)
        }
        #endif
        .task {
            reachability.start()
            lock.authenticate()
            #if DEBUG
            debugScreen = ClientOptions.openScreen
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                reachability.refresh()
                lock.authenticate()
            case .background:
                #if os(visionOS)
                break // `VantageApp` locks once every window has gone, not when the list closes
                #else
                lock.lockIfNeeded()
                #endif
            default: break
            }
        }
        .onOpenURL { url in
            if let id = DeviceCatalog.macID(from: url) { pending.requestedMacID = id }
        }
        // `initial: true` catches a request that arrived before this view existed — a cold
        // launch from Siri, a shortcut, or the Control Center control sets the slot first.
        .onChange(of: pending.requestedMacID, initial: true) { _, id in openRequestedConnection(id) }
        .onChange(of: lock.isLocked) { _, locked in
            if !locked { openRequestedConnection(pending.requestedMacID) }
        }
        .onChange(of: requireBiometrics) { _, _ in store.refreshSpotlight() }
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

    #if DEBUG
    /// Opens one screen straight from a launch argument so screenshots don't depend on driving
    /// the UI. Never compiled into a release build.
    @ViewBuilder private func debugView(_ screen: DebugScreen) -> some View {
        switch screen {
        case .settings: SettingsScreen()
        case .controls: ControlSettings()
        case .security: SecuritySettings()
        case .help: HelpScreen()
        case .about: AboutScreen()
        case .tailscale: TailscaleAccountScreen()
        case .addDevice: AddDeviceSheet()
        case .widgets: WidgetGalleryScreen()
        }
    }
    #endif
}

#if os(visionOS)
/// visionOS opens each Mac in a window of its own, which the session shapes to the Mac's display.
struct SessionWindow: View {
    static let sceneID = "session"
    let deviceID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    private let store = DeviceStore.shared
    private let lock = AppLock.shared

    var body: some View {
        Group {
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else if let device = store.devices.first(where: { $0.id == deviceID }) {
                RemoteSessionScreen(device: device).environment(store)
            } else {
                ContentUnavailableView("Mac Not Found", systemImage: "display.trianglebadge.exclamationmark",
                                       description: Text("This Mac is no longer in your device list."))
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { lock.authenticate() }
        }
    }
}
#endif

private struct LockOverlay: View {
    let errorMessage: String?
    let onUnlock: () -> Void
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Vantage is locked").font(.headline)
                if let errorMessage {
                    Text(errorMessage).font(.callout).multilineTextAlignment(.center).padding(.horizontal)
                }
                Button("Unlock", action: onUnlock).buttonStyle(.glassProminent)
            }
        }
    }
}

#Preview {
    ContentView()
}
