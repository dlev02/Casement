import Foundation
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

    var isEnabled: Bool { service.status == .enabled }
    var requiresApproval: Bool { service.status == .requiresApproval }

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
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
