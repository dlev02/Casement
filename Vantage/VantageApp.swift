import SwiftUI

@main
struct VantageApp: App {
    #if os(visionOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    init() {
        // View › Enter Full Screen is Vantage's own (with ⌃⌥⌘F, which a session leaves to
        // Vantage); AppKit would add a second one. Registered before the menu bar is built.
        UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        // One device list (⌘N adds a Mac rather than a second list); every link and opened file
        // lands here rather than in a session window.
        Window("Porthole", id: MacRootView.sceneID) {
            MacRootView().macWindowRoot()
        }
        .defaultSize(width: 880, height: 580)
        // Always there at launch, even if it was closed when Vantage last quit (or the state
        // saved then can't be restored): a Mac app that opens to nothing looks broken.
        .defaultLaunchBehavior(.presented)
        .handlesExternalEvents(matching: ["*"])
        .commands { MacCommands() }
        #else
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
        .handlesExternalEvents(matching: []) // a link never opens an empty session window
        #endif
        #endif

        #if os(macOS)
        Settings {
            MacSettingsView()
        }

        Window("Porthole Help", id: MacHelpWindow.sceneID) {
            MacHelpWindow()
        }
        .defaultSize(width: 560, height: 640)
        .commandsRemoved() // opened from Help › Vantage Help

        Window("About Porthole", id: MacAboutWindow.sceneID) {
            MacAboutWindow()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commandsRemoved() // opened from Vantage › About Vantage
        #endif
    }
}
