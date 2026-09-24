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

    /// Symbols that exist: "display.and.arrow.down.fill" and "display.slash" don't, and left the
    /// menu bar item blank while connected.
    private var menuBarSymbol: String {
        switch delegate.controller.status {
        case .connected: "display.and.arrow.down"
        case .listening, .idle: "display"
        case .error: "display.trianglebadge.exclamationmark"
        }
    }
}

/// Starts the host runtime as soon as the process launches (the menu popover may never open).
@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    let controller = HostController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        HostNotifications.shared.install()
        ParakeetModel.shared.start() // Warms the built-in engine only if the user turned it on.
        if HostOptions.shared.fixedPairingCode != nil {
            controller.generatePairingCode()
        }
        #if DEBUG
        switch HostOptions.shared.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if HostOptions.shared.openSettingsTab != nil { openSettingsWindowForTesting() }
        if !HostOptions.shared.previewArrival.isEmpty { previewArrivalForTesting() }
        #endif
    }

    #if DEBUG
    private var settingsWindow: NSWindow?

    /// `--open-settings <tab>`: a menu-bar app can't be told to open its Settings scene from the
    /// command line, so host the same view in a plain window for screenshots.
    private func openSettingsWindowForTesting() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: HostSettingsView(controller: controller)))
        window.title = "Vantage Host Settings"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    /// `--preview-arrival <paths>`: the on-screen notice for those files, until it's closed.
    private func previewArrivalForTesting() {
        let files = HostOptions.shared.previewArrival.map { URL(fileURLWithPath: $0) }
        let folder = files[0].deletingLastPathComponent()
        let summary = ArrivalSummary(files: files, devices: ["Drew's iPad Pro"],
                                     folderName: FileManager.default.displayName(atPath: folder.path(percentEncoded: false)),
                                     isDownloads: false)
        ArrivalNotice.shared.show(summary, files: files, lingers: true)
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reason = RestartGuard.systemQuitReason(),
              RestartGuard.isEnabled,
              controller.hasConnectedClients,
              !controller.safeRestartStaged
        else { return .terminateNow }
        // Answer later so loginwindow waits for the prompt instead of timing the restart out.
        let fileVaultOn = controller.readiness?.fileVaultOn
        let canRestartSafely = controller.readiness?.authRestartSupported == true
        DispatchQueue.main.async {
            let proceed = RestartGuard.confirm(reason, fileVaultOn: fileVaultOn, canRestartSafely: canRestartSafely)
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}
