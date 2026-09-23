import Foundation
import VantageCore

/// The Mac account password Vantage can type for you, one per saved device.
///
/// Passwords live in the Keychain — never in the saved-device list — under the device's UUID, so
/// renaming or re-addressing a Mac keeps its password and removing the Mac forgets it. With iCloud
/// sync on they ride iCloud Keychain to your other devices; otherwise they never leave this one
/// except as keystrokes on an already-authenticated session.
enum DeviceSecrets {
    static let keychainService = "com.benjaminlevinson.vantage.client.secrets"

    static func password(for device: SavedDevice) -> String? {
        password(forID: device.id)
    }

    static func password(forID id: UUID) -> String? {
        CloudSync.secret(account(for: id), service: keychainService)
    }

    static func hasPassword(for device: SavedDevice) -> Bool {
        password(for: device) != nil
    }

    /// Saves a password, or removes it when `password` is nil or empty.
    static func setPassword(_ password: String?, for device: SavedDevice) {
        setPassword(password, forID: device.id)
    }

    /// Removing the password also forgets the account name, which is useless without it.
    static func setPassword(_ password: String?, forID id: UUID) {
        guard let password, !password.isEmpty else {
            CloudSync.removeSecret(account(for: id), service: keychainService)
            CloudSync.removeSecret(usernameAccount(for: id), service: keychainService)
            return
        }
        try? CloudSync.secretsStore(service: keychainService).set(password, for: account(for: id))
    }

    /// The Mac account name that goes with the password. Screen Sharing needs it to sign in, which
    /// is how Vantage types into password fields and the lock screen that block ordinary keystrokes.
    static func username(for device: SavedDevice) -> String? {
        CloudSync.secret(usernameAccount(for: device.id), service: keychainService)
    }

    static func setUsername(_ username: String?, for device: SavedDevice) {
        let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            CloudSync.removeSecret(usernameAccount(for: device.id), service: keychainService)
            return
        }
        try? CloudSync.secretsStore(service: keychainService).set(trimmed, for: usernameAccount(for: device.id))
    }

    static func account(for id: UUID) -> String { "password.\(id.uuidString)" }
    static func usernameAccount(for id: UUID) -> String { "username.\(id.uuidString)" }
}
