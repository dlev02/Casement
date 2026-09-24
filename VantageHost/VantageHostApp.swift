import AppKit
import SwiftUI
import os

@main
struct VantageHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            HostMenuView(controller: delegate.controller)
        } label: {
            // A progress ring joins the icon while files move (and VoiceOver hears how far along).
            let controller = delegate.controller
            Image(nsImage: StatusItemIcon.image(for: controller.status, activity: StatusItemIcon.Activity(controller.transfers)))
                .accessibilityLabel("Vantage Host")
                .accessibilityValue(StatusItemIcon.accessibilityValue(status: controller.status, transfers: controller.transfers))
        }
        .menuBarExtraStyle(.window)

        Settings {
            HostSettingsView(controller: delegate.controller)
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
        if HostOptions.shared.openMenu { openMenuWindowForTesting() }
        if let seconds = HostOptions.shared.exitAfterSeconds {
            // A scripted test host quits by itself instead of being left running.
            Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "controller")
                .info("--exit-after: quitting in \(seconds, privacy: .public) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        #endif
    }

    #if DEBUG
    private var settingsWindow: NSWindow?
    private var menuWindow: NSWindow?

    /// `--open-menu`: the popover's content in a plain window, for when the item is hidden.
    private func openMenuWindowForTesting() {
        let root = VStack(spacing: 0) {
            HostMenuView(controller: controller)
            StatusIconPreview(controller: controller)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Vantage Host Menu"
        window.makeKeyAndOrderFront(nil)
        menuWindow = window
    }

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

#if DEBUG
/// `--open-menu`: the menu bar icon as it is right now, at menu bar size and enlarged, with what
/// VoiceOver says about it.
private struct StatusIconPreview: View {
    let controller: HostController

    var body: some View {
        let icon = StatusItemIcon.image(for: controller.status, activity: StatusItemIcon.Activity(controller.transfers))
        HStack(spacing: 16) {
            Image(nsImage: icon).renderingMode(.template)
            Image(nsImage: icon).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: icon.size.width * 4, height: icon.size.height * 4)
            Text(StatusItemIcon.accessibilityValue(status: controller.status, transfers: controller.transfers))
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 320)
    }
}
#endif
