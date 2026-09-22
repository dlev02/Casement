import SwiftUI
import VantageCore

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = DeviceStore()
    @State private var reachability = TailscaleReachability()
    @State private var lock = AppLock()

    var body: some View {
        ZStack {
            if lock.isLocked {
                LockOverlay(errorMessage: lock.errorMessage) { lock.authenticate() }
            } else {
                DeviceListScreen()
                    .environment(store)
                    .environment(reachability)
            }
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
