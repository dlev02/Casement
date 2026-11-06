import AppKit
import ServiceManagement
import os

/// Registers Vantage Host as a login item so it relaunches after a reboot (once the user logs in).
/// This is the realistic "works after the Mac reboots" path for a FileVault Mac: the host comes
/// back automatically at login and the iPad client auto-reconnects. True pre-login control is not
/// available to a third-party app (see docs/research).
@MainActor
@Observable
final class LoginItem {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "loginitem")
    private let service = SMAppService.mainApp
    /// `SMAppService.status` is a round trip to another process, far too slow to read while a view
    /// draws: Settings' Reboot toggle reads it many times per update, and that was more than half
    /// of the time every tab switch spent. Views read this copy.
    private var status = SMAppService.Status.notRegistered
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init() {
        status = service.status
        // Approval happens in System Settings; coming back is when it can have changed.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    /// Asks macOS again, off the main thread.
    func refresh() {
        Task.detached {
            let current = SMAppService.mainApp.status
            await MainActor.run { if self.status != current { self.status = current } }
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        status = service.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
