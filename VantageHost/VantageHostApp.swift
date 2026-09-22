import AppKit
import SwiftUI

@main
struct VantageHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            HostMenuView(controller: delegate.controller)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            HostSettingsView(controller: delegate.controller)
        }
    }

    private var menuBarSymbol: String {
        switch delegate.controller.status {
        case .connected: "display.and.arrow.down.fill"
        case .listening: "display"
        case .error: "exclamationmark.triangle"
        case .idle: "display.slash"
        }
    }
}

/// Starts the host runtime as soon as the process launches (the menu popover may never open).
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let controller = HostController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        if HostOptions.shared.fixedPairingCode != nil {
            controller.generatePairingCode()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
