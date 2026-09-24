import SwiftUI

@main
struct VantageApp: App {
    #if os(visionOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(visionOS)
        // The app's phase only reaches background once every window has, so an open session
        // doesn't lock just because the device list was closed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AppLock.shared.lockIfNeeded() }
        }
        #endif

        #if os(visionOS) || os(macOS)
        WindowGroup(id: SessionWindow.sceneID, for: UUID.self) { $deviceID in
            SessionWindow(deviceID: deviceID)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled) // reconnecting should be the user's call, not a relaunch's
        #if os(macOS)
        .commandsRemoved() // File › New Window would open a session window with no Mac in it
        #endif
        #endif
    }
}
