import SwiftUI
import VantageCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = DeviceStore()
    @State private var reachability = TailscaleReachability()
    @State private var lock = AppLock()

    var body: some View {
        ZStack {
            DeviceListScreen()
                .environment(store)
                .environment(reachability)
                .blur(radius: lock.isLocked ? 24 : 0)

            if lock.isLocked {
                LockOverlay { lock.authenticate() }
            }
        }
        .task {
            reachability.start()
            lock.authenticate()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: lock.authenticate()
            case .background: lock.lockIfNeeded()
            default: break
            }
        }
    }
}

private struct LockOverlay: View {
    let onUnlock: () -> Void
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle)
                Text("Vantage is locked").font(.headline)
                Button("Unlock", action: onUnlock).buttonStyle(.glassProminent)
            }
        }
    }
}

#Preview {
    ContentView()
}
