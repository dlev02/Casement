import SwiftUI
import VantageCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = DeviceStore()
    @State private var reachability = TailscaleReachability()
    @State private var lock = AppLock()
    @State private var selectedDevice: SavedDevice?
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic

    var body: some View {
        ZStack {
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else {
                DeviceListScreen(selectedDevice: $selectedDevice)
                    .environment(store)
                    .environment(reachability)
            }
        }
        .preferredColorScheme(appearance == .automatic ? nil : (appearance == .light ? .light : .dark))
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
        .task {
            reachability.start()
            lock.authenticate()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                reachability.refresh()
                lock.authenticate()
            case .background: lock.lockIfNeeded()
            default: break
            }
        }
    }
}

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
